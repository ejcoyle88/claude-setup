#!/bin/bash
# Deny-by-default egress firewall for the devcontainer service's OWN network
# namespace. Run via `sudo /usr/local/bin/init-firewall.sh` (see
# .devcontainer/Dockerfile's node-firewall sudoers entry). Shares the
# skeleton in firewall-common.sh with ollama-init-firewall.sh (the sidecar's
# equivalent firewall) so the two can't silently drift apart -- but this
# script's ALLOWED destinations and a couple of rule details are genuinely
# different from ollama's, and are NOT drop-in swaps for the shared
# functions of the same shape. See the inline notes below for each place
# this script deliberately does NOT call the "obvious" shared helper.
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# shellcheck source=firewall-common.sh
source /usr/local/bin/firewall-common.sh

readonly IPSET_NAME="allowed-domains"
readonly ALLOWED_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "sentry.io"
    "statsig.anthropic.com"
    "statsig.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
)

firewall_common::flush_and_restore_dns "$IPSET_NAME"

# NOT firewall_common::allow_dns_and_loopback(): that helper scopes DNS to
# the resolver(s) in /etc/resolv.conf and only opens UDP+TCP/53. This
# script's historical, proven behavior is a blanket "any destination,
# UDP/53" DNS rule plus its own SSH allowance (outbound tcp/22, and
# established-only inbound tcp/22) that the shared helper has no equivalent
# for at all. Preserving that exact rule set (not "fixing" it to the
# tighter, resolver-scoped behavior) is what this migration bead requires --
# byte-for-byte identical rule outcomes, not a security hardening. Kept
# inline rather than folded into firewall-common.sh so the shared skeleton
# doesn't normalize the wider DNS rule for future callers.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Resolve and add the plain-domain allowlist first. This also performs the
# ipset creation (`ipset create allowed-domains hash:net`) -- deliberately
# BEFORE the GitHub CIDR block below, not after, because
# firewall_common::build_domain_allowlist does an unconditional `ipset
# create` with no `-exist` guard; calling it after the ipset already has
# entries (from creating it and adding CIDRs manually first, as the
# pre-migration script order did) would fail outright ("set already
# exists"). Reordering is safe: ipset is an unordered set for matching
# purposes, so the final allowed set and every rule outcome are identical
# either way -- only the historical add-order (GitHub ranges before
# individual domains) changes to (individual domains before GitHub ranges).
firewall_common::build_domain_allowlist "$IPSET_NAME" "${ALLOWED_DOMAINS[@]}"

# Fetch GitHub meta information and aggregate + add their IP ranges. No
# equivalent in firewall-common.sh (ollama's firewall has no CIDR-range
# allowlisting need), so this stays inline.
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add "$IPSET_NAME" "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

host_network=$(firewall_common::allow_host_network)
echo "Host network detected as: $host_network"

firewall_common::lock_down "$IPSET_NAME"

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
firewall_common::verify_deny "https://example.com"
# Hard fail (matches this script's pre-migration exit-1-on-failure behavior
# for this specific check): hard_fail=1.
firewall_common::verify_allow "https://api.github.com/zen" 1
