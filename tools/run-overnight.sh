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
#       ACCEPTED RESIDUAL LIMITATION: checked purely by existence, same-UID
#       writable by every worker's own headless claude -p agent — any worker
#       can touch this (or the internal two-stage-cancel flag file described
#       next to _OVERNIGHT_STOP_FLAG_FILE's definition, same exposure) and
#       halt every other worker. No UID/sandbox boundary exists between main
#       and the worker agents here to prevent it; the accepted mitigation is
#       that a flag-file-observed halt is logged LOUDLY and distinguishably
#       from a genuine operator Ctrl+C in the top-level summary (see
#       run_worker's graceful-stop check) rather than left silent.
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
#       time this runs). Immediately before this pass (when OTEL_ENABLED=1),
#       check_telemetry_health() probes Prometheus's /-/healthy and the
#       collector's OTLP port over the network and logs a WARNING into the
#       summary if either is unreachable -- see that function for why (a
#       bounded OOM-restart budget on those services, claude-saz round 3)
#       and why it's a network probe rather than a `docker compose ps` (no
#       docker socket in this container, deliberately). It also flags a
#       narrower drift class (claude-muk): a bind-mounted otel-collector/
#       prometheus config edit (e.g. metric_expiration) that landed on disk
#       AFTER the sidecar containers were last started -- otelcol/Prometheus
#       read config once at process start and never hot-reload, so a stale
#       container silently keeps the OLD behavior with no signal. Detected by
#       symptom (a completed iteration's session_id vanishing from Prometheus
#       well under the currently configured metric_expiration), not by
#       docker-inspecting container start time (same no-docker-socket
#       constraint as above).
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

# claude-14w (review round 2, quality/security finding): PROJECT_DIR is
# ALWAYS (re)computed fresh from $1 here — an already-exported PROJECT_DIR in
# the environment is deliberately ignored at top level. Generic-sounding names
# like PROJECT_DIR are exactly the kind of thing an operator's shell, a CI
# job, a devcontainer, or a wrapper script might already have exported; if we
# preferred an inherited value unconditionally, a plain
# `./run-overnight.sh /some/other/project` would silently ignore its own `$1`
# and operate on whatever stale PROJECT_DIR happened to be set — a surprising,
# hard-to-diagnose regression, and (since PROJECT_DIR feeds mkdir/paths below)
# unwanted env-influenced path surface.
#
# The ONE caller that legitimately needs to hand a worker subprocess the
# exact PROJECT_DIR main already resolved is main's own parallel launch block
# (below), which re-sources this file in a brand-new `bash -c` process whose
# own $1 is that worker's SELF_PATH/args tuple, NOT a project directory — so
# recomputing from $1 there would try to `cd` into a script path and abort
# the worker outright. That path is signaled via the distinctly-named
# _OVERNIGHT_IS_WORKER=1 + _OVERNIGHT_WORKER_PROJECT_DIR, NOT via PROJECT_DIR
# itself, so normal top-level invocations remain immune to environment
# pollution under the generic name.
PROJECT_DIR="$(cd "${1:-$PWD}" && pwd)" || exit 1
# Only main's own parallel launch block sets _OVERNIGHT_IS_WORKER=1 (along
# with _OVERNIGHT_WORKER_PROJECT_DIR/_OVERNIGHT_WORKER_RUN_ID, set just below
# once RUN_ID is computed) before re-sourcing this file for a worker
# subprocess — see that block's docstring. Everyone else (a normal top-level
# invocation, and the test suite's own `source`ing of this file, neither of
# which sets _OVERNIGHT_IS_WORKER) gets the freshly-computed value above,
# regardless of what happens to be exported under the generic PROJECT_DIR
# name.
if [ "${_OVERNIGHT_IS_WORKER:-0}" = "1" ]; then
  PROJECT_DIR="$_OVERNIGHT_WORKER_PROJECT_DIR"
fi
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

# ── Signal handling (claude-23n / claude-14w): two-stage Ctrl+C cancel ──────
# 1st Ctrl+C: stop launching new iterations, let the in-flight claude finish,
#   then exit. 2nd Ctrl+C: hard-kill the in-flight claude (+ its `timeout`
#   wrapper) right now. Either way: skip the end-of-night /analyze-telemetry
#   pass, but still merge worker summaries (finalize) + check_telemetry_health,
#   and exit non-zero. Installed as an actual `trap` only inside the
#   BASH_SOURCE guard in main (below) — sourcing this file for tests must not
#   install a trap in the sourcing shell. These globals plus
#   register_pgid/deregister_pgid/run_in_pgroup/finalize (defined further
#   down, all side-effect-free to merely *source*) are the shared contract.
#   claude-23n wired the single-worker path, where run_worker executes
#   directly inside main's own process, so these globals (being ordinary bash
#   variables) are naturally shared with the trap. claude-14w extends this to
#   PARALLEL_WORKERS>1: each worker there is a genuinely SEPARATE process
#   (its own private copy of every global below), so main's trap coordinates
#   with them via two channels that DO cross process boundaries instead: the
#   shared _OVERNIGHT_STOP_FLAG_FILE (graceful) and `kill -TERM -- -<pgid>`
#   against each worker's own registered process group (hard-kill) — see
#   run_worker_in_pgroup(), _overnight_worker_term_handler(), and the
#   parallel launch block in main for the full mechanism.
_OVERNIGHT_INTERRUPT_COUNT=0
_OVERNIGHT_GRACEFUL_STOP=0
_OVERNIGHT_PGIDS=()
# claude-23n review F3: guards finalize() against a double-append if a 2nd
# Ctrl+C lands during the normal end-of-script tail (which already called
# finalize() once) — see finalize()'s docstring.
_OVERNIGHT_FINALIZED=0
# claude-23n review F2: bounded SIGTERM-then-SIGKILL grace period (seconds)
# for the hard-kill path — overridable for tests, not documented as a public
# knob.
_OVERNIGHT_KILL_GRACE_SECS="${_OVERNIGHT_KILL_GRACE_SECS:-5}"
# claude-14w: the ANALOGOUS grace period, but for a parallel worker leader's
# OWN local cleanup of its own nested claude/timeout session (see
# _overnight_worker_term_handler() below) when it gets SIGTERM'd by main's
# hard-kill. Deliberately much shorter than _OVERNIGHT_KILL_GRACE_SECS above:
# main's outer grace/escalation loop polls whether each worker's pgid is
# still alive and SIGKILLs it once ITS grace period elapses. If the worker
# leader were still mid-cleanup (waiting on ITS OWN inner grace period) when
# main's outer grace expires, main could SIGKILL the worker leader before it
# finishes tearing down its own nested grandchild, orphaning it. Keeping this
# knob meaningfully smaller than the outer one gives the inner cleanup room
# to always finish first.
_OVERNIGHT_WORKER_KILL_GRACE_SECS="${_OVERNIGHT_WORKER_KILL_GRACE_SECS:-2}"

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

# claude-14w (review round 2): RUN_ID is ALWAYS (re)computed fresh here too —
# same reasoning as PROJECT_DIR above. RUN_ID is interpolated unescaped into
# LOG_DIR (feeding mkdir -p/$SUMMARY) and into the git branch name
# overnight/$RUN_ID-w<N>, so an inherited RUN_ID under the generic name would
# be new path/ref-name surface an operator's shell, CI job, or wrapper script
# could influence. Only a worker subprocess (_OVERNIGHT_IS_WORKER=1, set by
# main's parallel launch block below, together with _OVERNIGHT_WORKER_RUN_ID
# carrying the exact value main computed) adopts an inherited identity —
# without this, a worker would stamp its OWN fresh `date` timestamp, landing
# its logs, its session markers, and its OTEL_RESOURCE_ATTRIBUTES run.id
# under a DIFFERENT RUN_ID/LOG_DIR than the main run that spawned it —
# silently splitting one run's telemetry/logs across two directories. The
# inherited value is validated against a strict timestamp shape before use
# (belt-and-suspenders against a corrupted/injected internal handoff — this
# can never fire in normal operation since main always sets it from its own
# `date` call just above).
if [ "${_OVERNIGHT_IS_WORKER:-0}" = "1" ]; then
  case "$_OVERNIGHT_WORKER_RUN_ID" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *)
      echo "run-overnight.sh: internal error: _OVERNIGHT_WORKER_RUN_ID ('${_OVERNIGHT_WORKER_RUN_ID:-}') is not a YYYYMMDD-HHMMSS timestamp — refusing to trust it as RUN_ID." >&2
      exit 1
      ;;
  esac
  RUN_ID="$_OVERNIGHT_WORKER_RUN_ID"
