#!/bin/sh
# Destructive only to the supplied gateway's router-originated SSH transport.
# Run explicitly on the router, after enabling automatic failover. Restores its
# own firewall rules on exit; never disconnects the router's management SSH.
set -eu
: "${TEST_GATEWAY_IP:?Supply the selected endpoint IPv4 address}"
: "${TEST_GATEWAY_PORT:?Supply its SSH port}"
case "$TEST_GATEWAY_IP" in *[!0-9.]*|'') exit 2 ;; esac
case "$TEST_GATEWAY_PORT" in *[!0-9]*|'') exit 2 ;; esac
# shellcheck disable=SC1090
. "${MIHOMO_ROUTER_CONFIG:-/data/mihomo-router/router.conf}"
TEST_WAIT=${TEST_WAIT:-180}
umask 077
tmp=$(mktemp -d /tmp/mr-failover-live.XXXXXX)
chain=MR_FAILOVER_TEST
owned=0; attached=0
cleanup() {
    [ "$attached" = 0 ] || iptables -w 5 -D OUTPUT -d "$TEST_GATEWAY_IP" -p tcp --dport "$TEST_GATEWAY_PORT" -j "$chain" 2>/dev/null || :
    if [ "$owned" = 1 ]; then iptables -w 5 -F "$chain"; iptables -w 5 -X "$chain"; fi
    rm -rf "$tmp"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
printf 'header = "Authorization: Bearer %s"\n' "$CONTROLLER_SECRET" >"$tmp/auth"
api() {
    api_path=$1; shift
    curl --noproxy '*' --config "$tmp/auth" -fsS --connect-timeout 2 --max-time 10 "$@" "http://$CONTROLLER_ADDRESS$api_path"
}
route() { api /proxies/SSH-Gateway-Route >"$tmp/route"; jsonfilter -i "$tmp/route" -e '@.now'; }
await_route() {
    wanted=$1; started=$(date +%s)
    while [ "$(route)" != "$wanted" ]; do
        [ "$(($(date +%s)-started))" -lt "$TEST_WAIT" ] || { echo "FAIL: timed out waiting for $wanted" >&2; exit 1; }
        sleep 2
    done
    printf 'PASS: effective route=%s after %ss\n' "$wanted" "$(($(date +%s)-started))"
}
core_before=$(pidof mihomo)
await_route SSH-Gateway
iptables -w 5 -N "$chain"; owned=1
iptables -w 5 -A "$chain" -j DROP
iptables -w 5 -I OUTPUT 1 -d "$TEST_GATEWAY_IP" -p tcp --dport "$TEST_GATEWAY_PORT" -j "$chain"; attached=1
await_route DIRECT
# Flush first: this must be a fresh real DNS lookup, not Fake-IP or a cache hit.
api /cache/dns/flush -X POST >/dev/null
health_host=${SSH_GATEWAY_HEALTH_URL#*://}; health_host=${health_host%%/*}; health_host=${health_host%%:*}
api /dns/query -G --data-urlencode "name=$health_host" --data-urlencode type=A >"$tmp/dns"
rcode=$(jsonfilter -i "$tmp/dns" -e '@.Status')
[ "$rcode" = 0 ] || { echo "FAIL: fallback DNS returned $rcode" >&2; exit 1; }
echo 'PASS: fresh private-domain DNS succeeds while phone transport is blocked'
api /rules >"$tmp/rules"
grep -q SSH-Gateway-Route "$tmp/rules"
iptables -w 5 -D OUTPUT -d "$TEST_GATEWAY_IP" -p tcp --dport "$TEST_GATEWAY_PORT" -j "$chain"; attached=0
await_route SSH-Gateway
code=$(curl --noproxy '' --proxy "http://127.0.0.1:${MIXED_PORT:-7890}" -sS -I --connect-timeout 3 --max-time 8 -o /dev/null -w '%{http_code}' "$SSH_GATEWAY_HEALTH_URL")
case "$code" in 2??|3??) ;; *) echo "FAIL: recovered target HTTP=$code" >&2; exit 1 ;; esac
[ "$(pidof mihomo)" = "$core_before" ] || { echo 'FAIL: core restarted during failover' >&2; exit 1; }
printf 'PASS: recovered internal HTTP=%s; core PID unchanged\n' "$code"
