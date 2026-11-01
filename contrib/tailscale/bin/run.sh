#!/bin/sh

set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
RUN=/tmp/tailscale-wol
DATA=/data/tailscale-wol
umask 077

mkdir -p "$RUN" "$DATA/state"
chmod 700 "$DATA/state"
exec 9>"$RUN/daemon.lock"
flock -n 9 || exit 1
rm -f "$RUN/log.pipe"
mkfifo "$RUN/log.pipe"
awk -v logfile="$RUN/tailscaled.log" '
BEGIN { size=0 }
{
	lower=tolower($0)
	if (lower ~ /key|token|authurl|loginurl|login\.tailscale|state.*content/) next
	if (size + length($0) > 131072) {
		close(logfile)
		printf "" > logfile
		close(logfile)
		size=0
	}
	print $0 >> logfile
	close(logfile)
	size += length($0) + 1
}' <"$RUN/log.pipe" 9>&- &
logger_pid=$!
daemon_pid=
cleanup() {
	trap - 0 INT TERM HUP
	if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || :; fi
	kill "$logger_pid" 2>/dev/null || :
	rm -f "$RUN/daemon.pid" "$RUN/log.pipe"
}
trap cleanup 0
trap 'exit 0' INT TERM HUP
GOMEMLIMIT=32MiB GOGC=50 TS_NO_LOGS_NO_SUPPORT=true TS_LOGS_DIR="$RUN" \
	"$RUN/tailscaled" --tun=userspace-networking --no-logs-no-support \
	--statedir="$DATA/state" --state="$DATA/state/tailscaled.state" \
	--socket="$RUN/tailscaled.sock" --port=0 >"$RUN/log.pipe" 2>&1 9>&- &
daemon_pid=$!
printf '%s\n' "$daemon_pid" >"$RUN/daemon.pid"
set +e
wait "$daemon_pid"
result=$?
set -e
exit "$result"
