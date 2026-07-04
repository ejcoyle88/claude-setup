#!/usr/bin/env bash
# Tests helpers in run-overnight.sh: the completed-iteration/spend extraction
# helpers (count_completed_iterations, total_worker_spend) against fabricated
# worker-N.log files, and the MCP pre-trust gate (mcp_trust_gate, claude-9hl)
# against fabricated workdirs — without launching claude or doing a real
# overnight run.
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
#
# NOTE: sourcing (unconditionally, ahead of the BASH_SOURCE guard) computes
# LOG_DIR/SUMMARY under this scratch dir and `mkdir -p`s it, and several
# functions sourced from run-overnight.sh — including mcp_trust_gate() on its
# failure/mismatch paths — call log(), which appends to $SUMMARY. Keep
# SOURCE_SCRATCH_DIR alive for the whole test run (clean it up at the very
# end, below) rather than deleting it right after sourcing: deleting it
# immediately leaves $SUMMARY pointing at a since-removed parent directory,
# so every later log() call — e.g. from the mcp_trust_gate tests that
# exercise a failing gate — throws a spurious "No such file or directory"
# redirection error on stderr. Assertions still pass either way (log()'s
# exit status doesn't affect mcp_trust_gate's return code), but the noise
# pollutes CI output and can mask a real problem.
SOURCE_SCRATCH_DIR="$(mktemp -d)"
# shellcheck disable=SC1090  # dynamic path is intentional: repo-relative $SCRIPT
SKIP_PREFLIGHT=1 ANALYZE_TELEMETRY=0 source "$SCRIPT" "$SOURCE_SCRATCH_DIR" >/dev/null 2>&1

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

# --- mcp_trust_gate (claude-9hl) ---
# Auditable pre-trust check for claude-1bz's finding that headless `claude -p`
# silently auto-connects a project's .mcp.json MCP servers with no fail-closed
# behavior. These tests exercise the gate directly against fabricated
# workdirs, without launching claude.
#
# The gate requires the .mcp.json/.mcp.json.trusted-sha256 pair to be
# git-tracked AND clean (no uncommitted working-tree changes), not just
# byte-matching on disk — a bytes-only check is self-computable by the very
# unattended agent the gate exists to constrain. So most "should pass" cases
# below need a real git repo with an actual commit, not just files on disk.

# mcp_git_init_committed <dir> <mcp_json_content> <trust_file_content>
# Initializes a throwaway git repo at <dir> and commits exactly the given
# .mcp.json / .mcp.json.trusted-sha256 contents as a single clean commit.
mcp_git_init_committed() {
  local dir="$1" mcp_content="$2" trust_content="$3"
  ( cd "$dir" \
    && git init -q \
    && git config user.email test@example.com \
    && git config user.name "Test" \
    && printf '%s' "$mcp_content" > .mcp.json \
    && printf '%s' "$trust_content" > .mcp.json.trusted-sha256 \
    && git add .mcp.json .mcp.json.trusted-sha256 \
    && git commit -q -m "trust baseline" )
}

