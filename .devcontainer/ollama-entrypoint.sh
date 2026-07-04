#!/bin/bash
# Applies the deny-by-default egress firewall in this container's own network
# namespace, then (for the long-running `serve` command only -- see the WARM
# section below) warms the configured model before handing off to the real
# ollama server. Baked in as the image ENTRYPOINT (see Dockerfile.ollama) so
# it runs on every `docker compose up`, not just under an orchestrator that
# supports postStartCommand-style hooks (compose itself doesn't for
# non-devcontainer-CLI services).
set -euo pipefail

# claude-241: SETPRIV_DROP lives in setpriv-drop-args.sh, sourced here rather
# than retyped, so Dockerfile.ollama's build-time setpriv guard (which sources
# the same file) tests the exact args this script actually uses -- not a
# separate hand-typed copy that could silently drift from this one.
# shellcheck source=setpriv-drop-args.sh
. /usr/local/bin/setpriv-drop-args.sh

# claude-kkc: fail fast, not silently-wrong, if SETPRIV_DROP came back from
# setpriv-drop-args.sh empty or the wrong shape. This is the runtime twin of
# claude-arv's build-time guard (which checks the cap NAMES Dockerfile.ollama's
# setpriv invocation actually accepts) -- it doesn't re-validate cap names,
# just guarantees the array this script is about to `exec setpriv` with
# actually has the two flags setpriv-drop-args.sh is supposed to produce
# (currently `--bounding-set=-net_admin,-net_raw --inh-caps=-net_admin,-net_raw`)
# rather than empty or single-element garbage. An empty/short SETPRIV_DROP
# would make the exec below either no-op (dropping nothing,
# cap_net_admin/cap_net_raw left live for the rest of this container's life)
# or fail outright -- an empty SETPRIV_DROP silently no-opping the drop was
# exactly the claude-01t regression. Asserting its shape here, before it's
# ever used, turns that class of bug back into an immediate, diagnosable
# startup failure instead of a container that "works" with caps still live.
(( ${#SETPRIV_DROP[@]} == 2 )) || {
  echo "FATAL: SETPRIV_DROP misconfigured (expected 2 elements: --bounding-set=... and --inh-caps=...; got ${#SETPRIV_DROP[@]}: '${SETPRIV_DROP[*]:-<empty>}') -- refusing to start rather than exec setpriv with a no-op or invalid cap-drop." >&2
  exit 1
}

# claude-kkc: bound the setpriv self-re-exec below (the `exec setpriv
# "${SETPRIV_DROP[@]}" "$0" "$@"` further down, NOT the "hand off straight to
# /bin/ollama" exec next to it -- that one never comes back through
# caps_already_dropped() below and so can't loop) to a small number of
# attempts. In the intended path this branch's exec runs at most once per
# container lifetime: the reborn copy lands in caps_already_dropped()
# returning true and never reaches this code again. But if
# caps_already_dropped() never observes cleared CapBnd bits -- a bad cap name
# reintroduced some other way, cap_add missing at runtime even though
# Dockerfile.ollama's build-time guard passed, or a non-transient /proc read
# failure -- the reborn copy comes back through this same "else" branch,
# re-runs ollama-init-firewall.sh, and re-execs again -- forever, silently,
# on every container start. That's exactly the crash-loop the
# empty-SETPRIV_DROP regression (claude-01t) caused. This counter is carried
# across `exec` via the environment (exec preserves the environment of the
# process it replaces, so an exported var survives), turning what would
# otherwise be an infinite loop into a bounded number of attempts with a
# clear diagnostic instead of a silent hang/loop.
: "${OLLAMA_ENTRYPOINT_REEXEC_DEPTH:=0}"

# claude-kkc: OLLAMA_ENTRYPOINT_REEXEC_DEPTH is caller-suppliable (docker-compose
# `environment:`, a `-e` override on `docker run`/`compose run`, or a
# compromised parent process) and, unlike argv, is never sanitized by exec
# argument passing. Bash arithmetic contexts recursively re-expand a
# referenced variable's *value* as a new expression -- including command
# substitution -- so feeding this straight into the `(( ... ))` below, while
# still root with NET_ADMIN/NET_RAW live, would let a value like
# '$(some_command)' execute arbitrary code before the cap-drop. This is the
# same "caller-suppliable input drives security-relevant control flow" class
# the __post_firewall argv sentinel comment above warns about, just via env
# instead of argv. Validating the shape here -- mirroring the
# `[[ "$capbnd" =~ ^[0-9a-fA-F]+$ ]]` guard caps_already_dropped() applies to
# capbnd below -- closes both that injection vector and a quieter one: a
# pre-set negative value (e.g. -1000000) would take that many iterations to
# trip the `>= 2` bound this diff exists to enforce. Reset-to-0 (not fatal)
# on a bad value, consistent with how capbnd degrades on a bad read rather
# than aborting immediately.
[[ "$OLLAMA_ENTRYPOINT_REEXEC_DEPTH" =~ ^(0|[1-9][0-9]{0,2})$ ]] || OLLAMA_ENTRYPOINT_REEXEC_DEPTH=0

# Fail-closed gate: whether the firewall has already been applied AND this
# process has already been re-exec'd through setpriv (see the re-exec below)
# is decided from ACTUAL KERNEL STATE -- this process's capability bounding
# set, read from /proc/self/status -- never from a caller-suppliable argv
# token. An earlier version of this gate used a plain "__post_firewall" argv
# sentinel; that's forgeable by anything that controls the container command
# (`docker compose run ollama __post_firewall serve`, a compose `command:`
# override, future tooling that forwards a config/user string as argv, ...),
# and landing in the post-firewall branch on a forged sentinel would skip
# BOTH the firewall AND the cap-drop -- strictly worse than not refactoring
# this at all, since it reproduces exactly the "a compromised process can
# flush its own firewall" scenario this design exists to prevent, silently.
# Reading CapBnd can't be spoofed via argv, and any read failure or
# unexpected value (not just cap_net_admin/cap_net_raw actually clear) falls
# through to the "apply firewall + drop" branch below instead of skipping
# it -- fail closed, not fail open.
caps_already_dropped() {
  local capbnd
  capbnd=$(awk '/^CapBnd:/{print $2}' /proc/self/status) || return 1
  [[ "$capbnd" =~ ^[0-9a-fA-F]+$ ]] || return 1
  # cap_net_admin = bit 12, cap_net_raw = bit 13 (capability(7)); 0x3000 is
  # both bits. Both clear means neither capability is reachable via execve
  # by this process (or anything it forks) anymore -- exactly the
  # post-setpriv-drop state, and NOT something argv can fake: it reflects
  # what the kernel actually granted this process at exec time.
  (( (0x$capbnd & 0x3000) == 0 ))
}

if caps_already_dropped; then
  # Already past the firewall + cap-drop below (this is the setpriv-reborn
  # copy of this same script) -- fall through straight to the WARM/serve
  # supervisor logic.
  :
else
  /usr/local/bin/ollama-init-firewall.sh

  # The firewall above needs NET_ADMIN/NET_RAW (granted via cap_add in
  # docker-compose.yml) to program iptables/ipset; nothing that runs after
  # it -- this script's own WARM supervisor logic, `ollama serve`, `ollama
  # pull`/`ollama list`, or anything any of them forks -- needs those caps
  # at all. Holding them any longer than necessary would let a compromised
  # process in that tree undo its own firewall (`iptables -F` / `ipset
  # destroy`) just as easily as this script built it.
  #
  # A per-child `setpriv <drops> /bin/ollama serve &` is NOT sufficient for
  # that: setpriv only strips the bounding/inheritable set of the process it
  # directly wraps. If THIS bash script stayed PID 1 as a supervisor
  # (backgrounding serve, waiting on it, running the WARM step in between --
  # see below), it would keep its own, un-dropped capability set for its
  # entire life, and cap_add would still be in effect for it. So instead
  # this script re-execs ITSELF (not just the eventual `ollama` process)
  # through setpriv right here, before any WARM/serve logic runs: the
  # bounding-set drop applies at exec time, so the reborn copy of this
  # script -- and everything it starts from then on -- inherits the dropped
  # set from birth (which is exactly what caps_already_dropped detects on
  # that next run, gating this whole branch out). A root process can only
  # reacquire a capability on execve if it's still in the bounding set, and
  # this clears it from there permanently for the rest of this container's
  # life. setpriv is part of util-linux, already present in the ollama base
  # image (verified at build time in Dockerfile.ollama).
  if [ "${1:-serve}" != "serve" ]; then
    # Not the long-running server (e.g. an ad-hoc `docker compose run ollama
    # <cmd>` debug invocation) -- the WARM dance below only makes sense for
    # `serve`, so just drop caps and hand off directly, same as before
    # claude-r30.2.
    exec setpriv "${SETPRIV_DROP[@]}" /bin/ollama "$@"
  fi

  # See the OLLAMA_ENTRYPOINT_REEXEC_DEPTH comment near the top of this
  # script for why this specific exec (and only this one) needs a depth
  # guard. Check BEFORE incrementing/exec'ing again, so the diagnostic below
  # reports the number of re-exec attempts actually taken so far, and this
  # script exits instead of handing off to yet another copy of itself.
  if (( OLLAMA_ENTRYPOINT_REEXEC_DEPTH >= 2 )); then
    echo "FATAL: caps_already_dropped() never observed cleared CapBnd bits after ${OLLAMA_ENTRYPOINT_REEXEC_DEPTH} setpriv re-exec attempt(s) -- check that cap_add (NET_ADMIN, NET_RAW) is actually granted to this service in docker-compose.yml, and that SETPRIV_DROP (setpriv-drop-args.sh) uses correct, un-prefixed capability names. Refusing to re-exec again to avoid an infinite firewall-reapply/cap-drop loop." >&2
    exit 1
  fi
  # Exported (not just set) so it survives the `exec` below: exec replaces
  # this process's image but keeps its environment, and the reborn copy's
  # `: "${OLLAMA_ENTRYPOINT_REEXEC_DEPTH:=0}"` above only seeds a default --
  # it won't clobber a value already inherited from the environment.
  export OLLAMA_ENTRYPOINT_REEXEC_DEPTH=$(( OLLAMA_ENTRYPOINT_REEXEC_DEPTH + 1 ))
  exec setpriv "${SETPRIV_DROP[@]}" "$0" "$@"
fi

# --- WARM (claude-r30.2) -- runs post-firewall, WITH caps already dropped --
# Ensures $OLLAMA_MODEL is pulled and the server is answering BEFORE this
# container's HEALTHCHECK (Dockerfile.ollama) can report healthy -- so an
# ollama-mcp tool call made after this container exists never hits a cold
# "model not found" on first use.
#
# This network namespace is already restricted (by the firewall applied
# above) to DNS/loopback/the pinned subnet only (see
# ollama-init-firewall.sh) -- the `ollama pull` below reaches the registry/
# blob hosts the exact same way any other pull against this sidecar would:
# through ollama-egress-proxy via HTTPS_PROXY (docker-compose.yml's
# x-ollama-common anchor). Nothing here reopens or bypasses that path.
#
# `ollama pull`/`ollama list` are just API clients against `ollama serve`, so
# the server has to already be running locally for either to work. It's
# started in the background here (no setpriv wrap needed on this child --
# the dispatch above already dropped the bounding set for this whole process
# tree before we got here). This script stays PID 1 as a thin supervisor:
# wait for readiness, ensure the model, then wait on the server for the rest
# of the container's life. Both the readiness wait and the pull below run as
# backgrounded jobs that TERM/INT are forwarded to (see the trap), so
# `docker compose stop`/`down` triggers a graceful shutdown at any point in
# this script's life -- including mid-pull -- rather than only once
# execution reaches the final `wait`.
: "${OLLAMA_MODEL:=llama3.2:3b}"
: "${OLLAMA_SERVER_READY_TIMEOUT_S:=60}"
: "${OLLAMA_PULL_TIMEOUT_S:=1800}"

pull_pid=""

/bin/ollama serve &
ollama_pid=$!

# bash only delivers a pending trap once the current foreground command
# returns -- a synchronous `ollama pull` run directly (not backgrounded)
# would defer TERM/INT for its entire (up to $OLLAMA_PULL_TIMEOUT_S) run.
# `wait` is the one builtin bash interrupts promptly on signal, so both the
# server and the pull are started as background jobs and this script only
# ever blocks in `wait` -- letting this trap fire, and forward the signal to
# whichever of them is currently running, at any point.
on_term() {
  echo "Forwarding signal to ollama serve (pid ${ollama_pid:-unknown})${pull_pid:+ and in-flight pull (pid $pull_pid)}..."
  if [ -n "$pull_pid" ]; then
    kill -TERM "$pull_pid" 2>/dev/null || true
  fi
  kill -TERM "$ollama_pid" 2>/dev/null || true
  wait "$ollama_pid" 2>/dev/null
  exit $?
}
trap on_term TERM INT

echo "Waiting up to ${OLLAMA_SERVER_READY_TIMEOUT_S}s for ollama serve to accept connections..."
ready=0
for _ in $(seq 1 "$OLLAMA_SERVER_READY_TIMEOUT_S"); do
  if curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ready=1
    break
  fi
  # Fail fast if the server process itself already died instead of waiting
  # out the full readiness timeout.
  if ! kill -0 "$ollama_pid" 2>/dev/null; then
    echo "ERROR: ollama serve exited before becoming ready" >&2
    wait "$ollama_pid"
    exit $?
  fi
  sleep 1
done

if [ "$ready" -ne 1 ]; then
  echo "ERROR: ollama serve did not accept connections within ${OLLAMA_SERVER_READY_TIMEOUT_S}s" >&2
  kill -TERM "$ollama_pid" 2>/dev/null || true
  exit 1
fi

# `ollama list`'s first column is an exact model:tag -- match it anchored and
# whitespace-terminated so e.g. "llama3.2:3b" doesn't false-match
# "llama3.2:3b-instruct-q8_0" (same acceptable "." imprecision as
# Dockerfile.ollama's HEALTHCHECK -- see its comment). Only `ollama pull`
# (not `ollama list`) ever touches the network, and only when the model
# isn't already cached in the ollama-models volume -- a warm restart with
# the model already present doesn't re-hit ollama-egress-proxy/the registry
# at all.
if ollama list 2>/dev/null | grep -Eq "^${OLLAMA_MODEL}[[:space:]]"; then
  echo "Model '${OLLAMA_MODEL}' already present -- skipping pull."
else
  echo "Pulling '${OLLAMA_MODEL}' (via ollama-egress-proxy, timeout ${OLLAMA_PULL_TIMEOUT_S}s)..."
  timeout "${OLLAMA_PULL_TIMEOUT_S}" ollama pull "$OLLAMA_MODEL" &
  pull_pid=$!
  if wait "$pull_pid"; then
    pull_pid=""
  else
    # $? here is `wait`'s own exit status (the `if` condition wasn't
    # negated), so this is the real pull/timeout exit code, not a
    # negation artifact.
    pull_status=$?
    echo "ERROR: failed to pull model '${OLLAMA_MODEL}' (exit ${pull_status})" >&2
    pull_pid=""
    kill -TERM "$ollama_pid" 2>/dev/null || true
    exit 1
  fi
fi

echo "ollama warm complete: '${OLLAMA_MODEL}' present and server ready."
wait "$ollama_pid"
