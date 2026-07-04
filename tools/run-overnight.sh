#!/usr/bin/env bash
# run-overnight.sh — loop Claude Code headlessly over /build-next until no ready work.
#
# v2: deterministic verification gate, stream-json parsing, budget caps,
#     optional git-worktree parallelism.
#
# Each iteration is a FRESH claude process (fresh context per task), running
# `/build-next --unattended` once. A worker stops when `bd ready` is empty, the
# stop file appears, its iteration cap / budget share is hit, too many runs fail
# in a row, or the verification gate fails (a broken build poisons every
# subsequent task, so the worker halts rather than building on rubble).
#
# Usage:
#   run-overnight.sh [project-dir]
#
# Env overrides:
#   MAX_ITERATIONS=20        per-worker cap on loops
#   RUN_TIMEOUT=90m          per-iteration timeout (a stuck run gets killed)
#   MAX_CONSEC_FAILURES=3    per-worker: stop after this many failures in a row
#   SLEEP_BETWEEN=15         seconds between iterations
#   PERMISSION_FLAGS="--permission-mode auto"
#       Default: auto mode — no routine prompts, but a classifier reviews each
#       action. Requires Claude Code v2.1.83+, a Team/Enterprise plan, and the
#       Anthropic API provider. IN HEADLESS MODE AN ESCALATION (3 consecutive /
#       20 total classifier denials) TERMINATES THE PROCESS — this loop counts
#       that as a failed iteration; the claimed bead drops out of `bd ready`, so
#       the next iteration moves on. Classifier calls count toward token usage.
#       Fallback if auto mode is unavailable on your plan/version:
#       PERMISSION_FLAGS="--dangerously-skip-permissions" (container advised;
#       refuses to run as root). A preflight probe validates the mode at launch.
#   SKIP_PREFLIGHT=0         set 1 to skip the launch-time permission probe
#
#   OTEL_ENABLED=1           export OpenTelemetry metrics + logs from every run
#       Defaults target a local OTLP collector: grpc → http://localhost:4317.
#       Override OTEL_EXPORTER_OTLP_ENDPOINT / _PROTOCOL / _HEADERS for a cloud
#       backend (Grafana Cloud, SigNoz, ...). If nothing is listening at the
#       endpoint, exports are dropped silently — run a collector, or set
#       OTEL_ENABLED=0. Content is structural by default (tokens, cost, tools —
#       no prompt text) unless you opt in via OTEL_LOG_USER_PROMPTS etc.
#       Each worker is tagged via OTEL_RESOURCE_ATTRIBUTES (run.id, worker.id).
#   STOP_FILE=<project>/.stop-overnight   touch to stop all workers gracefully
#
#   MCP trust gate (claude-9hl): headless `claude -p` auto-connects a
#       project's .mcp.json MCP servers with NO trust prompt and no fail-closed
#       behavior (verified in claude-1bz; see tools/ollama-mcp/README.md's
#       "Headless/unattended trust behavior" section and
#       anthropics/claude-code#5307). `--bare` would suppress this, but it also
#       suppresses skill/command auto-discovery — and `/build-next` itself is
#       a project skill (`commands/build-next.md`), so `--bare` would break
#       the very command this loop exists to run. Instead: every headless
#       `claude -p` launch in this script (preflight, each build-next
#       iteration, the end-of-night telemetry-analysis pass) is gated by
#       mcp_trust_gate(), which refuses to launch unless (a) the working
#       tree's `.mcp.json` sha256 matches `.mcp.json.trusted-sha256`, AND
#       (b) both files are actually git-tracked with NO uncommitted
#       working-tree changes, AND (c) neither path is a symlink (git records
#       a symlink's target string, never dereferencing it, so a committed
#       clean symlink would otherwise dodge check (b) while sha256sum
#       follows it) — a bytes-only comparison is self-computable by the very
#       unattended agent this gate exists to constrain (it has commit access
#       in $workdir and could rewrite .mcp.json + regenerate a matching hash
#       without ever committing either). No `.mcp.json` present -> nothing
#       to gate, launches proceed. An untracked/uncommitted/symlinked trust
#       pair or a genuine hash mismatch all fail loud (abort before
#       preflight; halt the worker mid-run) rather than silently
#       auto-connecting an unreviewed MCP server.
#       RESIDUAL LIMITATION: with the symlink vector closed, this still does
#       not stop an agent with commit rights from committing its own
#       rewritten `.mcp.json` plus a matching, freshly-committed hash each
#       time — a complete fix needs a trust anchor the overnight agent
#       cannot mutate (signed tag / protected-branch commit / out-of-band
#       value). Recorded honestly, not built in this bead.
#       To (re)trust a legitimate `.mcp.json` change: review the diff, then
#         sha256sum .mcp.json | awk '{print $1}' > .mcp.json.trusted-sha256
#         git add .mcp.json .mcp.json.trusted-sha256 && git commit
#   SKIP_MCP_TRUST_CHECK=0   set 1 to bypass the gate (NOT recommended — this
#       reintroduces the exact silent-auto-connect risk claude-1bz found;
#       only for debugging, and only with a `.mcp.json` you already trust).
#
#   MCP_EXTERNAL_TRUST_ANCHOR=""  (claude-o7u) out-of-band trust anchor that
#       closes the residual gap the in-repo check above admits by design: a
#       commit-capable overnight identity can always produce a fresh, clean,
#       git-tracked, hash-matching `.mcp.json` + `.mcp.json.trusted-sha256`
#       pair on its own, because both live inside $workdir where it has
#       commit rights. Set this to an absolute path OUTSIDE the repo working
#       tree, holding just the trusted sha256, that this identity cannot
#       write — e.g. root-owned, mode 0444, created at container-build time
#       or by the human operator before the run:
#         sudo install -o root -g root -m 0444 /dev/stdin \
#           /etc/claude-mcp-trust/mcp.trusted-sha256 \
#           <<<"$(sha256sum .mcp.json | awk '{print $1}')"
#       When set, every mcp_trust_gate() call additionally requires the
#       anchor to exist as a non-symlink regular file, resolve outside
#       $workdir (so no `git add`/`commit` run inside the repo can ever
#       reach it), be unwritable by the identity running this script — the
#       anchor file itself, and every ancestor directory from its parent up
#       to `/` — checked directly rather than trusting the operator got
#       permissions right; an anchor that turns out to be writable anywhere
#       in that chain is REFUSED, since that provides none of the guarantee
#       it exists for — and sha256-match `.mcp.json`. Unset
#       (default): the in-repo check above still runs, but the residual
#       self-reauthorization gap is NOT closed — see mcp_trust_gate()'s
#       comment and tools/ollama-mcp/README.md's "Headless/unattended trust
#       behavior" section.
#
#   VERIFY_CMD=""            deterministic gate, e.g. "dotnet build && dotnet test"
#       Runs in the workdir (a) once at startup — red baseline aborts the worker
#       before any tokens are spent — and (b) after every claude run, BEFORE the
#       iteration counts as a success. Don't trust the model's claim that tests
#       pass; check. Empty = gate disabled (warned loudly).
#   PRE_ITERATION_CMD=""     runs in the workdir before EACH claude launch.
#       For the config-repo dogfood setup: PRE_ITERATION_CMD="./install.sh"
#       re-links newly added/removed skills/agents/commands so each fresh
#       iteration sees the current suite. Failure counts as a failed iteration
#       (claude is not launched on a broken setup step).
#   ANALYZE_TELEMETRY=1      after the work loop, run one fresh headless claude
#       on /analyze-telemetry <run-id> to mine the night's telemetry + session
#       artifacts for token-waste and file [token-efficiency] beads. Skipped if
#       zero iterations completed (nothing to analyze). Set 0 to disable.
#       PROM_URL / LOKI_URL are passed through for the aggregate queries.
#       Bounded separately from a full build iteration (it's a read-only mining
#       pass, not agentic work) via ANALYZE_MAX_TURNS / ANALYZE_TIMEOUT; its
#       cost is folded into the run's reported total spend, but is NOT checked
#       against MAX_TOTAL_COST_USD (the budget loop has already exited by the
#       time this runs).
#   ANALYZE_MAX_TURNS=30     turn cap for the telemetry-analysis pass specifically.
#   ANALYZE_TIMEOUT=20m      timeout for the telemetry-analysis pass specifically.
#   MAX_TURNS=150            per-run agentic turn cap (claude --max-turns)
#   MAX_TOTAL_COST_USD=50    whole-run budget; split evenly across workers.
#       Read from stream-json result events. NOTE: on a subscription plan the
#       figure is notional (what it would cost via API), but still works as a
#       relative consumption cap.
#   PARALLEL_WORKERS=1       >1 = each worker gets its own git worktree/branch.
#       REQUIREMENT: beads must serve claims from SHARED state (bd server mode /
#       shared store). Plain per-worktree .beads files do NOT see each other's
#       claims -> duplicate work. Keep 1 unless that's configured.
#   WORKTREE_BASE=<project>/.overnight-worktrees
#
# Logs: <project>/.overnight-logs/<timestamp>/w<N>-iter-NN.log (+ .result.txt),
#       per-worker summary, merged summary.log

