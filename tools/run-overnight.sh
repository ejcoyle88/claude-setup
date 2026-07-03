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

verify() { # verify <workdir> <worker-summary> <label> ; returns VERIFY_CMD status
  [ -z "$VERIFY_CMD" ] && return 0
  local vlog="$LOG_DIR/$3.verify.log"
  ( cd "$1" && bash -c "$VERIFY_CMD" ) >"$vlog" 2>&1
  local st=$?
  [ $st -ne 0 ] && wlog "$2" "VERIFY FAILED ($3): see $vlog. Tail:" && tail -n 10 "$vlog" | sed 's/^/    /'
  return $st
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
log "Overnight run $RUN_ID: $PARALLEL_WORKERS worker(s), $MAX_ITERATIONS iters/worker, \$$MAX_TOTAL_COST_USD budget (\$$WORKER_BUDGET/worker), max-turns $MAX_TURNS/run."
log "Permissions: $PERMISSION_FLAGS | OTel: $([ "$OTEL_ENABLED" = "1" ] && echo "on → $OTEL_EXPORTER_OTLP_ENDPOINT ($OTEL_EXPORTER_OTLP_PROTOCOL)" || echo "off")"
[ -z "$VERIFY_CMD" ] && log "WARNING: VERIFY_CMD is empty — the deterministic verification gate is DISABLED. Set e.g. VERIFY_CMD='dotnet build && dotnet test'."
log "Stop file: $STOP_FILE"

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
log "Run complete. Review $LOG_DIR, 'bd ready', Question:/fix beads, and any worker branches."