else
  RUN_ID="$(date +%Y%m%d-%H%M%S)"
fi
LOG_DIR="$PROJECT_DIR/.overnight-logs/$RUN_ID"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/summary.log"
# claude-14w: internal flag FILE (distinct from the user-facing $STOP_FILE —
# do not conflate the two) that lets a graceful-stop request cross process
# boundaries. _OVERNIGHT_GRACEFUL_STOP (below) is an in-memory flag that only
# the process that sets it can see — fine for the single-worker path, where
# run_worker executes directly inside main's own process, but useless for a
# PARALLEL_WORKERS>1 worker leader, which is a SEPARATE process (see main's
# parallel launch block) with its own private copy of every global. This
# path is a pure function of LOG_DIR, which is itself now guaranteed
# identical across main and every worker (see RUN_ID/PROJECT_DIR above), so
# no separate export is needed for it to resolve to the same file everywhere.
#
# ACCEPTED RESIDUAL LIMITATION (claude-14w review, finding 2 — by design, not
# a bug, same spirit as the MCP-trust-gate residual limitation documented
# above): this file is checked purely by EXISTENCE, with no authenticity
# check, and it lives under $LOG_DIR — same-UID writable by every worker's
# own headless `claude -p` agent process. A misbehaving or prompt-injected
# worker agent could therefore `touch` it directly and cause every sibling
# worker (and the main launch loop) to halt gracefully after their current
# iteration — a cross-worker griefing/DoS. There is no UID/sandbox boundary
# between main and the worker agents in this environment to enforce against
# that (every worker leader and its nested claude run as the same identity
# as main), so an options that requires one is not achievable here. This is
# NOT a new privilege, though: the pre-existing user-facing $STOP_FILE
# mechanism already grants any worker/agent the identical "touch a file,
# halt every worker" capability with no authenticity check either — this
# flag file just extends the same, already-accepted exposure to the
# in-process graceful-stop path. The mitigation actually taken (see the
# graceful-stop check in run_worker's iteration loop, and the matching check
# in main's parallel launch loop) is to make a flag-file-observed halt LOUD
# in main's own top-level summary — distinguishable from a genuine
# in-process operator Ctrl+C/SIGTERM — so a sabotaged night is visible
# rather than silently indistinguishable from a clean one.
_OVERNIGHT_STOP_FLAG_FILE="$LOG_DIR/.graceful-stop"

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

