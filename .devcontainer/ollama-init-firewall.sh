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
#
# SCOPE NOTE (Review Round 1 finding E -- corrects an earlier, inaccurate
# version of this comment): the host-network rule above is bidirectional
# and subnet-wide -- allow_host_network (firewall-common.sh, shared with
# the devcontainer's own firewall) ACCEPTs ollama's OUTPUT to the ENTIRE
# 172.28.0.0/24 pinned subnet, not just to ollama-egress-proxy. That means
# ollama can also reach otel-collector, prometheus, loki, and grafana at
# L3/L4 -- it is NOT scoped to "the proxy and nothing else". This is
# inherited, not something newly widened for the proxy: the same rule
# already existed pre-claude-5r7 to let the devcontainer/MCP reach
# ollama:11434, and narrowing it to a single destination would mean either
# duplicating a chunk of the shared skeleton here or editing
# firewall-common.sh's generic, devcontainer-shared behavior -- both a
# larger, riskier change than this bead's scope. What's still true, and is
# the actual security boundary that matters: none of those other sidecars
# provide ollama an *internet*-egress path -- they don't proxy or forward
# arbitrary outbound traffic -- so reaching them doesn't let a compromised
# ollama reach anything beyond this subnet. The ONLY path off this subnet
# is through ollama-egress-proxy, and that path is gated by its own
# domain/SNI ACL (squid-ollama-egress.conf), not by this iptables layer.
#
# SUPERSEDED (claude-5r7): this firewall used to also IP-allowlist
# registry.ollama.ai directly via ipset, with a documented KNOWN LIMITATION
# that registry.ollama.ai is Cloudflare-anycast (`dig +short registry.ollama.ai A`
# => 104.21.75.227 / 172.67.182.229, both within Cloudflare's published
# 104.16.0.0/13 / 172.64.0.0/13 ranges), so iptables (destination-IP-only
# matching) couldn't actually distinguish "registry.ollama.ai" from any
# other tenant sharing that edge IP -- and, for the identical reason, could
# never safely allowlist the *.r2.cloudflarestorage.com hosts `ollama pull`
# redirects blob downloads to, so blob pulls were left deliberately broken.
# claude-5r7 closes both gaps the same way: ALLOWED_DOMAINS is now empty --
# ollama's own network namespace has no ipset-based external allowlist at
# all -- and all registry/blob traffic instead flows through the
# ollama-egress-proxy sidecar (docker-compose.yml, HTTPS_PROXY env var in
# the x-ollama-common anchor), which enforces a domain/SNI ACL for exactly
# those hosts (see squid-ollama-egress.conf) instead of an IP ipset. Reaching
# that proxy (and the rest of the pinned subnet -- see the SCOPE NOTE above)
# is already covered by the host-network rule, so no ipset entry is needed
# for it either.
set -euo pipefail
IFS=$'\n\t'

# shellcheck source=firewall-common.sh
source /usr/local/bin/firewall-common.sh

readonly IPSET_NAME="ollama-allowed-domains"
# Empty on purpose -- see the SUPERSEDED note above. All external egress now
# goes through ollama-egress-proxy instead of a direct ipset entry.
readonly ALLOWED_DOMAINS=()
readonly EGRESS_PROXY="http://ollama-egress-proxy:3128"

firewall_common::flush_and_restore_dns "$IPSET_NAME"
firewall_common::allow_dns_and_loopback
firewall_common::build_domain_allowlist "$IPSET_NAME" "${ALLOWED_DOMAINS[@]}"

host_network=$(firewall_common::allow_host_network)
echo "Host network detected as: $host_network"

firewall_common::lock_down "$IPSET_NAME"

echo "ollama firewall configuration complete"
echo "Verifying firewall rules..."
# Hard fail: proves deny-by-default actually denies, generally...
firewall_common::verify_deny "https://example.com"
# ...and specifically for registry.ollama.ai, which this firewall no
# longer allowlists directly at all -- only the proxy route below is
# permitted to reach it.
firewall_common::verify_deny "https://registry.ollama.ai/v2/"
# Hard fail: proves the proxy's own ACL actually denies a host it
# shouldn't allow -- not just that this container's iptables denies it
# directly (the check above).
#
# CORRECTED CLAIM (Review Round 2 finding W2): this only exercises the
# proxy's LAYER 1 (squid-ollama-egress.conf's CONNECT-line `allowed_dst`
# dstdomain check) -- www.cloudflare.com isn't on that list, so
# `http_access deny CONNECT !allowed_dst` rejects the CONNECT before Squid
# ever peeks a TLS ClientHello or looks at any real SNI. It does NOT
# exercise LAYER 2 (the ssl_bump peek/splice/terminate block, i.e. the
# actual domain-fronting fix from Review Round 1 finding C) -- this check
# would still pass even if that whole ssl_bump block were deleted. A
# genuine layer-2 regression test needs to present an ALLOWED CONNECT-line
# host with a DISALLOWED real SNI in the ClientHello (something lower-level
# than `curl -x`, e.g. a raw CONNECT handshake piped into `openssl
# s_client -servername <disallowed-host>`), which isn't wired up here --
# doing that robustly at container-startup time, without new tooling and
# without risking a flaky/hanging boot, was judged not cleanly doable for
# a startup check. Still a hard fail, and still a real (if partial)
# check: it does prove the proxy's own ACL denies a host this container's
# ipset doesn't even see, not just that iptables denies it directly.
firewall_common::verify_deny "https://www.cloudflare.com" "$EGRESS_PROXY"
# Soft fail: sanity check that the proxy route actually works end to
# end -- reaches ollama-egress-proxy over the pinned subnet, which then
# allows CONNECT to registry.ollama.ai per its own ACL. Not a hard startup
# requirement for ollama serve -- see firewall-common.sh's verify_allow --
# since a transient proxy-build/registry blip shouldn't wedge the sidecar.
firewall_common::verify_allow "https://registry.ollama.ai/v2/" 0 "$EGRESS_PROXY"

echo "ollama egress firewall active: DNS (resolv.conf resolver(s) only), ${host_network} (container-to-container, subnet-wide -- see the SCOPE NOTE above), no other direct external egress; internet egress only via ollama-egress-proxy's own domain/SNI ACL."
