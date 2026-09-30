#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/mihomo-router-boot-test.$$
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
mkdir -p "$TEST_ROOT/etc/init.d" "$TEST_ROOT/etc/crontabs" "$TEST_ROOT/data/other_vol/ShellCrash" "$TEST_ROOT/data/custom-crash"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Upgrade an existing router, preserving all settings and the subscription.
printf '%s\n' "SUBSCRIPTION_URL='https://fixture.invalid/private'" 'LAN_CIDRS="192.168.0.0/24"' >"$TEST_ROOT/etc/mihomo-router.conf"
printf '%s\n' '#!/bin/sh' '/bin/sh /data/mihomo-router/bin/boot-include' '/usr/bin/unrelated-startup' >"$TEST_ROOT/data/auto_start.sh"
"$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null
grep -q unrelated-startup "$TEST_ROOT/data/auto_start.sh" || fail 'unrelated startup removed'
if grep -q /data/mihomo-router/bin/boot-include "$TEST_ROOT/data/auto_start.sh"; then
	fail 'obsolete recovery hook retained'
fi
[ -L "$TEST_ROOT/etc/mihomo-router.conf" ] || fail 'config alias missing'
[ -L "$TEST_ROOT/etc/init.d/mihomo-router" ] || fail 'init alias missing'
grep -q '192.168.0.0/24' "$TEST_ROOT/data/mihomo-router/router.conf" || fail 'upgrade lost router settings'
# Atomic subscription writes must update persistent config, keeping the alias.
printf "%s\n" "Url='https://fixture.invalid/changed'" >"$TEST_ROOT/migration.cfg"
MIHOMO_ROUTER_CONFIG=$TEST_ROOT/etc/mihomo-router.conf "$TEST_ROOT/data/mihomo-router/bin/mihomo-router" migrate-shellcrash "$TEST_ROOT/migration.cfg" >/dev/null
[ -L "$TEST_ROOT/etc/mihomo-router.conf" ] || fail 'atomic write replaced alias'
grep -q 'fixture.invalid/changed' "$TEST_ROOT/data/mihomo-router/router.conf" || fail 'atomic write missed persistent config'
# A firmware reboot discards /etc. Reconstruct using only persistent files.
rm "$TEST_ROOT/etc/mihomo-router.conf" "$TEST_ROOT/etc/init.d/mihomo-router"
MIHOMO_ROUTER_ROOT=$TEST_ROOT "$TEST_ROOT/data/mihomo-router/bin/mihomo-router-boot" setup
[ -x "$TEST_ROOT/etc/init.d/mihomo-router" ] || fail 'reboot did not reconstruct init'
grep -q 'fixture.invalid/changed' "$TEST_ROOT/etc/mihomo-router.conf" || fail 'reboot lost subscription'
"$PROJECT_DIR/install.sh" --root "$TEST_ROOT" >/dev/null
"$PROJECT_DIR/install.sh" --root "$TEST_ROOT" --subscription-url https://fixture.invalid/latest >/dev/null
[ -L "$TEST_ROOT/etc/mihomo-router.conf" ] || fail 'installer replaced alias'
grep -q 'fixture.invalid/latest' "$TEST_ROOT/data/mihomo-router/router.conf" || fail 'installer did not persist new subscription'
# Exercise the legacy init service, both known watchdog formats, and custom layout.
cat >"$TEST_ROOT/etc/init.d/shellcrash" <<EOF_INIT
#!/bin/sh
printf '%s\\n' "\$1" >>'$TEST_ROOT/shellcrash-actions'
EOF_INIT
chmod 755 "$TEST_ROOT/etc/init.d/shellcrash"
printf '%s\n' 'CRASHDIR="/data/custom-crash"' >"$TEST_ROOT/data/shellcrash_init.sh"
cat >"$TEST_ROOT/etc/crontabs/root" <<'EOF_CRON'
* * * * * /data/other_vol/ShellCrash/task.sh 103
* * * * * /data/other_vol/ShellCrash/start_legacy_wd.sh shellcrash
0 2 * * * /usr/bin/unrelated-backup
EOF_CRON
MIHOMO_ROUTER_ROOT=$TEST_ROOT "$TEST_ROOT/data/mihomo-router/bin/mihomo-router-boot" disable-shellcrash
[ -f "$TEST_ROOT/data/other_vol/ShellCrash/.dis_startup" ] || fail 'legacy boot not disabled'
[ -f "$TEST_ROOT/data/custom-crash/.dis_startup" ] || fail 'custom legacy boot not disabled'
grep -q '^disable$' "$TEST_ROOT/shellcrash-actions" || fail 'legacy init not disabled'
grep -q '^stop$' "$TEST_ROOT/shellcrash-actions" || fail 'legacy init not stopped'
[ "$(wc -l <"$TEST_ROOT/etc/crontabs/root" | tr -d ' ')" = 1 ] || fail 'watchdogs survived or unrelated cron removed'
grep -q unrelated-backup "$TEST_ROOT/etc/crontabs/root" || fail 'unrelated cron removed'
MIHOMO_ROUTER_ROOT=$TEST_ROOT "$TEST_ROOT/data/mihomo-router/bin/mihomo-router-boot" disable-shellcrash
# A failure to stop legacy service must be reported, not silently ignored.
# The dollar is literal in the generated mock.
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$1" != stop ]\n' >"$TEST_ROOT/etc/init.d/shellcrash"
if MIHOMO_ROUTER_ROOT=$TEST_ROOT "$TEST_ROOT/data/mihomo-router/bin/mihomo-router-boot" disable-shellcrash; then
	fail 'legacy stop failure was ignored'
fi
printf 'PASS: upgrades preserve settings and atomic writes retain the persistent alias\n'
printf 'PASS: boot reconstructs volatile config and init files\n'
printf 'PASS: ShellCrash boot and watchdogs are disabled without removing unrelated cron\n'
printf 'PASS: legacy stop failure blocks activation\n'
