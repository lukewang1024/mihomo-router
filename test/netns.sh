#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/mihomo-router-netns.$$
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/run"

CONFIG=$TEST_ROOT/router.conf
cat >"$CONFIG" <<EOF
DATA_DIR=$TEST_ROOT/data
RUN_DIR=$TEST_ROOT/run
LAN_CIDRS="192.168.31.0/24"
BYPASS_CIDRS="10.0.0.0/8 192.168.0.0/16"
EOF
MIHOMO_ROUTER_CONFIG=$CONFIG
export MIHOMO_ROUTER_CONFIG

ip link add utun type dummy
ip link set utun up

"$PROJECT_DIR/bin/mihomo-router" firewall-up
iptables-save >"$TEST_ROOT/iptables.up"
ip rule show >"$TEST_ROOT/rules.up"
ip route show table 100 >"$TEST_ROOT/routes.up"

grep -q -- 'MR_TCP' "$TEST_ROOT/iptables.up"
grep -q -- 'MR_MARK' "$TEST_ROOT/iptables.up"
grep -q -- '--to-ports 7892' "$TEST_ROOT/iptables.up"
grep -q -- 'fwmark 0x1ed4.*lookup 100' "$TEST_ROOT/rules.up"
grep -q -- 'default dev utun' "$TEST_ROOT/routes.up"
grep -q -- '--dport 53 -j REDIRECT --to-ports 1053' "$TEST_ROOT/iptables.up"
grep -q -- '-d 198.18.0.0/16 -p tcp -j REDIRECT --to-ports 7892' "$TEST_ROOT/iptables.up"
grep -q -- '-d 198.18.0.0/16 -p udp -j MARK --set-xmark 0x1ed4/0xffffffff' "$TEST_ROOT/iptables.up"

"$PROJECT_DIR/bin/mihomo-router" firewall-up
iptables-save >"$TEST_ROOT/iptables.again"
test "$(grep -c -- '-d 198.18.0.0/16' "$TEST_ROOT/iptables.again")" -eq 2

"$PROJECT_DIR/bin/mihomo-router" firewall-down
if iptables-save | grep -q -- 'MR_TCP\|MR_MARK\|198.18.0.0/16\|--to-ports 1053'; then
	printf '%s\n' 'FAIL: custom chains remain after teardown' >&2
	exit 1
fi

printf '%s\n' 'PASS: real network namespace firewall integration'
