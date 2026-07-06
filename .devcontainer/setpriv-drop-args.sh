#!/bin/bash
# Single source of truth for the setpriv cap-drop args that strip
# NET_ADMIN/NET_RAW from the ollama container's process tree once the egress
# firewall (ollama-init-firewall.sh) has been applied. Meant to be SOURCED,
# not executed: it only declares the SETPRIV_DROP array, nothing else.
#
# claude-241: previously ollama-entrypoint.sh (at runtime) and
# Dockerfile.ollama's build-time setpriv guard each hardcoded their own copy
# of this array -- two byte-identical-by-coincidence literals that could
# silently drift apart (e.g. someone reintroducing cap_-prefixed names, which
# setpriv rejects, in one copy but not the other). Both now source this one
# file instead, so there is exactly one place to change the drop args and no
# second literal that can go stale.
#
# shellcheck disable=SC2034 # sourced by callers, not used in this file
# shellcheck disable=SC2054 # setpriv's own comma-separated cap-list syntax,
# not a shell array -- not a typo for space-separated elements
readonly SETPRIV_DROP=(--bounding-set=-net_admin,-net_raw --inh-caps=-net_admin,-net_raw)
