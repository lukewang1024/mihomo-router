#!/bin/sh
# Run on a Linux router, with an unused test IP supplied by the operator.
set -eu
umask 077
: "${TAP_RELAY:?Set TAP_RELAY to the static helper}"
: "${LAN_BRIDGE:?Set the bridge to test}"
: "${TEST_CIDR:?Set an unused client IP/prefix}"
: "${TEST_GATEWAY:?Set the client gateway}"
: "${TEST_DNS:?Set the client DNS server}"
: "${TEST_URL:?Set an HTTPS target}"
: "${TEST_EXPECT_HTTP:?Set the expected HTTP status}"
case "$TEST_URL" in https://*) ;; *) echo 'TEST_URL must use HTTPS' >&2; exit 1 ;; esac
host=${TEST_URL#https://}; host=${host%%/*}; host=${host%%:*}
ns=mr-test-$$; ht=mr-th$$; ct=mr-tc$$
log=/tmp/mr-tap.$$.log; dnsdir=/etc/netns/$ns
pid=; owns_ns=0; owns_dns=0; owns_parent=0
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
    [ "$owns_ns" = 0 ] || ip netns del "$ns" 2>/dev/null || :
    if [ "$owns_dns" = 1 ]; then rm "$dnsdir/resolv.conf" 2>/dev/null || :; rmdir "$dnsdir" 2>/dev/null || :; fi
    [ "$owns_parent" = 0 ] || rmdir /etc/netns 2>/dev/null || :
    [ ! -f "$log" ] || rm "$log"
}
trap cleanup 0
trap 'exit 1' INT TERM
ip netns add "$ns"; owns_ns=1
if [ ! -d /etc/netns ]; then mkdir /etc/netns; owns_parent=1; fi
mkdir "$dnsdir"; owns_dns=1
printf 'nameserver %s\n' "$TEST_DNS" >"$dnsdir/resolv.conf"
"$TAP_RELAY" "/var/run/netns/$ns" "$ht" "$ct" >"$log" 2>&1 & pid=$!
for attempt in 1 2 3; do grep -q '^READY' "$log" && break; sleep 1; done
if ! grep -q '^READY' "$log"; then cat "$log" >&2; exit 1; fi
brctl addif "$LAN_BRIDGE" "$ht"
ip link set "$ht" up
ip netns exec "$ns" ip link set lo up
ip netns exec "$ns" ip addr add "$TEST_CIDR" dev "$ct"
ip netns exec "$ns" ip link set "$ct" up
ip netns exec "$ns" ip route add default via "$TEST_GATEWAY"
# /etc/netns resolver also prevents BusyBox's reverse-server lookup from
# hanging on the root namespace's loopback-only resolver.
lookup=$(ip netns exec "$ns" timeout -t 8 nslookup "$host" "$TEST_DNS")
printf '%s\n' "$lookup"
case ${TEST_DNS_KIND:-any} in
    fake) printf '%s\n' "$lookup" | grep -q '198\.18\.' ;;
    real) if printf '%s\n' "$lookup" | grep -q '198\.18\.'; then echo 'Unexpected fake DNS answer' >&2; exit 1; fi ;;
    any) : ;;
    *) echo 'Invalid TEST_DNS_KIND' >&2; exit 1 ;;
esac
if [ -n "${TEST_CA:-}" ]; then set -- --cacert "$TEST_CA"; else set --; fi
# No explicit proxy. Real DNS, TLS validation and router PREROUTING apply.
code=$(ip netns exec "$ns" curl --noproxy '*' "$@" -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$TEST_URL")
printf 'LAN ingress HTTPS status: %s (expected %s)\n' "$code" "$TEST_EXPECT_HTTP"
[ "$code" = "$TEST_EXPECT_HTTP" ]