set -u

PROJECT_DIR="$(cd "${1:-$PWD}" && pwd)" || exit 1
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
RUN_TIMEOUT="${RUN_TIMEOUT:-90m}"
MAX_CONSEC_FAILURES="${MAX_CONSEC_FAILURES:-3}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-15}"
PERMISSION_FLAGS="${PERMISSION_FLAGS:---permission-mode auto}"
STOP_FILE="${STOP_FILE:-$PROJECT_DIR/.stop-overnight}"
VERIFY_CMD="${VERIFY_CMD:-}"
PRE_ITERATION_CMD="${PRE_ITERATION_CMD:-}"
ANALYZE_TELEMETRY="${ANALYZE_TELEMETRY:-1}"
ANALYZE_MAX_TURNS="${ANALYZE_MAX_TURNS:-30}"
ANALYZE_TIMEOUT="${ANALYZE_TIMEOUT:-20m}"
MAX_TURNS="${MAX_TURNS:-150}"
MAX_TOTAL_COST_USD="${MAX_TOTAL_COST_USD:-50}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-1}"
WORKTREE_BASE="${WORKTREE_BASE:-$PROJECT_DIR/.overnight-worktrees}"

# ── OpenTelemetry: metrics + logs from every claude run → OTLP collector ────
OTEL_ENABLED="${OTEL_ENABLED:-1}"
if [ "$OTEL_ENABLED" = "1" ]; then
  export CLAUDE_CODE_ENABLE_TELEMETRY=1
  export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
  export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
  export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
  export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4317}"
  [ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ] && export OTEL_EXPORTER_OTLP_HEADERS
  # Default 60s intervals lose the tail of short runs; flush faster.
  export OTEL_METRIC_EXPORT_INTERVAL="${OTEL_METRIC_EXPORT_INTERVAL:-10000}"
  export OTEL_LOGS_EXPORT_INTERVAL="${OTEL_LOGS_EXPORT_INTERVAL:-5000}"
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$PROJECT_DIR/.overnight-logs/$RUN_ID"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.log"

