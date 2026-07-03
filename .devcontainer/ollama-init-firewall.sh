#!/bin/bash
# Deny-by-default egress firewall for the ollama sidecar's OWN network
# namespace. init-firewall.sh (in this same directory) only ever runs inside
# the devcontainer service — it's the only OTHER service with NET_ADMIN/
# NET_RAW — so it cannot constrain this container. This script applies the
# same deny-by-default/ipset-allowlist model (shared skeleton lives in
# firewall-common.sh), scoped to what ollama genuinely needs. Run at
# container start via ollama-entrypoint.sh (baked into Dockerfile.ollama),
# since plain `docker compose up` has no postStartCommand-style hook the way
# the devcontainer CLI gives the "devcontainer" service.
#
# Allowed, and why:
#   - loopback, DNS to the resolver(s) in /etc/resolv.conf (tcp+udp/53,
#     falling back to Docker's embedded 127.0.0.11 if none are listed) --
#     NOT DNS to any destination, which would be a tunnelable exfil channel
#   - established/related return traffic
#   - the pinned 172.28.0.0/24 subnet (docker-compose.yml), so the
#     devcontainer/MCP callers on that subnet keep reaching ollama:11434
#   - registry.ollama.ai — ollama's own model-manifest/tag registry
#
# KNOWN LIMITATION -- registry.ollama.ai is CDN-fronted, same as the blob
# host we refuse to allowlist below: `dig +short registry.ollama.ai A`
# returns 104.21.75.227 and 172.67.182.229, both within Cloudflare's
# published anycast ranges (104.16.0.0/13 and 172.64.0.0/13 per
# cloudflare.com/ips) -- confirmed by direct lookup while writing this, not
# assumed. iptables matches destination IP, not SNI/Host, so this ipset rule
# actually allows "that Cloudflare edge IP", not provably "just
# registry.ollama.ai" -- any other tenant Cloudflare happens to route to the
# same anycast IP is also reachable through this rule. The residual exposure
# is bounded to whatever shares that edge (Cloudflare-fronted HTTPS traffic
# in general), not open internet egress. This is a real, accepted gap in
# "deny-by-default with an explicit allowlist" for THIS domain specifically,
# not a new one unique to ollama: init-firewall.sh's own allowlist has the
# identical limitation for every CDN-fronted domain it already allows today
# (registry.npmjs.org resolves to 104.16.x.x, also Cloudflare, by the same
# lookup method), so this is the repo's existing, consistent posture for
# ipset-based allowlisting, not a regression. See
# firewall-common.sh:build_domain_allowlist for the general note. A tighter,
# domain/SNI-scoped control (a forwarding proxy with a domain ACL) would
# close this for both the registry and the blob host below; that's deferred
# to the same proxy claude-r30.2 is expected to introduce for blob egress,
# not built here.
#
# Deliberately NOT allowed (yet):
#   - model *blob* downloads. `ollama pull` fetches manifests from
#     registry.ollama.ai but redirects the actual layer blobs to
#     *.r2.cloudflarestorage.com — a Cloudflare-anycast host whose IPs are
#     shared with unrelated tenants, so IP-allowlisting it here would open far
#     more than "ollama blobs". Full model-pull egress is left for
#     claude-r30.2 to solve, most likely via a forwarding proxy with a
#     domain/SNI ACL rather than widening this ipset to a shared anycast
#     range.
set -euo pipefail
IFS=$'\n\t'

source /usr/local/bin/firewall-common.sh

readonly IPSET_NAME="ollama-allowed-domains"
readonly ALLOWED_DOMAINS=("registry.ollama.ai")

firewall_common::flush_and_restore_dns "$IPSET_NAME"
firewall_common::allow_dns_and_loopback
firewall_common::build_domain_allowlist "$IPSET_NAME" "${ALLOWED_DOMAINS[@]}"

host_network=$(firewall_common::allow_host_network)
echo "Host network detected as: $host_network"

firewall_common::lock_down "$IPSET_NAME"

echo "ollama firewall configuration complete"
echo "Verifying firewall rules..."
# Hard fail: proves deny-by-default actually denies.
firewall_common::verify_deny "https://example.com"
# Soft fail: sanity check on the rules just built, not a startup
# requirement for ollama serve -- see firewall-common.sh's verify_allow.
firewall_common::verify_allow "https://registry.ollama.ai/v2/"

echo "ollama egress firewall active: DNS (resolv.conf resolver(s) only), ${host_network} (container-to-container), and registry.ollama.ai only."