# _duration_to_seconds <duration-string> — best-effort parser for the Go-style
# durations this repo's configs actually use (h/m/s, e.g. "24h", "5m30s"; see
# otel-collector-config.yaml's metric_expiration). Prints seconds to stdout on
# success; prints nothing and returns 1 if the string doesn't parse — callers
# must treat an empty result as "couldn't determine", not as 0 (0 would make
# every drift check fire). Requires the ENTIRE string to be consumed by
# recognized h/m/s tokens — "24hXYZ" (or any value sed left trailing junk on)
# must fail, not silently parse as "24h", since this return value directly
# gates a security-relevant comparison downstream.
#
# Review round 2, finding 1: `num` is digit-only (regex-captured) but that
# does NOT exclude a leading zero — bash `$(( ))` treats a leading-zero
# numeral as OCTAL, so a value like "08" (not a valid octal digit) would
# raise a fatal "value too great for base" error that kills the whole script
# in non-interactive bash (not just this function), and a value like "010"
# (valid octal) would silently miscompute as 8 instead of 10. Force base-10
# explicitly via `10#$num` in every arithmetic branch below so a leading zero
# in a config file (or anywhere else this parser is ever pointed) can never
# hit octal interpretation.
_duration_to_seconds() {
  local dur total=0 num unit
  dur="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  [ -n "$dur" ] || return 1
  while [[ "$dur" =~ ^([0-9]+)(h|m|s) ]]; do
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
      h) total=$((total + 10#$num * 3600));;
      m) total=$((total + 10#$num * 60));;
      s) total=$((total + 10#$num));;
    esac
    dur="${dur#"${BASH_REMATCH[0]}"}"
  done
  if [ "$total" -gt 0 ] && [ -z "$dur" ]; then echo "$total"; else return 1; fi
}

# record_session_marker <session_id> — appends "<epoch>|<session_id>" to
# $LOG_DIR/session-markers.log for each successfully completed iteration.
# Purely a small breadcrumb trail for check_telemetry_health()'s claude-muk
# drift check below: it needs to know when a given session_id's telemetry was
# last legitimately produced, so it can ask "should this still be visible in
# Prometheus right now, per the config on disk?" Cheap append; degrades to a
# no-op if OTel is off or the session id is empty (nothing to mark).
#
# Root-cause validation (review round 1, finding 1): $LOG_DIR lives under
# $PROJECT_DIR, which the very unattended worker this script's MCP trust gate
# exists to constrain can write to. check_telemetry_health() later feeds a
# marker's epoch field straight into bash arithmetic and its session field
# straight into a PromQL query string, so a malformed/hostile line must never
# reach the markers file in the first place — reject anything that isn't a
# plain token up front, rather than trusting read-side validation alone.
record_session_marker() { # record_session_marker <session_id>
  [ "$OTEL_ENABLED" = "1" ] || return 0
  local session="${1:-}"
  [ -n "$session" ] || return 0
  case "$session" in
    *[!A-Za-z0-9_.-]*)
      log "Telemetry health: refusing to record a session marker — session id contains unexpected characters (expected only [A-Za-z0-9_.-]): '${session:0:80}'"
      return 0
      ;;
  esac
  echo "$(date +%s)|$session" >> "$LOG_DIR/session-markers.log"
}

# check_telemetry_health — end-of-run visibility for a specific silent-data-
# loss risk (claude-saz round 3): otel-collector and prometheus (in the
# sidecar compose stack, .devcontainer/docker-compose.yml) now carry a
# deploy.resources.limits.memory cap + restart: on-failure:5, added so an
# unexpected metric-cardinality blow-up (e.g. from this same bead's
# metric_expiration: 5m -> 24h change) gets OOM-killed and restarted loudly
# instead of silently exhausting host memory. But on-failure:5 is a BOUNDED
# restart budget -- if it's ever exhausted (or either service is down for any
# other reason: bad config, host resource pressure, ...), nothing previously
# surfaced that to the operator until a *gap* in the morning telemetry was
# noticed after the fact, which is exactly the silent-data-loss failure mode
# this bead exists to fix, just via a different cause than the original
# premature-series-expiry bug.
#
# This can't be a `docker compose ps otel-collector prometheus` check: this
# script runs inside the `devcontainer` compose service, which has no
# /var/run/docker.sock mount and no docker CLI installed -- deliberately, per
# the sandbox model (see .devcontainer/init-firewall.sh and
# container-infra's least-privilege default) -- the container this script
# runs in is the thing BEING managed by compose, not something with
# reflexive access back to the engine that manages it. Handing it the docker
# socket just to make this one check possible would be a far larger
# privilege escalation (docker.sock access is root-equivalent on the host)
# than the blind spot it would close.
#
# Instead, probe the same two symptoms this bead's telemetry pipeline lives
# or dies by, over the plain compose network this container already uses to
# export telemetry (see observability-stack's container-networking notes):
# Prometheus's own /-/healthy, and whether anything is actually listening on
# the collector's OTLP port. Both "restart budget exhausted" and "down for
# some other reason" look identical from here: a reachable "no" -- which is
# the operator-relevant signal (don't trust this run's telemetry) regardless
# of cause.
check_telemetry_health() {
  [ "$OTEL_ENABLED" = "1" ] || return 0

  local prom_url="${PROM_URL:-http://prometheus:9090}"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "$prom_url/-/healthy" >/dev/null 2>&1; then
      log "Telemetry health: Prometheus ($prom_url) OK."
    else
      log "TELEMETRY HEALTH WARNING: Prometheus ($prom_url/-/healthy) did not respond healthy at end of run. If tonight's metrics look sparse or missing session_ids, don't assume the pipeline was just quiet -- check 'docker compose ps prometheus' and its restart count (it now has a memory cap + restart: on-failure:5; that budget may have been exhausted, or it may be down for another reason)."
    fi
  else
    log "Telemetry health: curl not found — skipping Prometheus /-/healthy check."
  fi

  local otlp_endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://otel-collector:4317}"
  local otlp_hostport="${otlp_endpoint#*://}"
  local otlp_host="${otlp_hostport%%:*}"
  local otlp_port="${otlp_hostport##*:}"
  otlp_port="${otlp_port%%/*}"
  if [ -n "$otlp_host" ] && [ -n "$otlp_port" ]; then
    if (exec 3<>"/dev/tcp/$otlp_host/$otlp_port") 2>/dev/null; then
      exec 3<&- 3>&- 2>/dev/null
      log "Telemetry health: otel-collector OTLP port ($otlp_host:$otlp_port) accepting connections."
    else
      log "TELEMETRY HEALTH WARNING: otel-collector OTLP port ($otlp_host:$otlp_port) did not accept a connection at end of run. Exports since it went down were dropped SILENTLY — the OTel SDK does not retry-and-fail-loud on a dead endpoint (see this script's OTEL_ENABLED docs above). Check 'docker compose ps otel-collector' and its restart count (memory cap + restart: on-failure:5 — that budget may have been exhausted, or it may be down for another reason)."
    fi
  else
    log "Telemetry health: could not parse host/port from OTEL_EXPORTER_OTLP_ENDPOINT='$otlp_endpoint' — skipping otel-collector reachability check."
  fi

  # claude-muk: config-vs-observed-behavior drift, a follow-up from
  # claude-mqp's verification pass. otelcol/Prometheus (see above) read their
  # bind-mounted config (.devcontainer/otel-collector-config.yaml,
  # .devcontainer/prometheus.yml) once at process start and do NOT hot-reload
  # on file change. claude-saz bumped metric_expiration 5m -> 24h specifically
  # so a completed iteration's session_id survives Prometheus for the whole
  # run + the end-of-night analyze-telemetry pass -- but a collector container
  # that was already running BEFORE that edit landed on disk keeps enforcing
  # the OLD, much shorter expiration silently: nothing before this check ever
  # surfaced that "config on disk" and "config actually in effect" had
  # diverged, and claude-mqp only caught it by manually bisecting container
  # start time against config-file mtime.
  #
  # This can't reuse that bisection here either: same as the docstring above
  # explains for `docker compose ps`, this container has no docker
  # socket/CLI, so there is no `docker inspect --format '{{.State.StartedAt}}'`
  # to compare against a config mtime from in here.
  #
  # So probe the SYMPTOM instead of the root cause (more robust to whatever
  # config knob causes the next version of this bug): among every session_id
  # this run has completed (record_session_marker() above), find the NEWEST
  # one that's old enough to judge yet still within the metric_expiration
  # currently on disk, and if it's already gone from Prometheus, the running
  # collector cannot be honoring the config on disk -- i.e. it predates it.
  #
  # Review round 1, finding 3: probing only the globally-oldest marker ages
  # that marker's elapsed time past expiration_secs on a long run while
  # fresher, still-in-window markers keep arriving -- silently going quiet
  # exactly when this check matters most, indistinguishable from "never
  # wired up". Walking every marker and taking the newest in-window one keeps
  # this check live for the whole run instead of firing once near the start.
  local markers="$LOG_DIR/session-markers.log"
  if [ ! -s "$markers" ]; then
    log "Telemetry health: no completed-iteration session markers recorded — skipping config-drift check (nothing to probe)."
  elif ! command -v curl >/dev/null 2>&1; then
    log "Telemetry health: curl not found — skipping config-drift check."
  else
    local otel_cfg="$PROJECT_DIR/.devcontainer/otel-collector-config.yaml"
    local expiration_str expiration_secs
    expiration_str="$(sed -n 's/^[[:space:]]*metric_expiration:[[:space:]]*\([^#[:space:]]*\).*/\1/p' "$otel_cfg" 2>/dev/null | head -n1)"
    expiration_secs="$(_duration_to_seconds "$expiration_str")"
    if [ -z "$expiration_secs" ]; then
      log "Telemetry health: could not read/parse metric_expiration from $otel_cfg — skipping config-drift check."
    else
      # Review round 1, finding 1: $markers lives under $PROJECT_DIR, so a
      # line here is only as trustworthy as the unattended worker writing it
      # (the exact thing mcp_trust_gate elsewhere in this script exists to
      # constrain). record_session_marker() already refuses to write a
      # malformed line, but this loop re-validates on read too (defense in
      # depth, and it's the only thing standing between a hand-edited/
      # corrupted markers file and `elapsed=$((now - marked_epoch))` below --
      # bash arithmetic recursively evaluates a variable's value, so an
      # unvalidated field there is a command-injection vector, not just a
      # `set -u` crash risk). Skip (don't warn on, don't crash on) any line
      # that fails either check.
      #
      # Review round 2, finding 1: "all digits" alone is NOT enough — a
      # leading zero (e.g. "08") makes bash's `$(( ))` treat the value as
      # OCTAL, and "08"/"09" aren't even valid octal digits, so
      # `$((now - epoch))` would raise a fatal "value too great for base"
      # error that kills the whole script (not just this function) in
      # non-interactive bash, silently skipping the end-of-night telemetry
      # analysis and "Run complete" summary that run unconditionally after
      # this. Force base-10 explicitly via `10#$epoch` so a leading zero can
      # never be misread as octal, whether that's a hostile line or an
      # entirely innocent one (e.g. a future caller formatting epochs
      # zero-padded).
      local now; now="$(date +%s)"
      local epoch session elapsed best_elapsed="" best_session=""
      local total_lines=0 valid_lines=0
      while IFS='|' read -r epoch session; do
        [ -n "$epoch" ] || [ -n "$session" ] || continue
        total_lines=$((total_lines + 1))
        case "$epoch" in
          ''|*[!0-9]*) continue ;;
        esac
        case "$session" in
          ''|*[!A-Za-z0-9_.-]*) continue ;;
        esac
        valid_lines=$((valid_lines + 1))
        elapsed=$((now - 10#$epoch))
        # Only judge sessions that (a) are well clear of scrape/export lag
        # (10s scrape interval, 10s metric export interval — 120s is
        # generous headroom, not a tight race) and (b) should still be
        # within the configured expiration window; outside that window
        # "missing" is expected, not drift. Among candidates, keep the
        # smallest elapsed (i.e. newest) so the probe stays fresh all run.
        if [ "$elapsed" -ge 120 ] && [ "$elapsed" -lt "$expiration_secs" ]; then
          if [ -z "$best_elapsed" ] || [ "$elapsed" -lt "$best_elapsed" ]; then
            best_elapsed="$elapsed"; best_session="$session"
          fi
        fi
      done < "$markers"

      if [ "$valid_lines" -eq 0 ]; then
        log "Telemetry health: $total_lines session marker line(s) recorded, none parsed as a valid '<epoch>|<session_id>' entry — skipping config-drift check."
      elif [ -z "$best_session" ]; then
        # Explicit, distinguishable-from-crash log (finding 3): this pass DID
        # run and DID have valid markers, they just all fell outside the
        # [120s, expiration_secs) probe window right now (either too fresh,
        # or the whole run has already outlasted metric_expiration).
        log "Telemetry health: config-drift check ran but had nothing eligible to probe this pass ($valid_lines valid marker(s) recorded, all either <120s old or already past the configured metric_expiration=$expiration_str) — not drift, just no marker currently in-window."
      else
        local query_resp
        query_resp="$(curl -fsS --max-time 5 --data-urlencode "query={session_id=\"$best_session\"}" "$prom_url/api/v1/query" 2>/dev/null)"
        if [ -z "$query_resp" ]; then
          log "Telemetry health: could not query $prom_url/api/v1/query — skipping config-drift check."
        else
          local verdict
          verdict="$(printf '%s' "$query_resp" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    result = data.get("data", {}).get("result", [])
    print("present" if result else "missing")
except Exception:
    print("unknown")
')"
          case "$verdict" in
            missing)
              log "TELEMETRY HEALTH WARNING: config/behavior drift detected — completed iteration session_id=$best_session vanished from Prometheus ($prom_url) after only ${best_elapsed}s, well under the configured metric_expiration=$expiration_str in $otel_cfg. otelcol/Prometheus read that file once at process start and do NOT hot-reload — this means the running otel-collector/prometheus container predates the config on disk (container older than config — recreate needed): run 'docker compose up -d --force-recreate otel-collector prometheus' (or recreate the whole stack) so they pick up the current config, then re-run tonight's analysis once telemetry is trustworthy again."
              ;;
            present)
              log "Telemetry health: config-drift check OK — session_id=$best_session (completed ${best_elapsed}s ago) still present in Prometheus, consistent with configured metric_expiration=$expiration_str."
              ;;
            *)
              log "Telemetry health: could not parse Prometheus query response — skipping config-drift check."
              ;;
          esac
        fi
      fi
    fi
  fi
}

