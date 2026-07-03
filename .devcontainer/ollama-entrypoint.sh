#!/bin/bash
# Applies the deny-by-default egress firewall in this container's own network
# namespace, then hands off to the real ollama entrypoint. Baked in as the
# image ENTRYPOINT (see Dockerfile.ollama) so it runs on every `docker compose
# up`, not just under an orchestrator that supports postStartCommand-style
# hooks (compose itself doesn't for non-devcontainer-CLI services).
set -euo pipefail

/usr/local/bin/ollama-init-firewall.sh

# The firewall above needs NET_ADMIN/NET_RAW (granted via cap_add in
# docker-compose.yml) to program iptables/ipset; `ollama serve` itself needs
# neither. Holding those caps for the rest of the container's life would let
# a compromised ollama process undo its own firewall (`iptables -F` /
# `ipset destroy`) just as easily as this script built it. Drop them from
# the bounding set (and inheritable set, for consistency -- see setpriv(1))
# before handing off, so the exec'd process -- and anything it forks --
# can't reacquire them even though it stays root: a root process can only
# gain back a capability on execve if it's still in the bounding set, and
# this clears it from there permanently for the rest of this container's
# life. setpriv is part of util-linux, already present in the ollama base
# image (verified at build time in Dockerfile.ollama).
exec setpriv --bounding-set=-cap_net_admin,-cap_net_raw \
             --inh-caps=-cap_net_admin,-cap_net_raw \
             /bin/ollama "$@"
