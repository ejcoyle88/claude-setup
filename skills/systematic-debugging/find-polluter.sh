#!/usr/bin/env bash
# Bisection script to find which test creates unwanted files/state.
# Runs each matching test file one at a time via `npm test <file>` and
# stops at the first one whose run leaves POLLUTION_CHECK on disk.
#
# Dependencies: npm must be on PATH, and the project's `npm test <file>`
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

# Get list of test files
TEST_FILES=$(find . -path "$TEST_PATTERN" | sort)
TOTAL=$(echo "$TEST_FILES" | wc -l | tr -d ' ')

echo "Found $TOTAL test files"
echo ""

COUNT=0
FAILING_TESTS=""
for TEST_FILE in $TEST_FILES; do
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
  # never persisted to disk, even transiently.
  TEST_OUTPUT=""
  if TEST_OUTPUT=$(npm test "$TEST_FILE" 2>&1); then
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
    echo "  npm test $TEST_FILE    # Run just this test"
    echo "  cat $TEST_FILE         # Review test code"
    exit 1
  fi
done

echo ""
if [ -n "$FAILING_TESTS" ]; then
  echo "✅ No polluter found - but some test runs FAILED (unrelated to pollution):"
  printf "%b" "$FAILING_TESTS" | sed 's/^/   - /'
  echo "Re-run 'npm test <file>' on the failing file(s) above to see full output."
  exit 2
fi

echo "✅ No polluter found - all tests clean!"
exit 0