# register_pgid <pgid> — adds a process-group id to the registry the
# INT/TERM trap (installed in main, inside the BASH_SOURCE guard) hard-kills
# on a second Ctrl+C. Called by run_in_pgroup() right after launch; callers
# must deregister_pgid() once the iteration returns normally (nothing left to
# hard-kill for it).
register_pgid() { # register_pgid <pgid>
  _OVERNIGHT_PGIDS+=("$1")
}

# deregister_pgid <pgid> — removes a process-group id from the registry.
deregister_pgid() { # deregister_pgid <pgid>
  local pgid="$1" kept=() p
  for p in "${_OVERNIGHT_PGIDS[@]}"; do
    [ "$p" = "$pgid" ] || kept+=("$p")
  done
  _OVERNIGHT_PGIDS=("${kept[@]}")
}

# run_in_pgroup <pgid-outvar> <logfile> -- <command...> — launches
# "$@" (everything after the first two args) in the background under
# `setsid`, so it becomes the leader of a brand-new session + process group
# (pgid == its own pid) that the INT/TERM trap can hard-kill as a single
# unit on a second Ctrl+C. Stdout+stderr of the launched command are
# redirected to <logfile>.
#
# Verified empirically in this sandbox (util-linux 2.38 setsid, GNU
# coreutils 9.1 `timeout`/`env`): under `setsid env --chdir=DIR VAR=VAL
# timeout ... claude ...`, `env`/`timeout` exec in place (no extra fork), so
# the pid `$!` captures here IS the new session/group leader's pid, and
# `timeout`'s own forked child (claude) stays in THAT SAME new group rather
# than a further-nested one — so a single `kill -TERM -- -<pgid>` tears down
# `timeout`+`claude` together with no separate bookkeeping needed for the
# grandchild.
#
# Stores the launched process's pid into the caller's variable named by
# <pgid-outvar> and registers it via register_pgid(). The caller is
# responsible for `wait`-ing on that pid (in a loop — see run_worker: a trap
# firing during `wait` makes it return early with a signal-based status
# while the process is still alive) and calling deregister_pgid() once the
# iteration has actually finished.
run_in_pgroup() { # run_in_pgroup <pgid-outvar> <logfile> -- <command...>
  local __pgid_var="$1" __logfile="$2"
  shift 2
  setsid "$@" >"$__logfile" 2>&1 &
  local pid=$!
  register_pgid "$pid"
  printf -v "$__pgid_var" '%s' "$pid"
}

# run_worker_in_pgroup <pgid-outvar> <command...> — claude-14w. Same
# `setsid ... &` + register_pgid() mechanism as run_in_pgroup() above (same
# verified invariant: launching a non-job-controlled background child under
# `setsid` makes the captured $! itself the new session/process-group
# leader, with no extra fork layer in between — see run_in_pgroup's
# docstring), used here to give each PARALLEL_WORKERS>1 worker LEADER its own
# killable process group instead of the plain `run_worker ... & ` this
# replaces (which left the worker in main's own pgid, immune to a targeted
# `kill -TERM -- -<pgid>` and to the terminal's Ctrl+C alike — the exact
# POSIX-async-list bug this bead exists to fix).
#
# Deliberately does NOT redirect stdout/stderr to a logfile the way
# run_in_pgroup does: a worker leader's own output is just its wlog() calls
# echoing to the terminal (each line is ALSO durably written to
# worker-<N>.log by wlog itself), and pre-claude-14w that output was already
# visible live on the terminal (plain `run_worker ... &` inherits the
# parent's stdout). Forcing it through run_in_pgroup's logfile redirection
# would silently take that live visibility away with no behavior upside —
# so this is intentionally a separate, narrower helper rather than a second
# call site reusing run_in_pgroup with a throwaway logfile.
run_worker_in_pgroup() { # run_worker_in_pgroup <pgid-outvar> <command...>
  local __pgid_var="$1"
  shift 1
  setsid "$@" &
  local pid=$!
  register_pgid "$pid"
  printf -v "$__pgid_var" '%s' "$pid"
}

# assert_pgroup_invariant <leaderpid> <wsum> — claude-23n review F1. The
# entire hard-kill path rests on an invariant that is TRUE in this sandbox
# (verified empirically: see run_in_pgroup's docstring) but is an
# environment/version-dependent side effect of `timeout`'s internal
# setpgid(0,0) call failing (because `setsid` already made it a session
# leader), NOT a documented contract of `setsid`/`timeout`. If a future
# coreutils/util-linux ever changes that internal behavior so `claude` lands
# in its OWN group again, `kill -TERM -- -<pgid>` on a 2nd Ctrl+C would
# silently reap only the idle `timeout` wrapper and ORPHAN `claude` — no
# error, just a misleading "aborting now" while claude keeps running
# unsupervised. Rather than trust the prose comment, check it at runtime:
# poll briefly (bounded — this must never hang a real run) for the leader's
# forked child to appear, and if its pgid doesn't match the leader pid,
# log a loud WARNING. Never aborts the run over this — it only makes the
# silent-failure mode loud, per the finding.
assert_pgroup_invariant() { # assert_pgroup_invariant <leaderpid> <wsum>
  local leaderpid="$1" wsum="$2" childpid="" childpgid="" tries=0
  command -v pgrep >/dev/null 2>&1 || return 0
  while [ "$tries" -lt 20 ]; do
    childpid="$(pgrep -P "$leaderpid" 2>/dev/null | head -n1)"
    [ -n "$childpid" ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  # Couldn't observe a child in time (already finished, or hasn't forked
  # yet) — that's not itself evidence the invariant is broken, so stay quiet
  # rather than false-alarm.
  [ -n "$childpid" ] || return 0
  childpgid="$(ps -o pgid= -p "$childpid" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$childpgid" ] || return 0
  if [ "$childpgid" != "$leaderpid" ]; then
    wlog "$wsum" "WARNING: process-group teardown invariant broken — claude (pid $childpid) is in pgid $childpgid, NOT the setsid leader's pgid $leaderpid. A 2nd Ctrl+C's 'kill -TERM -- -$leaderpid' would only reach the idle timeout wrapper, not claude — claude would be orphaned and keep running/burning tokens after this script reports 'aborting now'. This means the setsid+timeout process-group behavior claude-23n verified empirically no longer holds in this environment; investigate the coreutils/util-linux versions before relying on the hard-kill path."
  fi
}