test_mcp_gate_passes_with_no_mcp_json() {
  assert "no .mcp.json in workdir -> nothing to gate, gate passes" \
    "mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_passes_when_committed_and_clean_and_matching() {
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  assert "committed, clean working tree, matching hash -> gate passes" \
    "mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_fails_when_trust_file_missing() {
  echo '{"mcpServers":{}}' > "$TMPDIR_TEST/.mcp.json"
  assert ".mcp.json with no committed trust file -> gate refuses (fail-closed)" \
    "! mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_fails_on_hash_mismatch_even_when_committed_and_clean() {
  # Committed and clean, but the hash itself is genuinely wrong — exercises
  # the final sha256 comparison specifically (not the tracked/clean checks).
  mcp_git_init_committed "$TMPDIR_TEST" '{"mcpServers":{}}' \
    "0000000000000000000000000000000000000000000000000000000000000000" >/dev/null 2>&1
  assert "committed+clean but genuinely wrong hash -> gate refuses" \
    "! mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_fails_when_trust_file_on_disk_but_never_git_added() {
  # This is the exact hole Finding 1 identified: this repo's own
  # .mcp.json.trusted-sha256 was untracked (`?? .mcp.json.trusted-sha256` in
  # `git status`) and a bytes-only gate would have passed anyway.
  ( cd "$TMPDIR_TEST" && git init -q && git config user.email test@example.com && git config user.name "Test" )
  echo '{"mcpServers":{}}' > "$TMPDIR_TEST/.mcp.json"
  ( cd "$TMPDIR_TEST" && git add .mcp.json && git commit -q -m "mcp.json only" )
  sha256sum "$TMPDIR_TEST/.mcp.json" | awk '{print $1}' > "$TMPDIR_TEST/.mcp.json.trusted-sha256"
  # trust file exists on disk with the byte-correct hash, but was never
  # `git add`ed/committed.
  assert "on-disk-but-never-committed trust file is refused, not silently trusted" \
    "! mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_fails_on_uncommitted_self_reauthorization() {
  # Simulates the Finding-1 attack directly: a trusted, committed baseline
  # exists; the unattended agent (or an injected tool call) then rewrites
  # .mcp.json AND regenerates a matching hash, but commits neither change. A
  # bytes-only gate would incorrectly trust this because the hashes match;
  # the git-clean check must still refuse.
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  local evil='{"mcpServers":{"evil":{"command":"whatever"}}}'
  printf '%s' "$evil" > "$TMPDIR_TEST/.mcp.json"
  printf '%s' "$evil" | sha256sum | awk '{print $1}' > "$TMPDIR_TEST/.mcp.json.trusted-sha256"
  assert "matching-but-uncommitted rewrite ('self-reauthorization') is refused, not silently trusted" \
    "! mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_passes_on_committed_repo_files() {
  # Regression guard (Finding 2): proves the shipped .mcp.json.trusted-sha256
  # actually matches the shipped .mcp.json in THIS repo, not just that the
  # gate's internal logic works against fabricated dirs. Because the gate
  # fails closed, a real hash/file mismatch here would otherwise only surface
  # at 2am when an overnight run's preflight check aborts, with no PR-time
  # signal. NOTE: this requires .mcp.json.trusted-sha256 to be committed (not
  # just staged) and the working tree clean for both paths — it will
  # correctly go red if that commit hasn't landed yet.
  assert "committed .mcp.json.trusted-sha256 matches committed .mcp.json in the real checkout" \
    "mcp_trust_gate '$REPO_ROOT'"
}

test_mcp_gate_fails_when_mcp_json_is_a_symlink() {
  # Finding 1 (round 2): a committed, clean symlink still passes the
  # tracked+clean check (git stores the symlink's target *string* as the
  # blob and never dereferences it, so `git diff --quiet HEAD` reports
  # clean), while sha256sum *does* follow the link and hashes whatever it
  # currently points to. One commit swapping .mcp.json for a symlink into a
  # writable location would let an agent rewrite the pointed-to content
  # indefinitely with zero further commits and zero git-diff signal. Reject
  # symlinks outright rather than trusting them.
  ( cd "$TMPDIR_TEST" \
    && git init -q && git config user.email test@example.com && git config user.name "Test" \
    && mkdir -p real \
    && echo '{"mcpServers":{}}' > real/real.json \
    && ln -s real/real.json .mcp.json \
    && sha256sum real/real.json | awk '{print $1}' > .mcp.json.trusted-sha256 \
    && git add .mcp.json .mcp.json.trusted-sha256 real/real.json \
    && git commit -q -m "symlinked .mcp.json, committed and clean" )
  assert "a committed, clean, hash-matching symlinked .mcp.json is refused, not silently trusted" \
    "! mcp_trust_gate '$TMPDIR_TEST'"
}

test_mcp_gate_bypass_flag_documented_and_working() {
  echo '{"mcpServers":{}}' > "$TMPDIR_TEST/.mcp.json"
  echo "0000000000000000000000000000000000000000000000000000000000000000" > "$TMPDIR_TEST/.mcp.json.trusted-sha256"
  assert "SKIP_MCP_TRUST_CHECK=1 bypasses an otherwise-failing gate" \
    "SKIP_MCP_TRUST_CHECK=1 mcp_trust_gate '$TMPDIR_TEST'"
}

