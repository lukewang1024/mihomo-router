#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
DATA_DIR=/data/tailscale-wol
PAYLOAD_DIR=/data/userdisk/tailscale-wol/bin
ARCHIVE=tailscaled-1.104.1-ax3600-minimal-arm64.xz

die() {
	printf '%s\n' "tailscale install: ERROR: $*" >&2
	exit 1
}

install_file() {
	source_file=$1
	target_file=$2
	temporary_file=$target_file.new
	cp "$source_file" "$temporary_file"
	chmod 755 "$temporary_file"
	mv "$temporary_file" "$target_file"
}

[ -r "$SCRIPT_DIR/$ARCHIVE" ] || die "missing pinned Tailscale archive"
[ -r "$SCRIPT_DIR/$ARCHIVE.sha256" ] || die "missing archive checksum"
[ -r "$SCRIPT_DIR/tailscaled.sha256" ] || die "missing binary checksum"
[ -d /data/userdisk ] || die "/data/userdisk is required for the compressed binary"
command -v openssl >/dev/null 2>&1 || die "openssl is required for checksum verification"
command -v xz >/dev/null 2>&1 || die "xz is required to unpack Tailscale"
command -v uci >/dev/null 2>&1 || die "uci is required for persistent Xiaomi startup"

archive_actual=$(openssl dgst -sha256 "$SCRIPT_DIR/$ARCHIVE" | awk '{print $NF}')
archive_expected=$(awk 'NR == 1 { print $1 }' "$SCRIPT_DIR/$ARCHIVE.sha256")
[ "$archive_actual" = "$archive_expected" ] || die "archive checksum mismatch"

binary_expected=$(awk 'NR == 1 { print $1 }' "$SCRIPT_DIR/tailscaled.sha256")
existing_archive=$DATA_DIR/bin/tailscaled.xz
if [ -r "$existing_archive" ]; then
	existing_archive_actual=$(openssl dgst -sha256 "$existing_archive" | awk '{print $NF}')
	if [ "$existing_archive_actual" = "$archive_expected" ]; then
		# Reuse a valid installed payload when the router lacks spare flash space.
		PAYLOAD_DIR=$DATA_DIR/bin
	fi
fi

mkdir -p "$DATA_DIR/bin" "$DATA_DIR/share" "$DATA_DIR/state" "$PAYLOAD_DIR"
chmod 700 "$DATA_DIR/state" "$PAYLOAD_DIR"

archive_tmp=$PAYLOAD_DIR/tailscaled.xz.new
cleanup() {
	rm -f "$archive_tmp"
}
trap cleanup 0
archive_current=$PAYLOAD_DIR/tailscaled.xz
replace_archive=1
if [ -r "$archive_current" ]; then
	archive_actual=$(openssl dgst -sha256 "$archive_current" | awk '{print $NF}')
	if [ "$archive_actual" = "$archive_expected" ]; then
		replace_archive=0
	fi
fi
if [ "$replace_archive" = 1 ]; then
	cp "$SCRIPT_DIR/$ARCHIVE" "$archive_tmp"
	archive_actual=$(openssl dgst -sha256 "$archive_tmp" | awk '{print $NF}')
	[ "$archive_actual" = "$archive_expected" ] || die "copied archive checksum mismatch"
	binary_actual=$(xz -dc "$archive_tmp" | openssl dgst -sha256 | awk '{print $NF}')
	[ "$binary_actual" = "$binary_expected" ] || die "uncompressed binary checksum mismatch"
	mv "$archive_tmp" "$archive_current"
fi
cp "$SCRIPT_DIR/tailscaled.sha256" "$DATA_DIR/bin/tailscaled.sha256.new"
chmod 644 "$DATA_DIR/bin/tailscaled.sha256.new"
mv "$DATA_DIR/bin/tailscaled.sha256.new" "$DATA_DIR/bin/tailscaled.sha256"
if [ "$PAYLOAD_DIR/tailscaled.xz" != "$DATA_DIR/bin/tailscaled.xz" ]; then
	ln -sfn "$PAYLOAD_DIR/tailscaled.xz" "$DATA_DIR/bin/tailscaled.xz"
fi

install_file "$SCRIPT_DIR/tailscale-control.sh" "$DATA_DIR/tailscale-control.sh"
install_file "$SCRIPT_DIR/bin/boot-run.sh" "$DATA_DIR/bin/boot-run.sh"
install_file "$SCRIPT_DIR/bin/run.sh" "$DATA_DIR/bin/run.sh"
install_file "$SCRIPT_DIR/bin/boot-include" "$DATA_DIR/bin/boot-include"
install_file "$SCRIPT_DIR/openwrt/tailscale-wol.init" "$DATA_DIR/share/tailscale-wol.init"
install_file "$DATA_DIR/share/tailscale-wol.init" /etc/init.d/tailscale-wol

uci set firewall.tailscale_wol=include
uci set firewall.tailscale_wol.type=script
uci set firewall.tailscale_wol.path=/data/tailscale-wol/bin/boot-include
uci set firewall.tailscale_wol.enabled=1
uci set firewall.tailscale_wol.reload=1
uci commit firewall
/etc/init.d/tailscale-wol enable

if "$DATA_DIR/tailscale-control.sh" is-running; then
	printf '%s\n' 'Existing Tailscale daemon left running.'
else
	/etc/init.d/tailscale-wol start
	"$DATA_DIR/tailscale-control.sh" status >/dev/null
fi

printf '%s\n' 'Tailscale client installed and startup enabled.'
printf '%s\n' 'Device registration was not started.'
printf '%s\n' 'Run /data/tailscale-wol/tailscale-control.sh register when ready to authenticate.'
