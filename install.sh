#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
DEST_ROOT=/
SUBSCRIPTION_ARG=
START_AFTER_INSTALL=0

usage() {
	printf '%s\n' "usage: $0 [--root DIR] [--subscription-url URL] [--start]"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--root)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			DEST_ROOT=$2
			shift 2
			;;
		--subscription-url)
			[ "$#" -ge 2 ] || { usage >&2; exit 2; }
			SUBSCRIPTION_ARG=$2
			shift 2
			;;
		--start) START_AFTER_INSTALL=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--*) usage >&2; exit 2 ;;
		*)
			# Backward-compatible shorthand used by offline/test installs.
			DEST_ROOT=$1
			shift
			;;
	esac
done

case "$SUBSCRIPTION_ARG" in *"'"*) printf '%s\n' 'Subscription URL cannot contain a single quote.' >&2; exit 2 ;; esac

install_dir() {
	[ -d "$1" ] || mkdir -p "$1"
}


# The manager is a shell script; do not overwrite it while it is executing.
if [ "$DEST_ROOT" = / ] && [ -x /data/mihomo-router/bin/mihomo-router ] && /data/mihomo-router/bin/mihomo-router status >/dev/null 2>&1; then
	if [ -x /etc/init.d/mihomo-router ]; then
		/etc/init.d/mihomo-router stop
	fi
	/data/mihomo-router/bin/mihomo-router stop
fi

install_dir "$DEST_ROOT/etc/init.d"
install_dir "$DEST_ROOT/data/mihomo-router/bin"
install_dir "$DEST_ROOT/data/mihomo-router/share"

cp "$SCRIPT_DIR/share/domestic-overlay.awk" "$DEST_ROOT/data/mihomo-router/share/domestic-overlay.awk"
cp "$SCRIPT_DIR/bin/mihomo-router" "$DEST_ROOT/data/mihomo-router/bin/mihomo-router"
cp "$SCRIPT_DIR/openwrt/mihomo-router.init" "$DEST_ROOT/data/mihomo-router/share/mihomo-router.init"
cp "$SCRIPT_DIR/bin/mihomo-router-boot" "$DEST_ROOT/data/mihomo-router/bin/mihomo-router-boot"
cp "$SCRIPT_DIR/bin/mihomo-router-boot-include" "$DEST_ROOT/data/mihomo-router/bin/mihomo-router-boot-include"
cp "$SCRIPT_DIR/etc/mihomo-router.conf.example" "$DEST_ROOT/data/mihomo-router/share/mihomo-router.conf.example"
chmod 755 "$DEST_ROOT/data/mihomo-router/bin/mihomo-router" \
	"$DEST_ROOT/data/mihomo-router/bin/mihomo-router-boot" \
	"$DEST_ROOT/data/mihomo-router/bin/mihomo-router-boot-include" \
	"$DEST_ROOT/data/mihomo-router/share/mihomo-router.init"
MIHOMO_ROUTER_ROOT=${DEST_ROOT%/} "$DEST_ROOT/data/mihomo-router/bin/mihomo-router-boot" setup

if [ -n "$SUBSCRIPTION_ARG" ]; then
	config_file=$DEST_ROOT/data/mihomo-router/router.conf
	config_tmp=$config_file.new
	awk -v url="$SUBSCRIPTION_ARG" '
		/^SUBSCRIPTION_URL=/ { print "SUBSCRIPTION_URL=\047" url "\047"; found=1; next }
		{ print }
		END { if (!found) print "SUBSCRIPTION_URL=\047" url "\047" }
	' "$config_file" >"$config_tmp"
	chmod 600 "$config_tmp"
	mv "$config_tmp" "$config_file"
fi

printf '%s\n' "Installed below $DEST_ROOT"
printf '%s\n' "Edit /data/mihomo-router/router.conf if needed, then run mihomo-router update and mihomo-router-boot start."
printf '%s\n' "Use mihomo-router-boot start to disable ShellCrash and enable persistent startup."

if [ "$START_AFTER_INSTALL" = 1 ]; then
	[ "$DEST_ROOT" = / ] || { printf '%s\n' '--start requires --root /.' >&2; exit 2; }
	[ -n "$SUBSCRIPTION_ARG" ] || { printf '%s\n' '--start requires --subscription-url.' >&2; exit 2; }
	/data/mihomo-router/bin/mihomo-router update
	/data/mihomo-router/bin/mihomo-router-boot restart
	printf '%s\n' 'mihomo-router is installed, enabled, and started.'
fi