WORKER_BUDGET="$(python3 -c "print(round($MAX_TOTAL_COST_USD / $PARALLEL_WORKERS, 2))")"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$SUMMARY"; echo "[$(date +%H:%M:%S)] $*"; }
wlog() { # wlog <worker-summary-file> <msg>
  echo "[$(date +%H:%M:%S)] $2" >> "$1"; echo "[$(date +%H:%M:%S)] [$(basename "$1" .log)] $2"
}

ready_count() { # ready_count <workdir>
  (cd "$1" && bd ready --json 2>/dev/null) | python3 -c '
import json,sys
try:
    data = json.load(sys.stdin)
    print(len(data) if isinstance(data, list) else -1)
except Exception:
    print(-1)
'
}

# Parse the final stream-json "result" event of a run.
# Prints: ok|<cost>|<turns>|<session_id>  or  err|... or none|0|0|
parse_result() { # parse_result <iter-log> <result-text-out>
  python3 - "$1" "$2" <<'PY'
import json, sys
log_path, out_path = sys.argv[1], sys.argv[2]
res = None
try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if isinstance(obj, dict) and obj.get("type") == "result":
                res = obj
except Exception:
    pass
if res is None:
    print("none|0|0|")
else:
    try:
        with open(out_path, "w") as out:
            out.write(str(res.get("result", "")))
    except Exception:
        pass
    status = "err" if res.get("is_error") else "ok"
    print(f"{status}|{res.get('total_cost_usd') or 0}|{res.get('num_turns') or 0}|{res.get('session_id') or ''}")
PY
}

# Sum the "complete: N successful" counts out of one or more worker-summary
# logs. Factored out (rather than inline) so it's independently testable —
# see tests/test_run_overnight.sh. Uses awk, not `bc`: bc is not installed in
# the devcontainer image, and a naive `grep -o '[0-9]*' | paste -sd+ - | bc`
# also breaks because grep's `*` quantifier matches the empty string at every
# non-digit position, feeding bc a string of stray `+`s it can't parse.
count_completed_iterations() { # count_completed_iterations <log-dir>
  local dir="$1" f total=0 n
  for f in "$dir"/worker-*.log; do
    [ -f "$f" ] || continue
    n="$(awk -F'complete: ' '/complete: [0-9]+ successful/ { split($2, a, " "); sum += a[1] } END { print sum + 0 }' "$f")"
    total=$((total + n))
  done
  echo "$total"
}

# Sum the "$<cost> spent" figures out of one or more worker-summary logs, so
# the end-of-night telemetry-analysis cost (below) can be reported alongside
# the work-loop spend instead of in isolation. awk for float arithmetic
# (bash can't do it, and this project already avoids `bc`).
total_worker_spend() { # total_worker_spend <log-dir>
  local dir="$1" f total=0 n
  for f in "$dir"/worker-*.log; do
    [ -f "$f" ] || continue
    n="$(awk -F'\\$' '/successful iteration\(s\), \$/ { split($2, a, " "); sum += a[1] } END { print sum + 0 }' "$f")"
    total="$(awk -v a="$total" -v b="$n" 'BEGIN { print a + b }')"
  done
  echo "$total"
}

verify() { # verify <workdir> <worker-summary> <label> ; returns VERIFY_CMD status
  [ -z "$VERIFY_CMD" ] && return 0
  local vlog="$LOG_DIR/$3.verify.log"
  ( cd "$1" && bash -c "$VERIFY_CMD" ) >"$vlog" 2>&1
  local st=$?
  [ $st -ne 0 ] && wlog "$2" "VERIFY FAILED ($3): see $vlog. Tail:" && tail -n 10 "$vlog" | sed 's/^/    /'
  return $st
}