# assert_worker_pgroup_invariant <workerpid> — claude-14w. Same "verify, don't
# just trust the docstring" philosophy as assert_pgroup_invariant() above,
# but for the OTHER load-bearing invariant this bead introduces:
# run_worker_in_pgroup's `setsid <cmd> &` must make the captured $! itself
# the leader of a brand-new process group (pgid == pid), so main's
# `kill -TERM -- -<pid>` on a 2nd Ctrl+C actually reaches the whole worker
# session instead of a pgid the worker merely inherited from main (the exact
# POSIX-async-list bug this bead exists to fix). Bounded, best-effort, never
# aborts the run — only makes a broken invariant loud, matching
# assert_pgroup_invariant's pattern (including its short, bounded poll: the
# child may not have completed its setsid(2) call in the instant right after
# `&` returns).
assert_worker_pgroup_invariant() { # assert_worker_pgroup_invariant <workerpid>
  local pid="$1" pgid="" tries=0
  command -v ps >/dev/null 2>&1 || return 0
  while [ "$tries" -lt 20 ]; do
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$pgid" ] || return 0  # process already gone — nothing to check
    [ "$pgid" = "$pid" ] && return 0
    sleep 0.1
    tries=$((tries + 1))
  done
  log "WARNING: worker pid $pid is in pgid $pgid, NOT its own pid — the setsid session-leader invariant run_worker_in_pgroup() relies on does not hold in this environment. A 2nd Ctrl+C's 'kill -TERM -- -$pid' will not reach this worker's process group at all; it may keep running (and its own in-flight claude/timeout with it) unsupervised after this script reports 'aborting now'."
}

# finalize — merge each worker's per-worker summary log into the run's main
# SUMMARY, for a single morning read. Factored out (claude-23n) so BOTH the
# normal end-of-script path AND the hard-kill (2nd Ctrl+C) trap path call
# this exact logic instead of duplicating it. Idempotent (claude-23n review
# F3): a 2nd Ctrl+C landing during the normal end-of-script tail (which
# already ran finalize() once, e.g. while check_telemetry_health's curl
# calls are in flight) must not double-append every worker-*.log into
# $SUMMARY.
finalize() {
  [ "$_OVERNIGHT_FINALIZED" = "1" ] && return 0
  _OVERNIGHT_FINALIZED=1
  local f
  for f in "$LOG_DIR"/worker-*.log; do
    [ -f "$f" ] && { echo "── $(basename "$f") ──" >> "$SUMMARY"; cat "$f" >> "$SUMMARY"; }
  done
}

# _overnight_interrupted_during <pre-call-flag> — claude-23n review round 2
# (F4 fix). _OVERNIGHT_GRACEFUL_STOP is STICKY: once the 1st Ctrl+C sets it,
# it stays 1 for the rest of the run. That means a plain `[ "$_OVERNIGHT_
# GRACEFUL_STOP" = "1" ]` check after a subprocess fails cannot distinguish
# "this specific subprocess was killed by the signal" from "an earlier
# signal set the flag, and this later, UNRELATED subprocess failed on its
# own merits" — the latter is a real failure (e.g. a genuinely broken build
# in the post-iteration verify() gate) that must still file its P0 bead /
# real-failure warning, not be swallowed as "just an interrupt".
#
# Fix: callers snapshot _OVERNIGHT_GRACEFUL_STOP into a local IMMEDIATELY
# BEFORE invoking the subprocess (verify() / mcp_trust_gate() / bash -c
# "$PRE_ITERATION_CMD"), then pass that pre-call snapshot here after the
# call returns nonzero. Only a 0->1 transition — flag was 0 going in, 1
# coming out — means the interrupt landed DURING this specific call, so
# only that case is attributed to the interrupt. If the flag was ALREADY 1
# before the call started, this call's failure predates or is unrelated to
# that earlier signal and must be treated as real.
_overnight_interrupted_during() { # _overnight_interrupted_during <pre-call-flag>
  [ "$1" = "0" ] && [ "$_OVERNIGHT_GRACEFUL_STOP" = "1" ]
}

# _overnight_kill_registered_pgids <grace_secs> — claude-14w: factored out of
# _overnight_interrupt_handler's 2nd-signal body (claude-23n review F2's
# SIGTERM-then-confirm-then-SIGKILL logic), so BOTH main's own hard-kill trap
# AND each parallel worker leader's own local TERM trap
# (_overnight_worker_term_handler, below) call this exact logic instead of
# duplicating it — same "factor it out" spirit as finalize(). This operates
# on THIS PROCESS's own _OVERNIGHT_PGIDS array: since that array is an
# ordinary bash global, calling this function from different processes
# (main vs. a worker leader) naturally acts on that process's own registered
# pgids with no cross-talk — main's registry holds worker leader pgids (and,
# in single-worker mode, claude/timeout pgids directly); a worker leader's
# own registry holds only ITS nested claude/timeout pgids (see
# run_in_pgroup's docstring on why that's a separate, detached session that
# main's own `kill -TERM -- -<workerpid>` cannot reach directly).
#
# SIGTERM every registered pgid, poll for up to <grace_secs> (bounded — must
# never hang) confirming death, then SIGKILL any survivor. claude-23n review
# F2: SIGTERM can be trapped, delayed, or missed mid-syscall by claude/timeout
# — without confirming death and escalating, a survivor is silently orphaned
# after the caller exits (still burning tokens, nothing watching the budget)
# even though the operator was told "aborting now".
_overnight_kill_registered_pgids() { # _overnight_kill_registered_pgids <grace_secs>
  local grace_secs="${1:-$_OVERNIGHT_KILL_GRACE_SECS}" pgid waited=0
  local -a alive_pgids=()
  for pgid in "${_OVERNIGHT_PGIDS[@]}"; do
    [ -n "$pgid" ] || continue
    kill -TERM -- "-$pgid" 2>/dev/null \
      || { kill -0 -- "-$pgid" 2>/dev/null && log "WARNING: kill -TERM -- -$pgid failed even though the group is still alive — will still attempt SIGKILL below."; }
  done
  while [ "$waited" -lt "$grace_secs" ]; do
    alive_pgids=()
    for pgid in "${_OVERNIGHT_PGIDS[@]}"; do
      [ -n "$pgid" ] || continue
      kill -0 -- "-$pgid" 2>/dev/null && alive_pgids+=("$pgid")
    done
    [ "${#alive_pgids[@]}" -eq 0 ] && break
    sleep 1
    waited=$((waited + 1))
  done
  for pgid in "${alive_pgids[@]}"; do
    log "WARNING: pgid $pgid still alive ${grace_secs}s after SIGTERM — escalating to SIGKILL."
    kill -KILL -- "-$pgid" 2>/dev/null \
      || log "WARNING: kill -KILL -- -$pgid failed — it may already be gone, or this identity lacks permission to kill it. Check for an orphaned claude/timeout process manually."
  done
}

