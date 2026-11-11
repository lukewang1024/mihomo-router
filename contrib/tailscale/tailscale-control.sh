#!/bin/sh

set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
TS_DISABLE_PORTMAPPER=true
export TS_DISABLE_PORTMAPPER
umask 077

RUN=/tmp/tailscale-wol
SOCKET=$RUN/tailscaled.sock

is_running() {
	[ -r "$RUN/daemon.pid" ] || return 1
	pid=$(cat "$RUN/daemon.pid")
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	[ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$RUN/tailscaled" ] &&
		kill -0 "$pid" 2>/dev/null
}

start_service() {
	is_running && return 0
	/etc/init.d/tailscale-wol start
	count=0
	while [ "$count" -lt 15 ]; do
		if is_running && [ -S "$SOCKET" ]; then
			return 0
		fi
		count=$((count + 1))
		sleep 1
	done
	printf '%s\n' 'Tailscale did not start; inspect /tmp/tailscale-wol/tailscaled.log.' >&2
	return 1
}

backend_state() {
	"$RUN/tailscale" --socket="$SOCKET" status --json |
		sed -n 's/^[[:space:]]*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' |
		head -n 1
}

apply_tailscale_config() {
	advertise_exit_node=$1
	"$RUN/tailscale" --socket="$SOCKET" set \
		--accept-dns=false \
		--accept-routes=false \
		--ssh=false \
		--advertise-exit-node="$advertise_exit_node" || return $?
	"$RUN/tailscale" --socket="$SOCKET" up \
		--accept-dns=false \
		--accept-routes=false \
		--advertise-exit-node="$advertise_exit_node" \
		--ssh=false \
		--hostname=ax3600-wol \
		--netfilter-mode=off || return $?
}

connect_tailscale() {
	advertise_exit_node=$1
	"$RUN/tailscale" --socket="$SOCKET" up \
		--accept-dns=false \
		--accept-routes=false \
		--advertise-exit-node="$advertise_exit_node" \
		--ssh=false \
		--hostname=ax3600-wol \
		--netfilter-mode=off
}

enable_exit_node() {
	start_service
	: >/data/tailscale-wol/exit-node-enabled.new
	chmod 600 /data/tailscale-wol/exit-node-enabled.new
	if ! apply_tailscale_config true; then
		rm -f /data/tailscale-wol/exit-node-enabled.new
		apply_tailscale_config false || :
		return 1
	fi
	if ! mv /data/tailscale-wol/exit-node-enabled.new /data/tailscale-wol/exit-node-enabled; then
		apply_tailscale_config false || :
		return 1
	fi
	printf '%s\n' 'Userspace exit-node routes advertised (TCP/UDP). Approve this router in the Tailscale admin console if required.'
}

disable_exit_node() {
	start_service
	apply_tailscale_config false
	rm -f /data/tailscale-wol/exit-node-enabled
	printf '%s\n' 'Exit-node routes withdrawn; Tailscale connectivity remains enabled.'
}

action=
if [ "$#" -gt 0 ]; then
	action=$1
	shift
fi

case "$action" in
	start)
		start_service
		printf '%s\n' 'Tailscale daemon is running.'
		;;
	stop)
		if is_running; then
			kill "$pid"
			count=0
			while is_running && [ "$count" -lt 10 ]; do
				count=$((count + 1))
				sleep 1
			done
		fi
		printf '%s\n' 'Stop requested; persistent device identity retained.'
		;;
	status)
		is_running || { printf '%s\n' 'Stopped' >&2; exit 1; }
		printf 'Running PID %s\n' "$pid"
		"$RUN/tailscale" --socket="$SOCKET" status
		;;
	is-running)
		is_running
		;;
	register)
		start_service
		state=$(backend_state)
		if [ -f /data/tailscale-wol/exit-node-enabled ]; then
			advertise_exit_node=true
		else
			advertise_exit_node=false
		fi
		set +e
		if [ "$state" = Running ]; then
			apply_tailscale_config "$advertise_exit_node"
		else
			connect_tailscale "$advertise_exit_node"
		fi
		up_status=$?
		set -e
		state=$(backend_state)
		case "$state" in
			Running)
				"$RUN/tailscale" --socket="$SOCKET" serve \
					--bg --tcp=2222 tcp://127.0.0.1:22
				;;
			NeedsLogin|NeedsMachineAuth)
				printf '%s\n' 'Complete the sign-in shown above, then run register again to enable private SSH access.'
				;;
			*)
				if [ "$up_status" -ne 0 ]; then
					exit "$up_status"
				fi
				if [ -z "$state" ]; then state=unknown; fi
				printf '%s\n' "Tailscale backend state: $state"
				;;
		esac
		;;
	exit-node)
		case ${1:-} in
			enable) [ "$#" -eq 1 ] || exit 2; enable_exit_node ;;
			disable) [ "$#" -eq 1 ] || exit 2; disable_exit_node ;;
			*) printf '%s\n' 'usage: tailscale-control.sh exit-node enable|disable' >&2; exit 2 ;;
		esac
		;;
	cli)
		is_running || { printf '%s\n' 'Daemon is stopped' >&2; exit 1; }
		exec "$RUN/tailscale" --socket="$SOCKET" "$@"
		;;
	log)
		tail -n 50 "$RUN/tailscaled.log"
		;;
	*)
		printf '%s\n' 'usage: tailscale-control.sh start|stop|status|register|exit-node enable|disable|cli ARGS|log' >&2
		exit 2
		;;
esac