# mcp_trust_gate <workdir> ; returns 0 (safe to launch headless claude -p) or
# 1 (refuse). Auditable pre-trust check (claude-9hl) for claude-1bz's finding
# that headless `claude -p` silently auto-connects a project's .mcp.json MCP
# servers with no trust prompt and no fail-closed behavior. Fail-closed
# equivalent of the interactive trust dialog: the working tree's .mcp.json
# must sha256-match a committed .mcp.json.trusted-sha256, AND both files must
# actually be tracked by git with no uncommitted working-tree changes — a
# hash-only comparison is self-computable by the very `/build-next` agent
# this loop runs unattended (or a prompt-injected tool call from an already-
# connected MCP server), which has commit access inside $workdir: it could
# rewrite .mcp.json, regenerate a matching hash, and never even commit either
# file, and a bytes-only check would trust that. No .mcp.json present ->
# nothing to auto-connect -> nothing to gate.
#
# Both paths must also be regular files, not symlinks: git records a
# symlink's target *string* as its blob and never dereferences it, so a
# committed, clean symlink would otherwise still pass the tracked+clean
# check below while sha256sum happily follows it — one commit swapping
# either path for a symlink into a writable location would let an agent
# rewrite the pointed-to content indefinitely afterward with NO further
# commits and NO git-diff signal, which is stealthier than (and was not
# covered by) the residual limitation below. This is now rejected outright.
#
# RESIDUAL LIMITATION (by design, not a bug — see tools/ollama-mcp/README.md):
# with the symlink vector closed, every rewrite this gate can be tricked by
# still requires its own fresh, auditable commit. This defends against
# accidental drift (stray hand-edit, bad merge) and mid-run tampering that
# isn't committed. It does NOT by itself defend against an agent that has
# commit rights in $workdir deliberately committing its own rewritten
# .mcp.json plus a matching, freshly-committed trust file each time — that
# requires pinning trust to something the overnight agent cannot mutate.
#
# CLOSED, OPT-IN, VIA claude-o7u: if MCP_EXTERNAL_TRUST_ANCHOR is set, this
# function also calls mcp_external_anchor_check() (below), which requires an
# additional sha256 anchor living OUTSIDE $workdir (so no commit made inside
# the repo can ever reach it) and unwritable by the identity running this
# script. A signed-tag or protected-branch anchor was considered instead
# (see the bead) but rejected for THIS repo's environment specifically: this
# repo's own commits are already GPG-signed with a key this same identity
# holds unprompted (`git log --show-signature`), and there is no CI/server-
# side branch protection reachable from a plain local git repo — so both
# would be self-satisfiable by the very identity they're meant to constrain.
# An out-of-workdir, permission-restricted file is the one anchor this
# sandbox can actually enforce without new external infrastructure. Left
# unset (the default — this mechanism cannot be provisioned with real
# separate credentials from inside an unattended run itself, only by a human
# or a build step with root), the limitation above stands undiminished.
mcp_trust_gate() {
  local workdir="$1" mcp_json trust_file actual expected f
  [ "${SKIP_MCP_TRUST_CHECK:-0}" = "1" ] && return 0
  mcp_json="$workdir/.mcp.json"
  trust_file="$workdir/.mcp.json.trusted-sha256"
  [ -f "$mcp_json" ] || return 0
  # Reject symlinks outright. git stores a symlink's *target string* as its
  # blob and never dereferences it, so a committed, clean symlink still
  # passes the tracked+clean check below — while sha256sum DOES follow the
  # link. One commit swapping either path for a symlink into a writable
  # location would let an agent rewrite the pointed-to content indefinitely
  # afterward with zero further commits and zero git-diff signal.
  if [ -L "$mcp_json" ] || [ -L "$trust_file" ]; then
    log "MCP TRUST GATE: refusing — .mcp.json / .mcp.json.trusted-sha256 must be regular files, not symlinks (a symlinked trust pair evades the tracked+clean check while sha256sum follows the link)."
    return 1
  fi
  if [ ! -f "$trust_file" ]; then
    log "MCP TRUST GATE: $mcp_json exists but $trust_file is missing — refusing headless claude -p launch (fail-closed; see tools/ollama-mcp/README.md 'Headless/unattended trust behavior'). After reviewing .mcp.json: sha256sum '$mcp_json' | awk '{print \$1}' > '$trust_file' && git -C '$workdir' add .mcp.json .mcp.json.trusted-sha256 && git -C '$workdir' commit."
    return 1
  fi
  # Both paths must be genuinely git-tracked and committed — an untracked or
  # locally-modified trust pair (however byte-correct) is not a reviewed
  # commit, so it's not trusted. Closes the untracked-file hole (this repo's
  # own .mcp.json.trusted-sha256 was untracked until this check existed) and
  # the mid-run self-reauthorization hole (rewrite + regenerate hash without
  # committing).
  for f in .mcp.json .mcp.json.trusted-sha256; do
    if ! git -C "$workdir" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      log "MCP TRUST GATE: $workdir/$f is not tracked by git — refusing headless claude -p launch (fail-closed). A trust anchor must be a reviewed commit, not a file that merely exists on disk. After reviewing: git -C '$workdir' add .mcp.json .mcp.json.trusted-sha256 && git -C '$workdir' commit."
      return 1
    fi
  done
  if ! git -C "$workdir" diff --quiet HEAD -- .mcp.json .mcp.json.trusted-sha256 2>/dev/null; then
    log "MCP TRUST GATE: .mcp.json and/or .mcp.json.trusted-sha256 have uncommitted working-tree changes in $workdir — refusing headless claude -p launch (fail-closed). Review the diff, then: git -C '$workdir' add .mcp.json .mcp.json.trusted-sha256 && git -C '$workdir' commit."
    return 1
  fi
  actual="$(sha256sum "$mcp_json" | awk '{print $1}')"
  expected="$(tr -d '[:space:]' < "$trust_file")"
  if [ "$actual" != "$expected" ]; then
    log "MCP TRUST GATE MISMATCH: $mcp_json sha256 ($actual) does not match committed $trust_file ($expected) — refusing headless claude -p launch. If this .mcp.json change is legitimate, review the diff, then: sha256sum '$mcp_json' | awk '{print \$1}' > '$trust_file' && git -C '$workdir' add .mcp.json .mcp.json.trusted-sha256 && git -C '$workdir' commit."
    return 1
  fi
  # claude-o7u: opt-in out-of-band layer. In-repo trust alone (above) is
  # self-satisfiable by this identity; skip unless an external anchor is
  # configured (see MCP_EXTERNAL_TRUST_ANCHOR docs at the top of this file).
  if [ -n "${MCP_EXTERNAL_TRUST_ANCHOR:-}" ]; then
    mcp_external_anchor_check "$workdir" "$actual" || return 1
  fi
  return 0
}