# _overnight_worker_term_handler — claude-14w: the TERM trap body installed
# INSIDE each parallel worker leader's own re-sourced process (see
# run_worker_in_pgroup()'s caller in main's parallel launch block), NOT in
# main itself. Why a worker needs its OWN, separate trap rather than relying
# on main's: main's hard-kill sends `kill -TERM -- -<workerpid>`, which
# reaches every process IN the worker's own process group — including the
# worker leader process itself — but NOT the worker's nested claude/timeout
# pair, because run_in_pgroup's `setsid` call inside run_worker() succeeds
# AGAIN there (setsid(2)'s restriction is "caller must not already be a
# process-group leader" — the freshly-forked grandchild about to exec setsid
# is not itself a leader, regardless of its ancestor being one), creating a
# SECOND, fully detached session. So main's signal only ever reaches the
# worker LEADER — this trap is what makes that leader, upon receiving it,
# turn around and clean up its own nested session using its own,
# process-local _OVERNIGHT_PGIDS registry (populated correctly already,
# since register_pgid()/run_in_pgroup() just mutate whatever process calls
# them — here, the worker leader's).
#
# Uses _OVERNIGHT_WORKER_KILL_GRACE_SECS (deliberately shorter than main's
# own _OVERNIGHT_KILL_GRACE_SECS — see that variable's docstring for the
# race this avoids), then exits immediately: this trap firing IS this
# worker's entire hard-stop, there is no "finish the current iteration"
# concept to fall back to once main has decided to hard-kill.
_overnight_worker_term_handler() {
  _overnight_kill_registered_pgids "$_OVERNIGHT_WORKER_KILL_GRACE_SECS"
  exit 143  # 128 + SIGTERM(15): conventional signal-exit status
}

# _overnight_interrupt_handler — the INT/TERM trap body (claude-23n;
# extended to parallel mode by claude-14w). Registered via `trap` in main,
# inside the BASH_SOURCE guard below, so `source`-ing this file for tests
# never installs a trap in the sourcing shell (defining this function, like
# every other function in this file, is side-effect-free). Two-stage
# Ctrl+C:
#   1st signal: set the in-process graceful-stop flag (single-worker path:
#     run_worker executes directly inside main, so this flag alone is
#     enough) AND create the shared _OVERNIGHT_STOP_FLAG_FILE (parallel
#     path: each worker is a separate process with no shared memory, so it
#     polls for this file's existence instead — see run_worker's loop-top
#     check). Either way: stop launching NEW iterations, but do NOT touch
#     whatever claude/timeout is already in flight anywhere — it runs to
#     completion.
#   2nd signal: hard-kill. In single-worker mode, _OVERNIGHT_PGIDS (this
#     process's registry) holds the in-flight claude/timeout pgid directly.
#     In parallel mode, it holds each WORKER LEADER's pgid (registered by
#     run_worker_in_pgroup() in main's parallel launch block) — SIGTERM'ing
#     those reaches each worker leader, whose OWN local trap
#     (_overnight_worker_term_handler, above) then recursively tears down
#     that worker's nested claude/timeout session. Either way,
#     _overnight_kill_registered_pgids (factored out below, claude-14w) does
#     the SIGTERM-then-confirm-then-SIGKILL work; then merge whatever
#     per-worker summaries exist (finalize) + run check_telemetry_health,
#     and exit non-zero. This intentionally skips the end-of-night
#     /analyze-telemetry pass (mirrors the end-of-script guard on the
#     graceful path in main).
_overnight_interrupt_handler() {
  _OVERNIGHT_INTERRUPT_COUNT=$((_OVERNIGHT_INTERRUPT_COUNT + 1))
  if [ "$_OVERNIGHT_INTERRUPT_COUNT" -eq 1 ]; then
    _OVERNIGHT_GRACEFUL_STOP=1
    if ! touch "$_OVERNIGHT_STOP_FLAG_FILE" 2>/dev/null; then
      log "WARNING: could not create internal graceful-stop flag file $_OVERNIGHT_STOP_FLAG_FILE — any PARALLEL_WORKERS>1 worker (a separate process) will NOT see this graceful-stop request and may keep launching new iterations. The in-process worker path (PARALLEL_WORKERS<=1) is unaffected — it uses the in-memory flag above."
    fi
    log "Interrupt received — finishing current iteration; press Ctrl+C again to abort now."
    return
  fi
  log "Second interrupt — aborting now."
  _overnight_kill_registered_pgids "$_OVERNIGHT_KILL_GRACE_SECS"
  finalize
  check_telemetry_health
  exit 130
}

