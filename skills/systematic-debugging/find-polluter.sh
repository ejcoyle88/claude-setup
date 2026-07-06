#!/usr/bin/env bash
# Bisection script to find which test creates unwanted files/state.
# Runs each matching test file one at a time via `npm test -- <file>` and
# stops at the first one whose run leaves POLLUTION_CHECK on disk.
#
# Dependencies: npm must be on PATH, and the project's `npm test -- <file>`
# invocation must accept a single test file path (as most JS/TS test
# runners - Jest, Vitest, etc. - do when invoked through `npm test --`).
#
# Usage: ./find-polluter.sh <file_or_dir_to_check> <test_pattern>
# Example: ./find-polluter.sh '.git' 'src/**/*.test.ts'

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <file_to_check> <test_pattern>"
  echo "Example: $0 '.git' 'src/**/*.test.ts'"
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "Error: npm not found on PATH. This script runs tests via 'npm test' and requires Node/npm to be installed." >&2
  exit 1
fi

POLLUTION_CHECK="$1"
TEST_PATTERN="$2"

echo "🔍 Searching for test that creates: $POLLUTION_CHECK"
echo "Test pattern: $TEST_PATTERN"
echo ""

# Search root is `.`, so GNU find prepends `./` to every path it walks.
# `-path` does a literal(-ish) match against that prepended path, so a
# pattern with no leading `./` (e.g. 'src/**/*.test.ts', as documented in
# the Usage example above) would never match anything. Normalize the
# pattern to always start with `./`, without double-prefixing a pattern
# the caller already wrote with one.
case "$TEST_PATTERN" in
  ./*) FIND_PATTERN="$TEST_PATTERN" ;;
  *) FIND_PATTERN="./$TEST_PATTERN" ;;
esac

# Capture find's output and exit status separately from sort's (pipefail is
# scoped to this subshell only, so it doesn't change the rest of the script's
# behavior under `set -e`). Without this, a genuine `find` failure (bad
# -path argument, permission denied, etc.) would otherwise be swallowed by
# the pipe into `sort` and surface as "Found 0 test files" instead of an
# error, since a failure inside `< <(...)` process substitution isn't
# checked by `set -e` either.
if FIND_OUTPUT=$(set -o pipefail; find . -path "$FIND_PATTERN" | sort); then
  FIND_STATUS=0
else
  FIND_STATUS=$?
fi
if [ "$FIND_STATUS" -ne 0 ]; then
  echo "Error: 'find' failed (exit $FIND_STATUS) while searching for pattern: $TEST_PATTERN" >&2
  exit 1
fi

# Get list of test files, newline-safe (avoids word-splitting on filenames
# with spaces/globs, unlike `for f in $TEST_FILES`). A read loop is used
# instead of `mapfile` for Bash 3.2 compatibility (stock macOS /bin/bash).
# Guard against FIND_OUTPUT being empty: a legitimately-empty match set
# must produce TOTAL=0, not a single empty-string entry from `<<<`.
TEST_FILES=()
if [ -n "$FIND_OUTPUT" ]; then
  while IFS= read -r f; do TEST_FILES+=("$f"); done <<< "$FIND_OUTPUT"
fi
TOTAL="${#TEST_FILES[@]}"

echo "Found $TOTAL test files"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  echo "No test files matched pattern: $TEST_PATTERN"
  exit 0
fi

COUNT=0
FAILING_TESTS=""
for TEST_FILE in "${TEST_FILES[@]}"; do
  COUNT=$((COUNT + 1))

  # Skip if pollution already exists
  if [ -e "$POLLUTION_CHECK" ]; then
    echo "⚠️  Pollution already exists before test $COUNT/$TOTAL"
    echo "   Skipping: $TEST_FILE"
    continue
  fi

  echo "[$COUNT/$TOTAL] Testing: $TEST_FILE"

  # Run the test, capturing output in memory only (never written to disk)
  # so a FAILING run is distinguished from a CLEAN one instead of silently
  # swallowing the exit code. Avoiding a temp file also means test stdout/
  # stderr (which can contain env dumps, tokens, connection strings) is
  # never persisted to disk, even transiently. `--` forwards $TEST_FILE to
  # the underlying test runner as documented above; without it, npm may
  # drop the positional arg and silently run the whole suite instead of
  # just this file. Output is piped through `tail -c` (with `pipefail`
  # scoped to this subshell so npm's real exit code, not tail's, is what
  # gets checked) to bound memory in case a hanging/looping test produces
  # unbounded output; only the last 20 lines are ever displayed (below).
  TEST_OUTPUT=""
  if TEST_OUTPUT=$(set -o pipefail; npm test -- "$TEST_FILE" 2>&1 | tail -c 1000000); then
    TEST_RESULT="clean"
  else
    TEST_RESULT="failing"
    FAILING_TESTS="${FAILING_TESTS}${TEST_FILE}\n"
    echo "   ⚠️  Test run FAILED"
  fi

  # Check if pollution appeared
  if [ -e "$POLLUTION_CHECK" ]; then
    echo ""
    echo "🎯 FOUND POLLUTER!"
    echo "   Test: $TEST_FILE"
    echo "   Test run was: $TEST_RESULT"
    echo "   Created: $POLLUTION_CHECK"
    echo ""
    echo "Pollution details:"
    ls -la "$POLLUTION_CHECK"
    echo ""
    if [ "$TEST_RESULT" = "failing" ]; then
      echo "Note: this test also FAILED its assertions. Last output lines:"
      printf '%s\n' "$TEST_OUTPUT" | tail -n 20 | sed 's/^/   | /'
      echo "Pollution may be a side effect of the failure, not the primary bug."
      echo ""
    fi
    echo "To investigate:"
    echo "  npm test -- $TEST_FILE    # Run just this test"
    echo "  cat $TEST_FILE         # Review test code"
    exit 1
  fi
done

echo ""
if [ -n "$FAILING_TESTS" ]; then
  echo "✅ No polluter found - but some test runs FAILED (unrelated to pollution):"
  printf "%b" "$FAILING_TESTS" | sed 's/^/   - /'
  echo "Re-run 'npm test -- <file>' on the failing file(s) above to see full output."
  exit 2
fi

echo "✅ No polluter found - all tests clean!"
exit 0
