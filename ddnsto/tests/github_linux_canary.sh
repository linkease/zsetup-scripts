#!/bin/sh
# Test-only: run in a disposable Alpine Docker container with NET_ADMIN.
# Never execute this harness on a host. No real user token is used.
set -eu
test -f /.dockerenv
test "${DDNSTO_CANARY_CONTAINER:-}" = 1
: "${ENTRY_URL:?fixed GitHub commit URL required}" "${ENTRY_SHA:?entry SHA256 required}"
case "$ENTRY_URL" in https://raw.githubusercontent.com/linkease/zsetup-scripts/*/ddnsto/install.sh) ;; *) exit 2 ;; esac
apk add --no-cache curl ca-certificates openrc iptables python3
mkdir -p /run/openrc
touch /run/openrc/softlevel

# Container-only egress filter: allow DNS and the resolved download hosts on
# TLS443. No cloud control/tunnel access, even with a synthetic token.
addresses=$(python3 -c 'import socket
hosts=["raw.githubusercontent.com", "dl.istoreos.com", "fw.d4ctech.com", "fw20.koolcenter.com", "fw.koolcenter.com"]
for host in hosts:
    for ip in sorted({x[4][0] for x in socket.getaddrinfo(host,443,socket.AF_INET)}): print(ip)')
test -n "$addresses"
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
for ip in $addresses; do iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT; done
iptables -A OUTPUT -j REJECT
# IPv6 must be disabled by docker --sysctl, otherwise refuse the test.
test "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1
if curl -fsS --connect-timeout 2 --max-time 3 http://tunnel.kooldns.cn:4445/; then
    printf '%s\n' 'Cloud egress unexpectedly permitted' >&2
    exit 1
fi

test ! -e /usr/local/bin/ddnsto
test ! -e /tmp/zsetup
umask 077
printf '%s\n' 'github-canary-not-an-account-token' > /tmp/canary-token
curl -fsSL --proto '=https' --proto-redir '=https' "$ENTRY_URL" -o /tmp/github-entry.sh
printf '%s  %s\n' "$ENTRY_SHA" /tmp/github-entry.sh | sha256sum -c -
# This is the same one-command path as the user, with a synthetic token file.
sh -c 'entry=$(curl -fsSL --proto "=https" --proto-redir "=https" "$ENTRY_URL") && test -n "$entry" && sh -c "$entry" install.sh --token-file /tmp/canary-token'
rc-service ddnsto status
curl -fsS http://127.0.0.1:18333/healthz
printf '\n%s\n' 'COLD_INSTALL_OK'
sh -c 'entry=$(curl -fsSL --proto "=https" --proto-redir "=https" "$ENTRY_URL") && test -n "$entry" && sh -c "$entry" install.sh --token-file /tmp/canary-token'
rc-service ddnsto status
curl -fsS http://127.0.0.1:18333/healthz
printf '\n%s\n' 'REPEAT_INSTALL_OK cloud_status=not_tested'
rc-service ddnsto stop
