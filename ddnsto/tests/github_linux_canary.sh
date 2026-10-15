#!/bin/sh
# Test-only: run in a disposable Alpine Docker container with NET_ADMIN.
# Never execute this harness on a host. No real user token is used.
set -eu
: "${ENTRY_URL:?immutable entry URL required}" "${ENTRY_SHA:?entry SHA256 required}"
test "${#ENTRY_SHA}" = 64 || exit 2
case "$ENTRY_SHA" in *[!0-9a-f]*) exit 2 ;; esac
case "$ENTRY_URL" in
    https://raw.githubusercontent.com/linkease/zsetup-scripts/*/ddnsto/install.sh)
        revision=${ENTRY_URL#https://raw.githubusercontent.com/linkease/zsetup-scripts/}
        revision=${revision%/ddnsto/install.sh}
        test "${#revision}" = 40 || exit 2
        case "$revision" in *[!0-9a-f]*) exit 2 ;; esac
        ;;
    https://web.toany.net/ddnsto-install/0.1.9/*/install.sh|https://web.toany.net/ddnsto-install/0.1.10/*/install.sh)
        build=${ENTRY_URL#https://web.toany.net/ddnsto-install/}
        build=${build#*/}
        build=${build%/install.sh}
        case "$build" in ''|*[!0-9a-f-]*) exit 2 ;; esac
        case "$build" in 20??????-?*) ;; *) exit 2 ;; esac
        ;;
    *) exit 2 ;;
esac
case "${1:-}" in
    --check-entry) printf '%s\n' 'ENTRY_CONTRACT_OK'; exit 0 ;;
    '') ;;
    *) exit 2 ;;
esac
test -f /.dockerenv
test "${DDNSTO_CANARY_CONTAINER:-}" = 1
# Use the reachable Alpine mirror for test prerequisites only. APK signatures
# remain enforced; neither installer sources nor product sources are changed.
apk --repositories-file /dev/null \
    --repository https://mirrors.aliyun.com/alpine/v3.20/main \
    --repository https://mirrors.aliyun.com/alpine/v3.20/community \
    add --no-cache curl ca-certificates openrc iptables python3
mkdir -p /run/openrc/starting /run/openrc/started /run/openrc/stopping \
    /run/openrc/failed /run/openrc/inactive /run/openrc/wasinactive /run/openrc/exclusive
touch /run/openrc/softlevel

test ! -e /usr/local/bin/ddnsto
test ! -e /tmp/zsetup
umask 077
printf '%s\n' 'github-canary-not-an-account-token' > /tmp/canary-token
# Fetch before a client exists. The test domain also serves cloud endpoints,
# so it must NOT stay reachable once the client is installed and running.
curl -fsSL --retry 2 --retry-delay 1 --connect-timeout 10 --max-time 60 --proto '=https' --proto-redir '=https' "$ENTRY_URL" -o /tmp/github-entry.sh
printf '%s  %s\n' "$ENTRY_SHA" /tmp/github-entry.sh | sha256sum -c -

# Container-only egress filter: DNS plus product/native download hosts TLS443.
addresses=$(python3 -c 'import socket
hosts=["dl.istoreos.com", "fw.d4ctech.com", "fw20.koolcenter.com", "fw.koolcenter.com"]
for host in hosts:
    for ip in sorted({x[4][0] for x in socket.getaddrinfo(host,443,socket.AF_INET)}): print(ip)')
test -n "$addresses"
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
for ip in $addresses; do iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT; done
iptables -A OUTPUT -j REJECT
# Deny the cloud/test host even if it shares an address with an allowed CDN.
cloud_addresses=$(python3 -c 'import socket
for host in ["web.toany.net", "tunnel.kooldns.cn"]:
    for ip in sorted({x[4][0] for x in socket.getaddrinfo(host,None,socket.AF_INET)}): print(ip)')
for ip in $cloud_addresses; do iptables -I OUTPUT 1 -p tcp -d "$ip" -j REJECT; done
# IPv6 must be disabled by docker --sysctl, otherwise refuse the test.
test "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1
python3 -c 'import socket
for host, port in [("web.toany.net",443),("web.toany.net",9445),("tunnel.kooldns.cn",4445)]:
    try:
        with socket.create_connection((host,port),timeout=2): pass
    except OSError:
        continue
    raise SystemExit("Cloud TCP egress unexpectedly permitted: %s:%d" % (host,port))
print("CLOUD_EGRESS_BLOCKED")'

# Execute only the already verified entry; retain stdin like the user's command.
# Repeat from the same bytes without reopening cloud-host egress.
entry=$(cat /tmp/github-entry.sh)
sh -c "$entry" install.sh --token-file /tmp/canary-token
rc-service com.linkease.ddnstoshell status
curl -fsS http://127.0.0.1:18333/healthz
printf '\n%s\n' 'COLD_INSTALL_OK'
sh -c "$entry" install.sh --token-file /tmp/canary-token
rc-service com.linkease.ddnstoshell status
curl -fsS http://127.0.0.1:18333/healthz
printf '\n%s\n' 'REPEAT_INSTALL_OK cloud_status=not_tested'
rc-service com.linkease.ddnstoshell stop
