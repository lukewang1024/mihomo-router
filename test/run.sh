#!/bin/sh

set -eu

PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/mihomo-router-test.$$
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/run" "$TEST_ROOT/bin"
cp "$PROJECT_DIR/test/mocks/mihomo" "$TEST_ROOT/bin/mihomo"
chmod 755 "$TEST_ROOT/bin/mihomo"
gzip -c "$TEST_ROOT/bin/mihomo" >"$TEST_ROOT/data/mihomo.gz"
mkdir -p "$TEST_ROOT/tar-source"
cp "$TEST_ROOT/bin/mihomo" "$TEST_ROOT/tar-source/CrashCore"
tar -czf "$TEST_ROOT/data/mihomo.tar.gz" -C "$TEST_ROOT/tar-source" CrashCore

MOCK_LOG=$TEST_ROOT/commands.log
export MOCK_LOG
CONFIG=$TEST_ROOT/router.conf
cat >"$CONFIG" <<EOF
DATA_DIR=$TEST_ROOT/data
RUN_DIR=$TEST_ROOT/run
CORE_ARCHIVE=$TEST_ROOT/data/mihomo.gz
SUBSCRIPTION_URL=file://$PROJECT_DIR/test/fixtures/subscription.yaml
LAN_CIDRS="192.168.31.0/24 192.168.19.0/24"
BYPASS_CIDRS="10.0.0.0/8 192.168.0.0/16"
IPTABLES=$PROJECT_DIR/test/mocks/iptables
IP=$PROJECT_DIR/test/mocks/ip
CURL=$PROJECT_DIR/test/mocks/curl
EOF
MIHOMO_ROUTER_CONFIG=$CONFIG
export MIHOMO_ROUTER_CONFIG

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_grep() {
	grep -q "$1" "$2" || fail "missing pattern $1 in $2"
}

assert_not_grep() {
	if grep -q "$1" "$2"; then
		fail "unexpected pattern $1 in $2"
	fi
}

output=$TEST_ROOT/rendered.yaml
"$PROJECT_DIR/bin/mihomo-router" render "$PROJECT_DIR/test/fixtures/subscription.yaml" "$output"
assert_grep '^    listen: 0.0.0.0:1053$' "$output"
assert_grep '^  enhanced-mode: fake-ip$' "$output"
test "$(grep -c '^dns:' "$output")" -eq 1 || fail "subscription DNS block was not preserved exactly once"
assert_grep '^redir-port: 7892$' "$output"
assert_grep '^tproxy-port: 7893$' "$output"
assert_grep '^tun: {enable: true, stack: system, device: utun, auto-route: false, auto-detect-interface: false, dns-hijack: \[\]}$' "$output"

install_root=$TEST_ROOT/install-root
"$PROJECT_DIR/install.sh" "$install_root" >/dev/null
[ -x "$install_root/data/mihomo-router/bin/mihomo-router" ] || fail "controller not installed in writable data partition"
[ -x "$install_root/etc/init.d/mihomo-router" ] || fail "procd init script not installed"
[ -r "$install_root/etc/mihomo-router.conf" ] || fail "configuration not installed"
assert_grep '^PROG=/data/mihomo-router/bin/mihomo-router$' "$install_root/etc/init.d/mihomo-router"

argument_install_root=$TEST_ROOT/argument-install-root
"$PROJECT_DIR/install.sh" --root "$argument_install_root" --subscription-url 'https://subscription.invalid/from-argument' >/dev/null
assert_grep "^SUBSCRIPTION_URL='https://subscription.invalid/from-argument'$" "$argument_install_root/etc/mihomo-router.conf"

migration_source=$TEST_ROOT/ShellCrash.cfg
printf "%s\n" "Url='https://subscription.invalid/client?key=fixture'" >"$migration_source"
MIHOMO_ROUTER_CONFIG=$install_root/etc/mihomo-router.conf "$install_root/data/mihomo-router/bin/mihomo-router" migrate-shellcrash "$migration_source" >/dev/null
assert_grep "^SUBSCRIPTION_URL='https://subscription.invalid/client?key=fixture'$" "$install_root/etc/mihomo-router.conf"
case "$(uname -s)" in
	Darwin) migration_mode=$(stat -f '%Lp' "$install_root/etc/mihomo-router.conf") ;;
	*) migration_mode=$(stat -c '%a' "$install_root/etc/mihomo-router.conf") ;;
esac
test "$migration_mode" = 600 || fail "migrated config permissions are not 600"

