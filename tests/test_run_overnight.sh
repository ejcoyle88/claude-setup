#!/usr/bin/env bash
# Tests the completed-iteration/spend extraction helpers in run-overnight.sh
# (count_completed_iterations, total_worker_spend) against fabricated
# worker-N.log files, without launching claude or doing a real overnight run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/tools/run-overnight.sh"

pass=0
fail=0
failed_tests=()

assert() {
  local desc="$1"
  local cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_tests+=("$desc: $cond")
    echo "  FAIL: $desc"
    echo "        condition: $cond"
  fi
}

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  LOG_DIR_TEST="$TMPDIR_TEST/logs"
  mkdir -p "$LOG_DIR_TEST"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

run_test() {
  local name="$1"
  echo "TEST: $name"
  setup
  "$name"
  teardown
}

# Source just the function definitions out of run-overnight.sh. The
# BASH_SOURCE guard around its "main" section (see that file) keeps this from
# launching claude, running a preflight probe, or doing a real overnight run —
# sourcing only defines count_completed_iterations / total_worker_spend /
# parse_result / etc. and sets a handful of harmless default variables.
# Point PROJECT_DIR at a scratch dir so it doesn't touch the real repo.
SOURCE_SCRATCH_DIR="$(mktemp -d)"
# shellcheck disable=SC1090  # dynamic path is intentional: repo-relative $SCRIPT
SKIP_PREFLIGHT=1 ANALYZE_TELEMETRY=0 source "$SCRIPT" "$SOURCE_SCRATCH_DIR" >/dev/null 2>&1
rm -rf "$SOURCE_SCRATCH_DIR"

# --- count_completed_iterations ---

test_count_zero_with_no_worker_logs() {
  local n
  n="$(count_completed_iterations "$LOG_DIR_TEST")"
  assert "count is 0 when no worker-*.log files exist" "[ '$n' = '0' ]"
}

test_count_single_worker() {
  echo "[12:00:00] Worker 1 complete: 3 successful iteration(s), \$1.2000 spent, remaining ready: 0." \
    > "$LOG_DIR_TEST/worker-1.log"
  local n
  n="$(count_completed_iterations "$LOG_DIR_TEST")"
  assert "count reflects a single worker's completed iterations" "[ '$n' = '3' ]"
}

test_count_multi_worker_sum() {
  echo "[12:00:00] Worker 1 complete: 3 successful iteration(s), \$1.2000 spent, remaining ready: 0." \
    > "$LOG_DIR_TEST/worker-1.log"
  echo "[12:05:00] Worker 2 complete: 5 successful iteration(s), \$2.5000 spent, remaining ready: 2." \
    > "$LOG_DIR_TEST/worker-2.log"
  echo "[12:10:00] Worker 3 complete: 12 successful iteration(s), \$4.0000 spent, remaining ready: 0." \
    > "$LOG_DIR_TEST/worker-3.log"
  local n
  n="$(count_completed_iterations "$LOG_DIR_TEST")"
  assert "count sums completed iterations across multiple workers (3+5+12=20)" "[ '$n' = '20' ]"
}

test_count_zero_completed_worker() {
  echo "[12:00:00] Worker 1 complete: 0 successful iteration(s), \$0 spent, remaining ready: 4." \
    > "$LOG_DIR_TEST/worker-1.log"
  local n
  n="$(count_completed_iterations "$LOG_DIR_TEST")"
  assert "a worker with 0 completed iterations contributes 0, not skipped/erroring" "[ '$n' = '0' ]"
}

# Regression guard: prove the ORIGINAL pipeline
#   grep -ho 'complete: [0-9]* successful' ... | grep -o '[0-9]*' | paste -sd+ - | bc
# actually fails to extract the count (grep's `[0-9]*` matches the empty
# string at every non-digit position, so paste joins a run of stray `+`s that
# bc can't parse — and bc isn't even installed in the target image), so
# `completed_total` silently comes out as 0 via the `|| echo 0` fallback even
# though iterations completed. This is the bug that made the end-of-night
# telemetry analysis never run. Confirms this test would have caught it, and
# that count_completed_iterations does not have the same failure mode.
test_old_pipeline_was_broken_new_one_is_not() {
  echo "[12:00:00] Worker 1 complete: 3 successful iteration(s), \$1.2000 spent, remaining ready: 0." \
    > "$LOG_DIR_TEST/worker-1.log"

  local old_result
  old_result="$(grep -ho 'complete: [0-9]* successful' "$LOG_DIR_TEST"/worker-*.log 2>/dev/null \
    | grep -o '[0-9]*' | paste -sd+ - | bc 2>/dev/null || echo 0)"
  assert "the old grep+bc pipeline fails to recover the real count of 3 (proves the bug existed)" \
    "[ '$old_result' != '3' ]"

  local new_result
  new_result="$(count_completed_iterations "$LOG_DIR_TEST")"
  assert "the new awk-based helper correctly recovers 3" "[ '$new_result' = '3' ]"
}

# --- total_worker_spend ---

test_spend_zero_with_no_worker_logs() {
  local n
  n="$(total_worker_spend "$LOG_DIR_TEST")"
  assert "spend is 0 when no worker-*.log files exist" "[ '$n' = '0' ]"
}

test_spend_sums_multiple_workers() {
  echo "[12:00:00] Worker 1 complete: 3 successful iteration(s), \$1.25 spent, remaining ready: 0." \
    > "$LOG_DIR_TEST/worker-1.log"
  echo "[12:05:00] Worker 2 complete: 2 successful iteration(s), \$0.75 spent, remaining ready: 0." \
    > "$LOG_DIR_TEST/worker-2.log"
  local n is_two
  n="$(total_worker_spend "$LOG_DIR_TEST")"
  is_two="$(awk -v n="$n" 'BEGIN{print (n==2)?"yes":"no"}')"
  assert "spend sums to 2 across workers (1.25+0.75), got $n" "[ '$is_two' = 'yes' ]"
}

run_test test_count_zero_with_no_worker_logs
run_test test_count_single_worker
run_test test_count_multi_worker_sum
run_test test_count_zero_completed_worker
run_test test_old_pipeline_was_broken_new_one_is_not
run_test test_spend_zero_with_no_worker_logs
run_test test_spend_sums_multiple_workers

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
