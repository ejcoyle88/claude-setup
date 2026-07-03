#!/bin/bash
# Applies the deny-by-default egress firewall in this container's own network
# namespace, then (for the long-running `serve` command only -- see the WARM
# section below) warms the configured model before handing off to the real
# ollama server. Baked in as the image ENTRYPOINT (see Dockerfile.ollama) so
# it runs on every `docker compose up`, not just under an orchestrator that
# supports postStartCommand-style hooks (compose itself doesn't for
# non-devcontainer-CLI services).
set -euo pipefail

readonly SETPRIV_DROP=(--bounding-set=-cap_net_admin,-cap_net_raw --inh-caps=-cap_net_admin,-cap_net_raw)

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
