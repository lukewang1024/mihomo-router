#!/bin/sh

set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
TS_DISABLE_PORTMAPPER=true
export TS_DISABLE_PORTMAPPER
umask 077

RUN=/tmp/tailscale-wol
DATA=/data/tailscale-wol

mkdir -p "$RUN"
if [ ! -x "$RUN/tailscaled" ]; then
	free_kb=$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)
	if [ -z "$free_kb" ]; then free_kb=0; fi
	[ "$free_kb" -ge 70000 ] || exit 1
	xz -dc "$DATA/bin/tailscaled.xz" >"$RUN/tailscaled.new"
	actual=$(openssl dgst -sha256 "$RUN/tailscaled.new" | awk '{print $NF}')
	expected=$(awk 'NR == 1 { print $1 }' "$DATA/bin/tailscaled.sha256")
	[ "$actual" = "$expected" ] || { rm -f "$RUN/tailscaled.new"; exit 1; }
	chmod 700 "$RUN/tailscaled.new"
	mv "$RUN/tailscaled.new" "$RUN/tailscaled"
fi
[ -e "$RUN/tailscale" ] || ln -s tailscaled "$RUN/tailscale"
exec "$DATA/bin/run.sh"