# mcp_external_anchor_check <workdir> <expected-sha256> — the claude-o7u
# out-of-band trust layer, called by mcp_trust_gate() only when
# MCP_EXTERNAL_TRUST_ANCHOR is set. Returns 0 only if the anchor:
#   (a) exists and is a plain, non-symlink regular file;
#   (b) resolves to a path OUTSIDE $workdir — so no `git add`/`commit` run
#       inside the repo being gated can ever reach it (a path pointed
#       *inside* $workdir would just be another in-repo file this identity
#       can commit, defeating the entire point);
#   (c) is NOT writable by the identity running this script, and neither is
#       ANY ancestor directory from the anchor's parent up to / (a writable
#       file could be overwritten directly; a writable immediate parent
#       lets it be unlinked and recreated; a writable grandparent-or-higher
#       lets the whole anchor_dir be renamed aside and replaced wholesale —
#       so every ancestor is checked, not just the immediate parent) —
#       checked directly rather than trusted, so a misconfigured anchor
#       that happens to be writable anywhere in its ancestry is loudly
#       REJECTED rather than silently accepted as if it provided real
#       separation; and
#   (d) sha256-matches the .mcp.json content mcp_trust_gate() just verified
#       against the in-repo pair (passed in as <expected-sha256> so this
#       function doesn't re-read/re-hash it).
mcp_external_anchor_check() {
  local workdir="$1" expected="$2" anchor="${MCP_EXTERNAL_TRUST_ANCHOR:-}"
  local anchor_dir_resolved real_anchor real_workdir actual_anchor d walk_root
  # _MCP_ANCHOR_WALK_ROOT_TEST_ONLY: internal test seam, NOT a documented
  # user-facing env var and not part of this script's normal operation —
  # defaults to "/" (the real filesystem root) always, in every real
  # invocation. It exists solely because tests/test_run_overnight.sh runs
  # as the same unprivileged `node` identity this whole mechanism exists to
  # constrain, with no real root available in this sandbox (see `sudo -l`:
  # scoped to one firewall script, nothing broader) to build a genuinely
  # root-owned ancestor chain — every writable-by-`node` tmpdir the test
  # suite can create sits under /tmp, which is itself world-writable, so an
  # unbounded walk to the true "/" would (correctly, but untestably here)
  # refuse every fixture the tests can construct. Overriding this variable
  # would weaken the real security property, so it is deliberately
  # undocumented outside this comment and this file's tests.
  walk_root="${_MCP_ANCHOR_WALK_ROOT_TEST_ONLY:-/}"
  if [ ! -e "$anchor" ]; then
    log "MCP TRUST GATE: MCP_EXTERNAL_TRUST_ANCHOR='$anchor' does not exist — refusing headless claude -p launch. An operator with write access this identity lacks must create it, e.g.: sudo install -o root -g root -m 0444 /dev/stdin '$anchor' <<<\"\$(sha256sum '$workdir/.mcp.json' | awk '{print \$1}')\""
    return 1
  fi
  if [ -L "$anchor" ]; then
    log "MCP TRUST GATE: MCP_EXTERNAL_TRUST_ANCHOR='$anchor' is a symlink — refusing (same rationale as the in-repo pair: git-style tracked+clean reasoning doesn't even apply here, but a symlink still lets the pointed-to content change without the anchor path itself changing)."
    return 1
  fi
  if [ ! -f "$anchor" ]; then
    log "MCP TRUST GATE: MCP_EXTERNAL_TRUST_ANCHOR='$anchor' is not a regular file — refusing."
    return 1
  fi
  real_workdir="$(cd "$workdir" 2>/dev/null && pwd -P)"
  if [ -z "$real_workdir" ]; then
    log "MCP TRUST GATE: could not resolve real path for workdir '$workdir' — refusing rather than guessing."
    return 1
  fi
  # Resolve (and validate) the anchor's containing directory BEFORE
  # concatenating the basename back on: if the inner `cd` fails,
  # anchor_dir_resolved is "" and we catch that here. (Concatenating
  # "/$(basename "$anchor")" onto an empty resolved-dir string, as an
  # earlier version of this check did, produces a non-empty path like
  # "/anchor.sha256" that slips past an emptiness guard on $real_anchor —
  # failing closed only by downstream coincidence, not by design.)
  anchor_dir_resolved="$(cd "$(dirname "$anchor")" 2>/dev/null && pwd -P)"
  if [ -z "$anchor_dir_resolved" ]; then
    log "MCP TRUST GATE: could not resolve MCP_EXTERNAL_TRUST_ANCHOR='$anchor' directory — refusing rather than guessing."
    return 1
  fi
  real_anchor="$anchor_dir_resolved/$(basename "$anchor")"
  case "$real_anchor" in
    "$real_workdir"|"$real_workdir"/*)
      log "MCP TRUST GATE: MCP_EXTERNAL_TRUST_ANCHOR='$anchor' resolves inside the repo working tree ($real_workdir) — refusing. An anchor reachable from inside \$workdir is just another file this identity can git-commit; it must live entirely outside the repo to provide any out-of-band guarantee."
      return 1
      ;;
  esac
  if [ -w "$anchor" ]; then
    log "MCP TRUST GATE: MCP_EXTERNAL_TRUST_ANCHOR='$anchor' is writable by the identity running this script ($(id -un 2>/dev/null || echo '?')) — refusing. An anchor this identity can write directly gives none of the separate-credential guarantee it exists for; fix ownership/permissions (e.g. a different owning user, mode 0444) so only a genuinely different identity can update it."
    return 1
  fi
  # Walk EVERY ancestor directory up to / (not just the immediate parent):
  # a writable grandparent (or higher) lets this identity `mv` the whole
  # anchor_dir aside, `mkdir` a fresh replacement, drop a fake hash in it,
  # and `chmod` it back read-only before the next gate check — an
  # immediate-parent-only check would report "not writable" and pass
  # despite the entire subtree having just been attacker-controlled.
  d="$anchor_dir_resolved"
  while true; do
    if [ -w "$d" ]; then
      log "MCP TRUST GATE: ancestor directory '$d' of MCP_EXTERNAL_TRUST_ANCHOR='$anchor' is writable by the identity running this script ($(id -un 2>/dev/null || echo '?')) — refusing. A writable ancestor anywhere above the anchor lets this identity replace the whole subtree (rename it aside, recreate it, drop a forged hash in, chmod back read-only) even if the anchor file and its immediate directory are themselves locked down; every directory from the anchor up to / must be unwritable by this identity."
      return 1
    fi
    [ "$d" = "/" ] || [ "$d" = "$walk_root" ] && break
    d="$(dirname "$d")"
  done
  actual_anchor="$(tr -d '[:space:]' < "$anchor" 2>/dev/null)"
  if [ "$actual_anchor" != "$expected" ]; then
    log "MCP TRUST GATE MISMATCH: MCP_EXTERNAL_TRUST_ANCHOR='$anchor' ($actual_anchor) does not match .mcp.json's actual sha256 ($expected) — refusing headless claude -p launch. Only an identity with write access to '$anchor' can update this anchor; that must be a deliberate, out-of-band action, not something this script or the agent it launches can do for itself."
    return 1
  fi
  return 0
}

run_worker() { # run_worker <index> <workdir>
  local idx="$1" workdir="$2"
  local wsum="$LOG_DIR/worker-$idx.log"
  local spent="0" consec=0 completed=0

  # Baseline gate: never burn a night on an already-red build.
  if ! verify "$workdir" "$wsum" "w$idx-baseline"; then
    wlog "$wsum" "Baseline verification is RED in $workdir — aborting worker before spending tokens."
    return 1
  fi

  # MCP trust gate (claude-9hl): refuse to launch headless claude -p at all
  # if workdir's .mcp.json isn't a reviewed, committed-trusted config.
  if ! mcp_trust_gate "$workdir"; then
    wlog "$wsum" "MCP trust gate failed in $workdir — see summary log for details; aborting worker before spending tokens."
    return 1
  fi

  local i
  for i in $(seq 1 "$MAX_ITERATIONS"); do
    [ -f "$STOP_FILE" ] && wlog "$wsum" "Stop file present — halting." && break

    if [ "$(python3 -c "print(1 if $spent >= $WORKER_BUDGET else 0)")" = "1" ]; then
      wlog "$wsum" "Budget share (\$$WORKER_BUDGET) reached at \$$spent — halting."
      break
    fi

    local n; n="$(ready_count "$workdir")"
    if [ "$n" = "0" ]; then
      wlog "$wsum" "No ready beads — done after $completed completed iteration(s)."
      break
    elif [ "$n" = "-1" ]; then
      wlog "$wsum" "Could not read 'bd ready' — halting rather than looping blind."
      break
    fi

    local tag; tag="w$idx-iter-$(printf '%02d' "$i")"
    local ilog="$LOG_DIR/$tag.log"

    if [ -n "$PRE_ITERATION_CMD" ]; then
      if ! ( cd "$workdir" && bash -c "$PRE_ITERATION_CMD" ) >>"$wsum" 2>&1; then
        consec=$((consec + 1))
        wlog "$wsum" "PRE_ITERATION_CMD failed ($consec consecutive) — skipping claude launch this iteration."
        if [ "$consec" -ge "$MAX_CONSEC_FAILURES" ]; then
          wlog "$wsum" "Hit $MAX_CONSEC_FAILURES consecutive failures — halting worker."
          break
        fi
        sleep "$SLEEP_BETWEEN"; continue
      fi
    fi

    # Re-check every iteration, not just at worker startup: a completed bead
    # could legitimately (or not) have modified .mcp.json — committed or not —
    # since the baseline check. Halt rather than launching on unreviewed drift
    # or an uncommitted self-reauthorization.
    if ! mcp_trust_gate "$workdir"; then
      wlog "$wsum" "MCP trust gate failed mid-run (.mcp.json / .mcp.json.trusted-sha256 no longer a clean, committed, matching pair) — halting worker rather than launching an unreviewed MCP config."
      break
    fi

    wlog "$wsum" "Iteration $i: $n ready bead(s); spent \$$spent of \$$WORKER_BUDGET. Launching claude..."

    ( cd "$workdir" && \
      OTEL_RESOURCE_ATTRIBUTES="service.name=overnight-runner,run.id=$RUN_ID,worker.id=w$idx" \
      timeout "$RUN_TIMEOUT" claude -p "/build-next --unattended" \
        $PERMISSION_FLAGS \
        --output-format stream-json --verbose \
        --max-turns "$MAX_TURNS" ) >"$ilog" 2>&1
    local status=$?

    local parsed; parsed="$(parse_result "$ilog" "$ilog.result.txt")"
    local rstate cost turns session
    IFS='|' read -r rstate cost turns session <<< "$parsed"
    spent="$(python3 -c "print(round($spent + $cost, 4))")"
    wlog "$wsum" "  exit=$status result=$rstate cost=\$$cost turns=$turns session=$session"

    if [ $status -ne 0 ] || [ "$rstate" != "ok" ]; then
      consec=$((consec + 1))
      [ $status -eq 124 ] && wlog "$wsum" "  TIMED OUT after $RUN_TIMEOUT."
      wlog "$wsum" "  Failure ($consec consecutive)."
      case "$PERMISSION_FLAGS" in *auto*)
        wlog "$wsum" "  (auto mode: headless classifier escalation terminates the run — if failures recur, inspect $ilog for denial messages)";;
      esac
      if [ "$consec" -ge "$MAX_CONSEC_FAILURES" ]; then
        wlog "$wsum" "Hit $MAX_CONSEC_FAILURES consecutive failures — halting worker."
        break
      fi
      sleep "$SLEEP_BETWEEN"; continue
    fi

    # Deterministic gate: the model saying "tests pass" is not evidence.
    if ! verify "$workdir" "$wsum" "$tag"; then
      ( cd "$workdir" && bd create "Build/tests RED after overnight iteration $tag (commit $(git rev-parse --short HEAD 2>/dev/null)); verify log: $LOG_DIR/$tag.verify.log" -p 0 ) >>"$wsum" 2>&1
      wlog "$wsum" "Verification gate failed — filed a P0 fix bead and halting worker (a broken build poisons later tasks)."
      break
    fi

    consec=0; completed=$((completed + 1))
    if [ -s "$ilog.result.txt" ]; then
      wlog "$wsum" "  Report: $(head -c 300 "$ilog.result.txt" | tr '\n' ' ')"
    fi
    sleep "$SLEEP_BETWEEN"
  done

  wlog "$wsum" "Worker $idx complete: $completed successful iteration(s), \$$spent spent, remaining ready: $(ready_count "$workdir")."
}

# ── main ─────────────────────────────────────────────────────────────────────
# Guarded so tests can `source` this file (to reuse count_completed_iterations /
# total_worker_spend / parse_result etc. directly) without kicking off the
# actual overnight workflow — the guard is the standard `[[ $0 == source ]]`
# idiom, not a behavior change for normal invocation (`./run-overnight.sh` or
# `bash run-overnight.sh` still runs everything below exactly as before).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then

# claude-o7u: _MCP_ANCHOR_WALK_ROOT_TEST_ONLY is an internal test-only seam
# (see mcp_external_anchor_check()) that bounds the external-anchor
# ancestor walk short of the real filesystem root — tests/test_run_overnight.sh
# sets it because its scratch fixtures live under /tmp, which this
# unprivileged identity can't otherwise make "unwritable all the way up"
# without real root. It must NEVER affect a real invocation: unset it here,
# before the first mcp_trust_gate call, so an inherited value (leaked from
# a prior `source`d test run in the same shell, a sloppy CI step, etc.)
# can't silently shrink the walk and reproduce the exact immediate-parent-
# only bypass Finding 1 (claude-o7u round 1) closed. The test suite
# `source`s this file rather than executing it, so this line never runs
# under test.
if [ -n "${_MCP_ANCHOR_WALK_ROOT_TEST_ONLY:-}" ]; then
  log "WARNING: _MCP_ANCHOR_WALK_ROOT_TEST_ONLY was set in the environment ('$_MCP_ANCHOR_WALK_ROOT_TEST_ONLY') for this real run — this test-only seam must never be set outside tests/test_run_overnight.sh; it would bound the claude-o7u external-anchor ancestor walk short of the real filesystem root. Unsetting it now."
  unset _MCP_ANCHOR_WALK_ROOT_TEST_ONLY
fi

log "Overnight run $RUN_ID: $PARALLEL_WORKERS worker(s), $MAX_ITERATIONS iters/worker, \$$MAX_TOTAL_COST_USD budget (\$$WORKER_BUDGET/worker), max-turns $MAX_TURNS/run."
log "Permissions: $PERMISSION_FLAGS | OTel: $([ "$OTEL_ENABLED" = "1" ] && echo "on → $OTEL_EXPORTER_OTLP_ENDPOINT ($OTEL_EXPORTER_OTLP_PROTOCOL)" || echo "off")"
[ -z "$VERIFY_CMD" ] && log "WARNING: VERIFY_CMD is empty — the deterministic verification gate is DISABLED. Set e.g. VERIFY_CMD='dotnet build && dotnet test'."
if [ -z "${MCP_EXTERNAL_TRUST_ANCHOR:-}" ]; then
  log "WARNING: MCP_EXTERNAL_TRUST_ANCHOR is not set (claude-o7u) — the MCP trust gate's in-repo check alone cannot stop this identity from committing its own rewritten .mcp.json + matching trust hash. Set MCP_EXTERNAL_TRUST_ANCHOR to a file outside the repo, unwritable by this identity, to close that gap."
else
  log "MCP external trust anchor (claude-o7u): $MCP_EXTERNAL_TRUST_ANCHOR"
fi
log "Stop file: $STOP_FILE"

# MCP trust gate (claude-9hl): fail closed BEFORE even the preflight probe —
# preflight itself launches a headless claude -p, which auto-connects
# .mcp.json MCP servers just as much as the real work loop does.
# (mcp_trust_gate itself honors SKIP_MCP_TRUST_CHECK=1 as a documented,
# NOT-recommended bypass.)
if ! mcp_trust_gate "$PROJECT_DIR"; then
  log "Aborting before preflight/loop — see MCP TRUST GATE message above. Override with SKIP_MCP_TRUST_CHECK=1 only if you understand the risk (claude-1bz)."
  exit 1
fi

# Preflight: fail at launch, not silently all night. Auto mode in particular
# needs v2.1.83+, a Team/Enterprise plan, and the Anthropic API provider.
if [ "${SKIP_PREFLIGHT:-0}" != "1" ]; then
  log "Preflight: probing claude with current permission flags..."
  if ( cd "$PROJECT_DIR" && timeout 5m claude -p "Reply with exactly: OK" $PERMISSION_FLAGS --max-turns 1 ) >"$LOG_DIR/preflight.log" 2>&1; then
    log "Preflight OK."
  else
    log "Preflight FAILED — see $LOG_DIR/preflight.log. If using auto mode, check plan/version/API-provider requirements, or override with PERMISSION_FLAGS='--dangerously-skip-permissions' (container advised). Aborting before the loop."
    exit 1
  fi
fi

if [ "$PARALLEL_WORKERS" -le 1 ]; then
  run_worker 1 "$PROJECT_DIR"
else
  log "Parallel mode: workers use git worktrees under $WORKTREE_BASE on branches overnight/$RUN_ID-w<N>."
  log "REMINDER: parallel claiming is only safe if bd serves SHARED state (server mode); per-worktree .beads files do not see each other's claims."
  mkdir -p "$WORKTREE_BASE"
  pids=()
  for w in $(seq 1 "$PARALLEL_WORKERS"); do
    WT="$WORKTREE_BASE/w$w"
    if [ ! -d "$WT" ]; then
      git -C "$PROJECT_DIR" worktree add -b "overnight/$RUN_ID-w$w" "$WT" HEAD >>"$SUMMARY" 2>&1 \
        || { log "Worker $w: worktree creation failed — skipping."; continue; }
    fi
    run_worker "$w" "$WT" &
    pids+=($!)
    sleep 3
  done
  wait "${pids[@]}" 2>/dev/null
  log "Worker branches (merge or discard in the morning):"
  git -C "$PROJECT_DIR" branch --list "overnight/$RUN_ID-*" | sed 's/^/    /' | tee -a "$SUMMARY"
fi

# Merge per-worker summaries into the main one for a single morning read.
for f in "$LOG_DIR"/worker-*.log; do
  [ -f "$f" ] && { echo "── $(basename "$f") ──" >> "$SUMMARY"; cat "$f" >> "$SUMMARY"; }
done

# End-of-night telemetry analysis: one fresh headless pass over the whole run's
# telemetry + session artifacts, filing [token-efficiency] beads. Runs AFTER the
# loop (so the run's OTel data has flushed) and only if any iteration completed.
# Bounded tighter than a full build iteration (ANALYZE_MAX_TURNS/ANALYZE_TIMEOUT,
# not MAX_TURNS/RUN_TIMEOUT) since it's a read-only mining pass, not agentic work.
worker_spend="$(total_worker_spend "$LOG_DIR")"
analyze_cost="0"
if [ "$ANALYZE_TELEMETRY" = "1" ]; then
  completed_total="$(count_completed_iterations "$LOG_DIR")"
  if [ "${completed_total:-0}" -gt 0 ] && ! mcp_trust_gate "$PROJECT_DIR"; then
    log "Skipping telemetry analysis — MCP trust gate failed (see MCP TRUST GATE message above); refusing to launch this headless claude -p pass too."
  elif [ "${completed_total:-0}" -gt 0 ]; then
    log "Analyzing telemetry for run $RUN_ID ($completed_total iteration(s) completed)..."
    ANALYZE_LOG="$LOG_DIR/analyze-telemetry.log"
    ( cd "$PROJECT_DIR" && \
      PROM_URL="${PROM_URL:-http://prometheus:9090}" LOKI_URL="${LOKI_URL:-http://loki:3100}" \
      OTEL_RESOURCE_ATTRIBUTES="service.name=overnight-analyzer,run.id=$RUN_ID" \
      timeout "$ANALYZE_TIMEOUT" claude -p "/analyze-telemetry $RUN_ID" \
        $PERMISSION_FLAGS --output-format stream-json --verbose --max-turns "$ANALYZE_MAX_TURNS" \
    ) >"$ANALYZE_LOG" 2>&1
    if [ $? -eq 0 ]; then
      log "Telemetry analysis done. Filed beads: bd list --label token-efficiency"
      analyze_parsed="$(parse_result "$ANALYZE_LOG" "$ANALYZE_LOG.result.txt")"
      IFS='|' read -r _ analyze_cost _ _ <<< "$analyze_parsed"
      analyze_cost="${analyze_cost:-0}"
      [ -s "$ANALYZE_LOG.result.txt" ] && wlog "$SUMMARY" "  $(head -c 400 "$ANALYZE_LOG.result.txt" | tr '\n' ' ')"
    else
      log "Telemetry analysis failed (see $ANALYZE_LOG) — non-fatal."
    fi
  else
    log "No completed iterations — skipping telemetry analysis."
  fi
fi
total_reported_cost="$(awk -v w="$worker_spend" -v a="$analyze_cost" 'BEGIN { print w + a }')"
log "Total reported cost this run: \$$total_reported_cost (workers: \$$worker_spend, telemetry analysis: \$$analyze_cost). NOTE: the analysis pass is not itself checked against MAX_TOTAL_COST_USD (the budget loop has already exited by the time it runs)."

log "Run complete. Review $LOG_DIR, 'bd ready', Question:/fix + [token-efficiency] beads, and any worker branches."

fi # end BASH_SOURCE guard