: >"$MOCK_LOG"
"$PROJECT_DIR/bin/mihomo-router" firewall-up
assert_grep 'iptables -t nat -A PREROUTING .* -j MR_TCP' "$MOCK_LOG"
assert_grep 'iptables -t mangle -A PREROUTING .* -j MR_MARK' "$MOCK_LOG"
assert_grep 'iptables -t nat -A MR_TCP -s 192.168.31.0/24 -p tcp -j REDIRECT --to-ports 7892' "$MOCK_LOG"
assert_grep 'ip rule add fwmark 0x1ed4 table 100' "$MOCK_LOG"
assert_grep 'ip route add default dev utun table 100' "$MOCK_LOG"
assert_grep 'iptables -t nat -A PREROUTING -s 192.168.31.0/24 -p tcp --dport 53 -j REDIRECT --to-ports 1053' "$MOCK_LOG"
assert_grep 'iptables -t nat -A PREROUTING -s 192.168.31.0/24 -p udp --dport 53 -j REDIRECT --to-ports 1053' "$MOCK_LOG"

"$PROJECT_DIR/bin/mihomo-router" firewall-up
"$PROJECT_DIR/bin/mihomo-router" firewall-down

MOCK_CURL_SOURCE=$PROJECT_DIR/test/fixtures/subscription.yaml
MOCK_CURL_FAIL=0
MOCK_EXPECT_USER_AGENT=clash.meta
export MOCK_CURL_SOURCE MOCK_CURL_FAIL MOCK_EXPECT_USER_AGENT
"$PROJECT_DIR/bin/mihomo-router" update
assert_grep '^    listen: 0.0.0.0:1053$' "$TEST_ROOT/data/config.yaml"

old_sum=$(cksum "$TEST_ROOT/data/config.yaml")
MOCK_CURL_FAIL=1
export MOCK_CURL_FAIL
if "$PROJECT_DIR/bin/mihomo-router" update >/dev/null 2>&1; then
	fail "failed subscription update unexpectedly succeeded"
fi
[ "$old_sum" = "$(cksum "$TEST_ROOT/data/config.yaml")" ] || fail "failed update changed active config"

MOCK_CURL_FAIL=0
MOCK_CURL_SOURCE=$TEST_ROOT/invalid.yaml
export MOCK_CURL_FAIL MOCK_CURL_SOURCE
printf '%s\n' 'invalid: true' >"$TEST_ROOT/invalid.yaml"
if "$PROJECT_DIR/bin/mihomo-router" update >/dev/null 2>&1; then
	fail "invalid config unexpectedly activated"
fi
[ "$old_sum" = "$(cksum "$TEST_ROOT/data/config.yaml")" ] || fail "invalid update changed active config"

MOCK_CURL_SOURCE=$PROJECT_DIR/test/fixtures/subscription.yaml
export MOCK_CURL_SOURCE
"$PROJECT_DIR/bin/mihomo-router" start
"$PROJECT_DIR/bin/mihomo-router" status >/dev/null
"$PROJECT_DIR/bin/mihomo-router" stop
if "$PROJECT_DIR/bin/mihomo-router" status >/dev/null 2>&1; then
	fail "service still reports running after stop"
fi

rm -f "$TEST_ROOT/run/mihomo"
printf '%s\n' "CORE_ARCHIVE=$TEST_ROOT/missing.gz" "CORE_URL=https://example.invalid/mihomo.gz" "CORE_TLS_INSECURE=1" "CORE_SHA256=" >>"$CONFIG"
if "$PROJECT_DIR/bin/mihomo-router" validate "$TEST_ROOT/data/config.yaml" >/dev/null 2>&1; then
	fail "insecure core download without SHA-256 unexpectedly allowed"
fi

sed -i.bak "s|^CORE_ARCHIVE=.*|CORE_ARCHIVE=$TEST_ROOT/data/mihomo.tar.gz|; /^CORE_URL=/d; /^CORE_TLS_INSECURE=/d; /^CORE_SHA256=/d" "$CONFIG"
rm -f "$TEST_ROOT/run/mihomo"
"$PROJECT_DIR/bin/mihomo-router" validate "$TEST_ROOT/data/config.yaml" >/dev/null
[ -x "$TEST_ROOT/run/mihomo" ] || fail "tar.gz core archive was not unpacked"

printf 'PASS: render preserves subscription DNS and binds the managed LAN resolver\n'
printf 'PASS: installer targets writable OpenWrt partitions\n'
printf 'PASS: installer accepts and protects a subscription URL argument\n'
printf 'PASS: ShellCrash subscription migration keeps the token off the command line\n'
printf 'PASS: firewall provides TCP/UDP transparency with managed LAN DNS interception\n'
printf 'PASS: firewall operations are repeatable\n'
printf 'PASS: subscription updates are normalized and validated\n'
printf 'PASS: subscription requests identify as a Clash Meta client\n'
printf 'PASS: failed and invalid updates roll back atomically\n'
printf 'PASS: managed start/status/stop lifecycle works\n'
printf 'PASS: insecure core download requires a pinned SHA-256\n'
printf 'PASS: ShellCrash-style tar.gz core archives are supported\n'
