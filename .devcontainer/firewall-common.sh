#!/bin/bash
# Shared skeleton for the egress-allowlist firewalls in this directory.
# Sourced (not executed directly) by ollama-init-firewall.sh and
# init-firewall.sh, each of which supplies its own ipset name, domain list,
# and verification targets and calls these functions in sequence. Not every
# function here is a drop-in fit for both callers -- e.g. init-firewall.sh
# does NOT use firewall_common::allow_dns_and_loopback, because its
# historical (and deliberately preserved) DNS/SSH rules are a genuinely
# different rule set from this file's resolver-scoped DNS helper. See each
# caller's own inline comments for exactly which shared functions it uses
# and which it keeps inline, and why.
set -euo pipefail
IFS=$'\n\t'

# Captures Docker's embedded-DNS NAT rules, flushes all tables/chains and the
# named ipset (if it exists from a prior run), then restores just the DNS
# NAT rules. Must run before any other rule is added.
firewall_common::flush_and_restore_dns() {
  local ipset_name="$1"
  local docker_dns_rules

  docker_dns_rules=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  ipset destroy "$ipset_name" 2>/dev/null || true

  if [ -n "$docker_dns_rules" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$docker_dns_rules" | xargs -L 1 iptables -t nat
  else
    echo "No Docker DNS rules to restore"
  fi
}

# DNS scoped to the resolver(s) actually configured in /etc/resolv.conf
# (falling back to Docker's embedded-DNS address, 127.0.0.11, if that file
# has none) -- NOT a blanket "any destination, port 53" rule. A blanket rule
# would let a compromised container DNS-tunnel data out past the ipset
# allowlist entirely (queries to an attacker-controlled DNS server never
# touch the ipset-matched OUTPUT rule). Also allows loopback outright.
firewall_common::allow_dns_and_loopback() {
  local resolvers=()
  if [ -r /etc/resolv.conf ]; then
    while read -r ip; do
      resolvers+=("$ip")
    done < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
  fi
  if [ "${#resolvers[@]}" -eq 0 ]; then
    resolvers=("127.0.0.11")
  fi

  local ip
  for ip in "${resolvers[@]}"; do
    echo "Allowing DNS to resolver $ip"
    iptables -A OUTPUT -d "$ip" -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -s "$ip" -p udp --sport 53 -j ACCEPT
    # TCP DNS too -- large responses fall back from UDP to TCP.
    iptables -A OUTPUT -d "$ip" -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -s "$ip" -p tcp --sport 53 -j ACCEPT
  done

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
}

# Creates the named ipset and resolves+adds each domain's A records into it.
# Hard-fails (exit 1) on any resolution failure or malformed IP -- an empty
# or partial allowlist is a silent security downgrade, not something to
# shrug off.
#
# KNOWN LIMITATION (IP allowlisting vs. domain/SNI allowlisting): iptables
# matches on destination IP, not on SNI/Host, so this only ever allows "this
# IP address", never "this domain name". For any allowlisted domain that
# sits behind a shared CDN/anycast edge (Cloudflare, Azure Front Door, etc.),
# the resolved IP is shared with unrelated tenants of that same edge -- this
# rule then also permits reaching whatever else answers on that IP, not just
# the intended domain. This is a real, accepted gap in "deny-by-default with
# an explicit allowlist": it constrains egress to a specific edge/IP, not
# provably to a specific domain. It's the same reason a wildcard CDN host
# (e.g. *.r2.cloudflarestorage.com) can't be safely IP-allowlisted at all --
# callers of this function should resolve, case by case, whether the
# residual "shares an IP with other CDN tenants" exposure is acceptable for
# their domain, and prefer a domain/SNI-aware egress proxy instead when it
# isn't. Every domain-allowlisting firewall in this repo today accepts that
# residual exposure -- both this function's callers, ollama-init-firewall.sh
# and init-firewall.sh (the devcontainer service's own ipset-based
# allowlist), share it. See each caller's own comments for its specific
# domains and reasoning.
firewall_common::build_domain_allowlist() {
  local ipset_name="$1"
  shift
  local domains=("$@")

  ipset create "$ipset_name" hash:net

  local domain ips ip
  for domain in "${domains[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
      echo "ERROR: Failed to resolve $domain"
      exit 1
    fi

    while read -r ip; do
      if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: Invalid IP from DNS for $domain: $ip"
        exit 1
      fi
      echo "Adding $ip for $domain"
      ipset add "$ipset_name" "$ip"
    done < <(echo "$ips")
  done
}

# Derives HOST_NETWORK from this container's own default route (so it
# tracks a repinned subnet instead of a hardcoded literal) and allows it in
# both directions -- container-to-container traffic on the pinned compose
# subnet. Prints the detected network on stdout so the caller can capture
# it (e.g. `host_network=$(firewall_common::allow_host_network)`).
firewall_common::allow_host_network() {
  local host_ip
  host_ip=$(ip route | grep default | cut -d" " -f3)
  if [ -z "$host_ip" ]; then
    echo "ERROR: Failed to detect default route" >&2
    exit 1
  fi

  local host_network
  host_network=$(echo "$host_ip" | sed "s/\.[0-9]*$/.0\/24/")

  iptables -A INPUT -s "$host_network" -j ACCEPT
  iptables -A OUTPUT -d "$host_network" -j ACCEPT

  echo "$host_network"
}

# Sets default-DROP policies, allows established/related traffic, allows
# outbound traffic to the named ipset, and REJECTs (not silently drops)
# everything else on OUTPUT for immediate feedback.
firewall_common::lock_down() {
  local ipset_name="$1"

  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP

  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  iptables -A OUTPUT -m set --match-set "$ipset_name" dst -j ACCEPT

  iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
}

# Negative check: proves deny-by-default by confirming an off-allowlist
# destination is NOT reachable. Always a hard failure (exit 1) -- if this
# unexpectedly succeeds, the firewall isn't actually restricting anything,
# and that must stop the container rather than continue in a false sense of
# safety. Bounded with --max-time so a stalled TLS/HTTP phase (as opposed to
# a fast, expected connection failure) can't hang startup indefinitely.
# Optionally routes the check through a forwarding proxy (see
# verify_allow) for callers proving a proxy's own ACL denies a host it
# shouldn't allow, rather than proving the iptables layer denies it.
#
# CAUTION (Review Round 1 finding A): when via_proxy is NOT given, this is
# supposed to be a genuinely DIRECT check -- but curl also honors an
# ambient https_proxy/HTTPS_PROXY environment variable if one happens to
# be set in this process's environment (e.g. ollama's own container sets
# HTTPS_PROXY for ollama serve -- see docker-compose.yml -- and that env
# var is just as visible to this firewall script, which runs in the same
# container before ollama serve starts). Without --noproxy, a "direct"
# check would silently ride that ambient proxy instead, and calling
# verify_deny("https://registry.ollama.ai/v2/") with no via_proxy would
# then reach registry.ollama.ai anyway (the proxy's ACL allows it) and
# treat that success as a firewall failure -- exit 1 on every single
# startup. --noproxy '*' unconditionally overrides any ambient proxy env
# var for this one curl call, so the no-via_proxy path is always truly
# direct regardless of what's set in the calling environment.
firewall_common::verify_deny() {
  local deny_url="$1"
  local via_proxy="${2:-}"
  local -a curl_args=(--connect-timeout 5 --max-time 10)
  if [ -n "$via_proxy" ]; then
    curl_args+=(-x "$via_proxy")
  else
    curl_args+=(--noproxy '*')
  fi

  if curl "${curl_args[@]}" "$deny_url" >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach $deny_url${via_proxy:+ via $via_proxy}"
    exit 1
  fi
  echo "Firewall verification passed - unable to reach $deny_url${via_proxy:+ via $via_proxy} as expected"
}

# Positive check: confirms an allowlisted destination IS reachable. This is
# a sanity check on the rules just built, not something the workload itself
# needs in order to start, so it soft-fails (warns and continues) by
# default -- a transient registry/DNS blip shouldn't permanently wedge the
# container on every restart. Pass hard_fail=1 for callers that want it
# fatal instead. Optionally routes the check through a forwarding proxy
# (e.g. "http://ollama-egress-proxy:3128") for callers whose firewall no
# longer allowlists the destination directly and instead relies on a
# domain/SNI-scoped proxy to reach it -- see ollama-init-firewall.sh.
# Bounded with --max-time for the same reason as verify_deny. Also matches
# verify_deny's --noproxy '*' on the no-via_proxy path -- see verify_deny's
# CAUTION comment for why an unqualified "direct" curl can't be trusted to
# actually be direct if an ambient https_proxy/HTTPS_PROXY is set.
firewall_common::verify_allow() {
  local allow_url="$1"
  local hard_fail="${2:-0}"
  local via_proxy="${3:-}"
  local -a curl_args=(--connect-timeout 5 --max-time 10)
  if [ -n "$via_proxy" ]; then
    curl_args+=(-x "$via_proxy")
  else
    curl_args+=(--noproxy '*')
  fi

  if curl "${curl_args[@]}" "$allow_url" >/dev/null 2>&1; then
    echo "Firewall verification passed - able to reach $allow_url as expected${via_proxy:+ (via $via_proxy)}"
    return 0
  fi

  if [ "$hard_fail" = "1" ]; then
    echo "ERROR: Firewall verification failed - unable to reach $allow_url${via_proxy:+ via $via_proxy}"
    exit 1
  fi
  echo "WARNING: Firewall verification - unable to reach $allow_url${via_proxy:+ via $via_proxy} (sanity check only; not required for the workload to start, continuing)"
  return 0
}