# --- MCP_EXTERNAL_TRUST_ANCHOR / mcp_external_anchor_check (claude-o7u) ---
# claude-9hl's own residual limitation: the in-repo checks above require a
# fresh commit, but nothing stops the very identity running this script from
# making that commit itself (`/build-next --unattended` commits per
# completed task). These tests exercise the opt-in out-of-band layer that
# closes it — an anchor file that must live outside $workdir and be
# unwritable by this identity. EXT_ANCHOR_DIR is a scratch dir created
# OUTSIDE TMPDIR_TEST (sibling, not nested) so it's a genuine stand-in for
# "outside the repo working tree"; cleaned up per-test since teardown() only
# removes TMPDIR_TEST.

ext_anchor_setup() { # ext_anchor_setup -> sets EXT_ANCHOR_DIR (a fresh scratch dir)
  EXT_ANCHOR_DIR="$(mktemp -d)"
}
ext_anchor_teardown() {
  chmod -R u+w "$EXT_ANCHOR_DIR" 2>/dev/null
  rm -rf "$EXT_ANCHOR_DIR"
}

test_external_anchor_unset_does_not_change_existing_behavior() {
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  assert "MCP_EXTERNAL_TRUST_ANCHOR unset -> gate behaves exactly as claude-9hl shipped it" \
    "mcp_trust_gate '$TMPDIR_TEST'"
}

test_external_anchor_missing_fails_when_configured() {
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  assert "in-repo pair valid but configured external anchor file doesn't exist -> refuses" \
    "! MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/nonexistent.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  ext_anchor_teardown
}

test_external_anchor_matches_and_locked_down_passes() {
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  printf '%s' "$hash" > "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0444 "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0555 "$EXT_ANCHOR_DIR"
  # _MCP_ANCHOR_WALK_ROOT_TEST_ONLY bounds the ancestor walk at
  # EXT_ANCHOR_DIR (still checked itself, per the assertion below) instead
  # of the true "/": every scratch dir this unprivileged test process can
  # create lives under /tmp, which is itself world-writable, so an
  # unbounded walk would (correctly) refuse every fixture the test suite
  # can build here — see the internal-test-seam comment in
  # mcp_external_anchor_check(). This does not weaken the real check; it
  # only affects this test process when the var is explicitly set.
  assert "in-repo pair valid + external anchor outside workdir, matching, unwritable -> gate passes" \
    "_MCP_ANCHOR_WALK_ROOT_TEST_ONLY='$EXT_ANCHOR_DIR' MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  chmod 0755 "$EXT_ANCHOR_DIR"
  ext_anchor_teardown
}

test_external_anchor_content_mismatch_fails() {
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  echo "0000000000000000000000000000000000000000000000000000000000000000" > "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0444 "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0555 "$EXT_ANCHOR_DIR"
  # Bounded at EXT_ANCHOR_DIR (see comment in the previous test) so this
  # exercises the content-mismatch path specifically, not an incidental
  # /tmp-writability refusal.
  assert "external anchor exists, outside workdir, unwritable, but content wrong -> refuses" \
    "! _MCP_ANCHOR_WALK_ROOT_TEST_ONLY='$EXT_ANCHOR_DIR' MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  chmod 0755 "$EXT_ANCHOR_DIR"
  ext_anchor_teardown
}

test_external_anchor_inside_workdir_is_rejected() {
  # The whole point of "external" is that it's unreachable from a commit
  # made inside $workdir. Pointing the anchor AT a path inside the very repo
  # being gated must be refused outright, even if it would otherwise be
  # valid/matching/locked-down — otherwise "external" is just theater.
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  printf '%s' "$hash" > "$TMPDIR_TEST/inside-repo-anchor.sha256"
  chmod 0444 "$TMPDIR_TEST/inside-repo-anchor.sha256"
  assert "anchor path resolving inside \$workdir is refused even though content matches" \
    "! MCP_EXTERNAL_TRUST_ANCHOR='$TMPDIR_TEST/inside-repo-anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  chmod u+w "$TMPDIR_TEST/inside-repo-anchor.sha256"
}

test_external_anchor_symlink_rejected() {
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  printf '%s' "$hash" > "$EXT_ANCHOR_DIR/real.sha256"
  chmod 0444 "$EXT_ANCHOR_DIR/real.sha256"
  ln -s "$EXT_ANCHOR_DIR/real.sha256" "$EXT_ANCHOR_DIR/anchor-link.sha256"
  assert "a symlinked external anchor is refused, not silently followed" \
    "! MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/anchor-link.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  ext_anchor_teardown
}

