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

install_dir "$DEST_ROOT/etc/init.d"
install_dir "$DEST_ROOT/data/mihomo-router/bin"
install_dir "$DEST_ROOT/data/mihomo-router/share"

cp "$SCRIPT_DIR/bin/mihomo-router" "$DEST_ROOT/data/mihomo-router/bin/mihomo-router"
cp "$SCRIPT_DIR/openwrt/mihomo-router.init" "$DEST_ROOT/etc/init.d/mihomo-router"
cp "$SCRIPT_DIR/etc/mihomo-router.conf.example" "$DEST_ROOT/data/mihomo-router/share/mihomo-router.conf.example"
chmod 755 "$DEST_ROOT/data/mihomo-router/bin/mihomo-router" "$DEST_ROOT/etc/init.d/mihomo-router"

if [ ! -e "$DEST_ROOT/etc/mihomo-router.conf" ]; then
	cp "$SCRIPT_DIR/etc/mihomo-router.conf.example" "$DEST_ROOT/etc/mihomo-router.conf"
	chmod 600 "$DEST_ROOT/etc/mihomo-router.conf"
fi

if [ -n "$SUBSCRIPTION_ARG" ]; then
	config_file=$DEST_ROOT/etc/mihomo-router.conf
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
printf '%s\n' "Edit /etc/mihomo-router.conf if needed, then run mihomo-router update and mihomo-router start."
printf '%s\n' "Do not enable this service until ShellCrash has been stopped and disabled."

if [ "$START_AFTER_INSTALL" = 1 ]; then
	[ "$DEST_ROOT" = / ] || { printf '%s\n' '--start requires --root /.' >&2; exit 2; }
	[ -n "$SUBSCRIPTION_ARG" ] || { printf '%s\n' '--start requires --subscription-url.' >&2; exit 2; }
	if [ -x /etc/init.d/shellcrash ] && /etc/init.d/shellcrash status >/dev/null 2>&1; then
		printf '%s\n' 'ShellCrash is running; stop and disable it before using --start.' >&2
		exit 1
	fi
	/data/mihomo-router/bin/mihomo-router update
	/etc/init.d/mihomo-router enable
	/etc/init.d/mihomo-router restart
	printf '%s\n' 'mihomo-router is installed, enabled, and started.'
fi