run_worker() { # run_worker <index> <workdir>
  local idx="$1" workdir="$2"
  local wsum="$LOG_DIR/worker-$idx.log"
  local spent="0" consec=0 completed=0

  # Baseline gate: never burn a night on an already-red build.
  local _pre_int="$_OVERNIGHT_GRACEFUL_STOP"
  if ! verify "$workdir" "$wsum" "w$idx-baseline"; then
    # claude-23n review F4 (round 2 fix): verify() runs in this script's own
    # foreground process group (only claude is setsid-shielded), so a
    # Ctrl+C landing mid-verify kills it with a signal-derived nonzero
    # status — that is NOT evidence of a real RED build. But the flag is
    # sticky, so only a 0->1 transition DURING this specific call counts as
    # "interrupted" — see _overnight_interrupted_during()'s docstring.
    if _overnight_interrupted_during "$_pre_int"; then
      wlog "$wsum" "WARNING: baseline verification failed while the interrupt landed during this specific check (not before it) — treating as an interrupt artifact, not a real RED build. Aborting worker gracefully."
    else
      wlog "$wsum" "Baseline verification is RED in $workdir — aborting worker before spending tokens."
    fi
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

    # claude-23n: 1st Ctrl+C (or SIGTERM) sets this via the INT/TERM trap in
    # main. Stop launching NEW iterations, but the in-flight claude/timeout
    # (if any, from a previous pass through this loop) already ran to
    # completion before we got back here — nothing to shield/kill on this
    # path, that's the hard-kill (2nd signal) path in the trap itself.
    #
    # claude-14w: _OVERNIGHT_GRACEFUL_STOP alone only works when run_worker
    # executes directly inside main's own process (PARALLEL_WORKERS<=1) —
    # main's trap setting a plain bash variable is invisible to a genuinely
    # separate PARALLEL_WORKERS>1 worker process. That's what the shared
    # _OVERNIGHT_STOP_FLAG_FILE is for: main's trap creates it on the 1st
    # signal (in addition to setting the in-memory flag), and every worker
    # — in-process or out-of-process alike — polls for its existence here,
    # same as the pre-existing $STOP_FILE check just above.
    # claude-14w review (finding 2): distinguish the two ways this loop can
    # observe a graceful-stop request, rather than folding them into one log
    # line. _OVERNIGHT_GRACEFUL_STOP=1 in THIS process's own memory is only
    # ever set by THIS process's own INT/TERM trap — i.e. a genuine operator
    # Ctrl+C/SIGTERM landed on the process actually running this loop
    # (always true in single-worker mode, since run_worker executes directly
    # inside main). The stop-flag-FILE case is different: it is same-UID
    # writable by every worker's own headless `claude -p` agent process (see
    # _OVERNIGHT_STOP_FLAG_FILE's definition above for why, and why that's an
    # accepted residual limitation — the same exposure the pre-existing
    # user-facing $STOP_FILE already has), so a worker observing the file
    # rather than its own in-process flag cannot tell "main asked me to stop"
    # apart from "a sibling worker's agent touched this file itself." Log
    # that case LOUDLY via log() (not just wlog()) so it lands directly in
    # $SUMMARY as it happens — every worker process resolves the same
    # $SUMMARY path (see RUN_ID/PROJECT_DIR docstrings), so this reaches the
    # top-level summary an operator actually reads, not just a per-worker
    # log that only surfaces at finalize()-merge time. This does NOT change
    # the halt behavior itself, only its visibility.
    if [ "$_OVERNIGHT_GRACEFUL_STOP" = "1" ]; then
      wlog "$wsum" "Graceful interrupt received (operator signal in this process) — not launching a new iteration; halting."
      break
    elif [ -f "$_OVERNIGHT_STOP_FLAG_FILE" ]; then
      wlog "$wsum" "Graceful interrupt received (stop-flag file observed) — not launching a new iteration; halting."
      log "GRACEFUL STOP FLAG OBSERVED by worker $idx — halting after its current iteration. This worker's OWN in-process operator-signal flag was NOT set, so this stop was observed via $_OVERNIGHT_STOP_FLAG_FILE rather than a direct Ctrl+C/SIGTERM to this process. That file is same-UID writable by any worker's own agent (accepted residual limitation, documented at its definition) — if this run was not intentionally interrupted by the operator, treat this as a possible sibling-worker-triggered stop and inspect worker-$idx.log / that worker's iteration logs before trusting the rest of tonight's results."
      break
    fi

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
      local _pre_int_pic="$_OVERNIGHT_GRACEFUL_STOP"
      if ! ( cd "$workdir" && bash -c "$PRE_ITERATION_CMD" ) >>"$wsum" 2>&1; then
        # claude-23n review F4 (round 2 fix): PRE_ITERATION_CMD runs in this
        # script's own foreground process group (not setsid-shielded) — a
        # Ctrl+C landing mid-command kills it with a signal-derived nonzero
        # status. The flag is sticky, so only a 0->1 transition DURING this
        # specific call counts as "interrupted" — see
        # _overnight_interrupted_during()'s docstring.
        if _overnight_interrupted_during "$_pre_int_pic"; then
          wlog "$wsum" "WARNING: PRE_ITERATION_CMD failed while the interrupt landed during this specific run (not before it) — treating as an interrupt artifact, not a real command failure. Halting worker gracefully."
          break
        fi
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
    local _pre_int_mcp="$_OVERNIGHT_GRACEFUL_STOP"
    if ! mcp_trust_gate "$workdir"; then
      # claude-23n review F4 (round 2 fix): mcp_trust_gate's git calls run in
      # this script's own foreground process group — a Ctrl+C landing
      # mid-check kills them with a signal-derived nonzero status, not a
      # real trust failure. The flag is sticky, so only a 0->1 transition
      # DURING this specific call counts as "interrupted" — see
      # _overnight_interrupted_during()'s docstring. A misbehaving agent
      # signaling itself right before an otherwise-legitimate trust-gate
      # failure must NOT be able to suppress this WARNING / audit trail by
      # that trick alone — it only works if the flag was still 0 when this
      # call started.
      if _overnight_interrupted_during "$_pre_int_mcp"; then
        wlog "$wsum" "WARNING: MCP trust gate re-check failed while the interrupt landed during this specific check (not before it) — treating as an interrupt artifact, not a real trust failure. Halting worker gracefully."
      else
        wlog "$wsum" "MCP trust gate failed mid-run (.mcp.json / .mcp.json.trusted-sha256 no longer a clean, committed, matching pair) — halting worker rather than launching an unreviewed MCP config."
      fi
      break
    fi

    wlog "$wsum" "Iteration $i: $n ready bead(s); spent \$$spent of \$$WORKER_BUDGET. Launching claude..."

    # claude-23n: launch under run_in_pgroup (setsid) instead of a plain
    # subshell, so the trap can hard-kill this exact timeout+claude pair as a
    # unit on a second Ctrl+C. `env --chdir=` replaces the subshell's `cd`
    # (setsid execs straight into `env`, no shell needed to change directory
    # or set the OTEL_RESOURCE_ATTRIBUTES env var). $PERMISSION_FLAGS is
    # deliberately word-split into an array (unquoted, same as the original
    # inline `$PERMISSION_FLAGS` expansion) since it may hold multiple flags.
    local -a perm_flags=()
    # shellcheck disable=SC2206  # intentional word-splitting, see above
    perm_flags=($PERMISSION_FLAGS)

    local pgid=""
    run_in_pgroup pgid "$ilog" \
      env --chdir="$workdir" \
      OTEL_RESOURCE_ATTRIBUTES="service.name=overnight-runner,run.id=$RUN_ID,worker.id=w$idx" \
      timeout "$RUN_TIMEOUT" claude -p "/build-next --unattended" \
      "${perm_flags[@]}" \
      --output-format stream-json --verbose \
      --max-turns "$MAX_TURNS"

    # claude-23n review F1: check the load-bearing pgroup invariant at
    # runtime instead of only trusting the docstring — see
    # assert_pgroup_invariant()'s comment. Bounded, best-effort, never
    # aborts the run; only makes a broken invariant loud.
    assert_pgroup_invariant "$pgid" "$wsum"

    # `wait PGID` returns early (with a signal-derived exit status, e.g. 130)
    # the instant a trapped signal (the 1st Ctrl+C) fires, even though the
    # process is still running — re-wait until it's actually gone so a
    # graceful interrupt truly lets the in-flight claude finish rather than
    # this loop mistaking "wait was interrupted" for "claude exited".
    local status
    while true; do
      wait "$pgid"
      status=$?
      kill -0 "$pgid" 2>/dev/null || break
    done
    deregister_pgid "$pgid"

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
    # claude-23n review F4 (round 2 fix): the 1st Ctrl+C almost always lands
    # during the long, setsid-shielded claude run above, setting the sticky
    # _OVERNIGHT_GRACEFUL_STOP flag well BEFORE this verify() call even
    # starts — that flag being "1" here says nothing about whether THIS
    # verify() was itself hit by a signal. Snapshot it immediately before
    # the call so a genuinely broken build (this gate's entire reason to
    # exist) still gets its P0 bead even after an earlier, unrelated
    # interrupt — a misbehaving agent must not be able to suppress this
    # audit trail just by signaling the parent itself.
    local _pre_int_verify="$_OVERNIGHT_GRACEFUL_STOP"
    if ! verify "$workdir" "$wsum" "$tag"; then
      if _overnight_interrupted_during "$_pre_int_verify"; then
        wlog "$wsum" "WARNING: post-iteration verification failed while the interrupt landed during this specific check (not before it) — treating as an interrupt artifact, not a real RED build. No P0 bead filed. Halting worker gracefully."
      else
        ( cd "$workdir" && bd create "Build/tests RED after overnight iteration $tag (commit $(git rev-parse --short HEAD 2>/dev/null)); verify log: $LOG_DIR/$tag.verify.log" -p 0 ) >>"$wsum" 2>&1
        wlog "$wsum" "Verification gate failed — filed a P0 fix bead and halting worker (a broken build poisons later tasks)."
      fi
      break
    fi

    consec=0; completed=$((completed + 1))
    record_session_marker "$session"
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

# claude-23n: two-stage Ctrl+C cancel — see _overnight_interrupt_handler()'s
# docstring above for the full semantics. Installed here (inside the
# BASH_SOURCE guard), NOT at top level, so sourcing this file for tests never
# installs a trap in the sourcing (test-runner) shell.
trap _overnight_interrupt_handler INT TERM

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
if [ "$PARALLEL_WORKERS" -gt 1 ]; then
  log "Two-stage Ctrl+C cancel (claude-14w) covers PARALLEL_WORKERS=$PARALLEL_WORKERS: each worker runs in its own setsid session; 1st Ctrl+C lets every worker finish its current iteration then halt, 2nd Ctrl+C hard-kills every worker's in-flight claude/timeout via its own local cleanup trap."
fi

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

  # claude-14w: each worker is re-launched as THIS SAME SCRIPT, re-sourced in
  # a brand-new `setsid` session (own pgid) inside a fresh bash process, via
  # run_worker_in_pgroup() — see that function's docstring for why a plain
  # `run_worker "$w" "$WT" &` (the pre-claude-14w form) can never be
  # hard-killed on its own: backgrounded like that, it stays in THIS shell's
  # own pgid (POSIX async-list behavior) rather than getting one of its own.
  #
  # Resolve an ABSOLUTE path up front (rather than trusting a possibly
  # relative $0/BASH_SOURCE[0] to still resolve correctly from whatever cwd
  # the re-exec'd bash -c ends up with) so the worker's `source` always finds
  # this exact file regardless of how this script itself was invoked
  # (`./tools/run-overnight.sh`, `bash tools/run-overnight.sh`, an absolute
  # path, ...).
  SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  # claude-14w (review round 2): hand the worker its identity via
  # distinctly-named internal variables, NOT the generic RUN_ID/PROJECT_DIR
  # names — those two are ALWAYS recomputed fresh at top-of-file now (see
  # their docstrings) so that a normal top-level invocation can never be
  # derailed by an inherited environment value under a generic name. The
  # worker subprocess recognizes _OVERNIGHT_IS_WORKER=1 and adopts
  # _OVERNIGHT_WORKER_PROJECT_DIR/_OVERNIGHT_WORKER_RUN_ID instead of
  # recomputing its own (RUN_ID) or mis-computing one from the wrapper's own
  # unrelated $1 (PROJECT_DIR).
  export _OVERNIGHT_IS_WORKER=1 _OVERNIGHT_WORKER_PROJECT_DIR="$PROJECT_DIR" _OVERNIGHT_WORKER_RUN_ID="$RUN_ID"

  pids=()
  for w in $(seq 1 "$PARALLEL_WORKERS"); do
    # claude-14w review (finding 1): mirror run_worker's own loop-top
    # graceful-stop check (above) here in the LAUNCH loop too. Workers are
    # started with a `sleep 3` stagger between them (below), so a 1st
    # Ctrl+C landing mid-launch has a window of up to
    # PARALLEL_WORKERS*3 seconds during which — without this check — this
    # loop would keep creating overnight/$RUN_ID-w<N> worktrees and
    # spinning up brand-new worker-leader subprocesses, each of which only
    # self-halts AFTER running its own (potentially expensive) baseline
    # verify() + mcp_trust_gate() in run_worker(). That contradicts the
    # documented "1st Ctrl+C: stop launching new work" semantics. Written as
    # a single `if` with an explicit `||`-combined condition (not two
    # separate `&&`-chained one-liners) so precedence can't accidentally
    # make the break unconditional.
    if [ "$_OVERNIGHT_GRACEFUL_STOP" = "1" ] || [ -f "$_OVERNIGHT_STOP_FLAG_FILE" ]; then
      log "Graceful interrupt received — not launching worker $w or any further workers."
      break
    fi
    WT="$WORKTREE_BASE/w$w"
    if [ ! -d "$WT" ]; then
      git -C "$PROJECT_DIR" worktree add -b "overnight/$RUN_ID-w$w" "$WT" HEAD >>"$SUMMARY" 2>&1 \
        || { log "Worker $w: worktree creation failed — skipping."; continue; }
    fi
    # The `bash -c SCRIPT ARG0 ARG1 ARG2 ARG3` form: ARG0 becomes the new
    # process's $0, ARG1/ARG2/ARG3 become its $1/$2/$3. ARG0 is deliberately
    # a plain descriptive string, NOT $SELF_PATH — the BASH_SOURCE guard at
    # the bottom of this file (which must NOT re-enter main here) compares
    # `${BASH_SOURCE[0]} = ${0}`; BASH_SOURCE[0] inside the `source "$1"`
    # below resolves to $SELF_PATH, so $0 must be some other string for the
    # guard to reliably evaluate false. `source "$1"` (with no further args
    # of its own) intentionally leaves $1/$2/$3 as inherited from THIS
    # wrapper's own positional params for run_worker's call below to consume
    # — that's fine even though run-overnight.sh's own top-level `$1` would
    # normally mean "project dir", because _OVERNIGHT_IS_WORKER=1 (exported
    # above) makes the top-of-file logic adopt
    # _OVERNIGHT_WORKER_PROJECT_DIR instead of consulting `$1` at all (see
    # PROJECT_DIR's docstring).
    worker_pgid=""
    run_worker_in_pgroup worker_pgid \
      bash -c 'source "$1"; trap _overnight_worker_term_handler TERM; run_worker "$2" "$3"' \
      "run-overnight-worker-w$w" "$SELF_PATH" "$w" "$WT"
    assert_worker_pgroup_invariant "$worker_pgid"
    pids+=("$worker_pgid")
    sleep 3
  done

  # `wait PID1 PID2 ...` can return early (signal-derived exit status) the
  # instant a trapped signal fires, even though some/all of those pids are
  # still alive — same reasoning run_worker already applies to a single pgid
  # (~1102 there), generalized here to N worker pids (claude-14w): re-wait on
  # whichever ones are still actually alive until none are.
  remaining_pids=("${pids[@]}")
  while [ "${#remaining_pids[@]}" -gt 0 ]; do
    wait "${remaining_pids[@]}" 2>/dev/null
    still_alive=()
    for p in "${remaining_pids[@]}"; do
      kill -0 "$p" 2>/dev/null && still_alive+=("$p")
    done
    remaining_pids=("${still_alive[@]}")
  done
  for p in "${pids[@]}"; do
    deregister_pgid "$p"
  done

  log "Worker branches (merge or discard in the morning):"
  git -C "$PROJECT_DIR" branch --list "overnight/$RUN_ID-*" | sed 's/^/    /' | tee -a "$SUMMARY"
fi

# Merge per-worker summaries into the main one for a single morning read.
# claude-23n: factored into finalize() so the hard-kill (2nd Ctrl+C) trap
# path above calls this exact logic instead of duplicating it.
finalize

# claude-saz round 3: surface a dead otel-collector/prometheus BEFORE the
# telemetry-analysis pass below, which queries both — so a WARNING here is
# the operator's explanation for sparse/failed analysis output, not a
# separate mystery to debug later. claude-23n: run unconditionally on an
# interrupted run too (see the "Agreed semantics" for the two-stage Ctrl+C
# cancel) — telemetry health is still worth knowing about even on a cut-short
# night, unlike the /analyze-telemetry mining pass skipped below.
check_telemetry_health

# End-of-night telemetry analysis: one fresh headless pass over the whole run's
# telemetry + session artifacts, filing [token-efficiency] beads. Runs AFTER the
# loop (so the run's OTel data has flushed) and only if any iteration completed.
# Bounded tighter than a full build iteration (ANALYZE_MAX_TURNS/ANALYZE_TIMEOUT,
# not MAX_TURNS/RUN_TIMEOUT) since it's a read-only mining pass, not agentic work.
# claude-23n: skipped entirely on ANY Ctrl+C/SIGTERM (graceful or hard) — an
# operator-requested early stop means "cut the night short", not "keep going
# with one more headless claude -p pass to mine it."
worker_spend="$(total_worker_spend "$LOG_DIR")"
analyze_cost="0"
if [ "$_OVERNIGHT_GRACEFUL_STOP" = "1" ]; then
  log "Interrupted — skipping end-of-night telemetry analysis."
elif [ "$ANALYZE_TELEMETRY" = "1" ]; then
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

if [ "$_OVERNIGHT_GRACEFUL_STOP" = "1" ]; then
  log "Run interrupted by operator (Ctrl+C/SIGTERM) after $_OVERNIGHT_INTERRUPT_COUNT signal(s). Review $LOG_DIR, 'bd ready', and any in-progress work before resuming."
  exit 1
fi

log "Run complete. Review $LOG_DIR, 'bd ready', Question:/fix + [token-efficiency] beads, and any worker branches."

fi # end BASH_SOURCE guard