test_external_anchor_writable_by_self_is_rejected_even_when_content_matches() {
  # This is the core property the whole mechanism rests on: an anchor this
  # identity can write provides NO separation, no matter how correct its
  # current content is (this identity could have just written that content
  # itself, exactly the self-reauthorization move the gate exists to catch).
  # The gate must refuse a writable anchor rather than trust it because the
  # bytes happen to line up right now.
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  printf '%s' "$hash" > "$EXT_ANCHOR_DIR/anchor.sha256"
  # deliberately left writable (default mktemp -d / file perms)
  assert "external anchor is writable by this identity -> refused even though content currently matches" \
    "! MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  ext_anchor_teardown
}

test_external_anchor_writable_parent_dir_is_rejected() {
  # Even a read-only anchor FILE is not enough if its parent directory is
  # writable: this identity could unlink and recreate the file (a directory
  # write, not a file write) to the same effect as editing it in place.
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  printf '%s' "$hash" > "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0444 "$EXT_ANCHOR_DIR/anchor.sha256"
  # parent dir left writable (default mktemp -d perms, 0700 but owner-writable)
  assert "external anchor file is read-only but its directory is writable -> refused (delete+recreate vector)" \
    "! MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  ext_anchor_teardown
}

test_external_anchor_writable_grandparent_dir_is_rejected() {
  # A writable grandparent (or higher) is enough to replace the whole
  # anchor_dir subtree even when the anchor FILE and its IMMEDIATE parent
  # are both locked down: `mv locked locked.bak && mkdir locked && echo
  # <fake> > locked/anchor.sha256 && chmod back` only ever needs write
  # access on the grandparent, never on `locked` itself. The ancestor walk
  # must catch this, not just check the immediate parent.
  local content='{"mcpServers":{}}'
  local hash; hash="$(printf '%s' "$content" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$content" "$hash" >/dev/null 2>&1
  ext_anchor_setup
  mkdir "$EXT_ANCHOR_DIR/locked"
  printf '%s' "$hash" > "$EXT_ANCHOR_DIR/locked/anchor.sha256"
  chmod 0444 "$EXT_ANCHOR_DIR/locked/anchor.sha256"
  chmod 0555 "$EXT_ANCHOR_DIR/locked"
  # EXT_ANCHOR_DIR itself (the grandparent) is deliberately left writable
  # (default mktemp -d perms) — anchor file and immediate parent are both
  # locked down, but the grandparent is not.
  assert "anchor file + immediate parent locked down, but a writable grandparent -> still refused" \
    "! MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/locked/anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"
  chmod 0755 "$EXT_ANCHOR_DIR/locked"
  ext_anchor_teardown
}

test_external_anchor_defeats_a_full_valid_self_committed_rewrite() {
  # Scoped claim (narrowed per round-1 review, Finding 3 -- see git history
  # for the earlier, overstated version): proves that a valid, clean,
  # git-tracked, hash-matching in-repo COMMIT -- by itself, exercised
  # perfectly, exactly what would fully satisfy claude-9hl's in-repo gate on
  # its own per test_mcp_gate_passes_when_committed_and_clean_and_matching
  # above -- does not flip the overall trust decision when a configured
  # external anchor disagrees. Mechanically this exercises the same
  # hash-mismatch path as test_external_anchor_content_mismatch_fails; the
  # added value here is the explicit A/B: the SAME rewrite that the in-repo
  # layer alone accepts (the control assertion below, reproducing
  # claude-9hl's documented gap) is refused once the anchor is in play.
  #
  # NOT proven here (see README's honestly-disclosed residual limitation):
  # this does not show the anchor resists a same-UID attacker who goes
  # further and directly `chmod u+w`s + rewrites the anchor file itself --
  # in this sandbox (no real root/second UID available), that IS possible,
  # and mcp_external_anchor_check()'s writability checks exist to refuse an
  # anchor an operator left writable, not to make an unwritable anchor
  # un-chmod-able by its own owner.
  local original='{"mcpServers":{"ollama-mcp":{"command":"node"}}}'
  local original_hash; original_hash="$(printf '%s' "$original" | sha256sum | awk '{print $1}')"
  mcp_git_init_committed "$TMPDIR_TEST" "$original" "$original_hash" >/dev/null 2>&1

  # The external anchor is provisioned once, out of band, pinned to the
  # ORIGINAL trusted content -- standing in for a root-owned file this
  # identity has no write path to.
  ext_anchor_setup
  printf '%s' "$original_hash" > "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0444 "$EXT_ANCHOR_DIR/anchor.sha256"
  chmod 0555 "$EXT_ANCHOR_DIR"

  # Now simulate the exact attack claude-o7u is about: the (commit-capable)
  # identity rewrites .mcp.json to add a server of its own choosing, AND
  # performs a fully legitimate-looking commit of a matching trust hash --
  # nothing about this commit is dirty, untracked, or a symlink.
  local rewritten='{"mcpServers":{"ollama-mcp":{"command":"node"},"evil":{"command":"whatever"}}}'
  local rewritten_hash; rewritten_hash="$(printf '%s' "$rewritten" | sha256sum | awk '{print $1}')"
  ( cd "$TMPDIR_TEST" \
    && printf '%s' "$rewritten" > .mcp.json \
    && printf '%s' "$rewritten_hash" > .mcp.json.trusted-sha256 \
    && git add .mcp.json .mcp.json.trusted-sha256 \
    && git commit -q -m "self-authored rewrite + matching hash" )

  # Confirm the in-repo layer ALONE (no external anchor configured) would
  # have been fooled -- this is claude-9hl's documented residual limitation,
  # reproduced here as a control before showing the fix.
  assert "control: in-repo layer alone is fooled by a fully committed self-rewrite (the documented claude-9hl gap)" \
    "mcp_trust_gate '$TMPDIR_TEST'"

  # With the external anchor configured (still pinned to the ORIGINAL hash,
  # because this identity never had write access to update it), the overall
  # gate must now refuse -- proving the commit alone cannot flip the
  # decision. Bounded at EXT_ANCHOR_DIR (see the walk-root comment in
  # test_external_anchor_matches_and_locked_down_passes above) so this
  # refusal is specifically the hash-mismatch this test is about, not an
  # incidental /tmp-writability refusal.
  assert "fix: with MCP_EXTERNAL_TRUST_ANCHOR configured, the same self-committed rewrite is refused" \
    "! _MCP_ANCHOR_WALK_ROOT_TEST_ONLY='$EXT_ANCHOR_DIR' MCP_EXTERNAL_TRUST_ANCHOR='$EXT_ANCHOR_DIR/anchor.sha256' mcp_trust_gate '$TMPDIR_TEST'"

  chmod 0755 "$EXT_ANCHOR_DIR"
  ext_anchor_teardown
}

run_test test_count_zero_with_no_worker_logs
run_test test_count_single_worker
run_test test_count_multi_worker_sum
run_test test_count_zero_completed_worker
run_test test_old_pipeline_was_broken_new_one_is_not
run_test test_spend_zero_with_no_worker_logs
run_test test_spend_sums_multiple_workers
run_test test_mcp_gate_passes_with_no_mcp_json
run_test test_mcp_gate_passes_when_committed_and_clean_and_matching
run_test test_mcp_gate_fails_when_trust_file_missing
run_test test_mcp_gate_fails_on_hash_mismatch_even_when_committed_and_clean
run_test test_mcp_gate_fails_when_trust_file_on_disk_but_never_git_added
run_test test_mcp_gate_fails_on_uncommitted_self_reauthorization
run_test test_mcp_gate_passes_on_committed_repo_files
run_test test_mcp_gate_fails_when_mcp_json_is_a_symlink
run_test test_mcp_gate_bypass_flag_documented_and_working
run_test test_external_anchor_unset_does_not_change_existing_behavior
run_test test_external_anchor_missing_fails_when_configured
run_test test_external_anchor_matches_and_locked_down_passes
run_test test_external_anchor_content_mismatch_fails
run_test test_external_anchor_inside_workdir_is_rejected
run_test test_external_anchor_symlink_rejected
run_test test_external_anchor_writable_by_self_is_rejected_even_when_content_matches
run_test test_external_anchor_writable_parent_dir_is_rejected
run_test test_external_anchor_writable_grandparent_dir_is_rejected
run_test test_external_anchor_defeats_a_full_valid_self_committed_rewrite

rm -rf "$SOURCE_SCRATCH_DIR"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
