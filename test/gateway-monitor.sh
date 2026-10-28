#!/bin/sh
# Exercise the monitor's real state machine with URL-specific health verdicts.
# Requires OpenWrt jsonfilter; no network, firewall or production config access.
set -eu
PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mr-monitor-test.XXXXXX")
dummy=
trap 'if [ -n "$dummy" ]; then command kill "$dummy" 2>/dev/null || :; fi; rm -rf "$tmp"' 0
trap 'exit 1' INT TERM
RUN_DIR=$tmp/run; mkdir "$RUN_DIR"
DATA_DIR=$tmp
CONTROLLER_SECRET=fixture-token
CURL=curl
# shellcheck source=share/ssh-gateway.sh
. "$PROJECT_DIR/share/ssh-gateway.sh"
SSH_GATEWAY_HEALTH_URL=http://health.internal/
SSH_GATEWAY_HEALTH_TIMEOUT=3000
SSH_GATEWAY_HEALTH_THRESHOLD=2
SSH_GATEWAY_HEALTH_INTERVAL=60
SSH_GATEWAY_API_SECRET=fixture-token
log() { :; }
ensure_dirs() { mkdir -p "$RUN_DIR"; }
printf '0\n' >"$tmp/step"
# Simulate restoration of a previously healthy cached route on startup.
printf 'SSH-Gateway\n' >"$tmp/route"
: >"$tmp/transitions"
command sleep 30 & dummy=$!
gateway_request() {
    path=$1; shift
    output=; body=
    while [ "$#" -gt 0 ]; do
        case "$1" in -o) shift; output=$1 ;; --data) shift; body=$1 ;; esac
        shift
    done
    step=$(cat "$tmp/step")
    case "$path" in
        /proxies/SSH-Gateway-Route)
            if [ -n "$body" ]; then
                target=$(printf '%s' "$body" | "$JSONFILTER" -e '@.name')
                printf '%s\n' "$target" >"$tmp/route"
                printf '%s:%s\n' "$step" "$target" >>"$tmp/transitions"
            else printf '{"now":"%s"}\n' "$(cat "$tmp/route")" >"$output"; fi
            ;;
        /proxies/SSH-Gateway/delay) : ;; # HTTP 200 even when status mismatches.
        /proxies/SSH-Gateway)
            case "$step" in 0|1|3|7|8) alive=true ;; *) alive=false ;; esac
            printf '{"now":"phone-a","extra":{"http://health.internal/":{"alive":%s}}}\n' "$alive" >"$output"
            ;;
        *) echo "Unexpected path $path" >&2; return 1 ;;
    esac
}
sleep() {
    step=$(cat "$tmp/step"); step=$((step+1)); printf '%s\n' "$step" >"$tmp/step"
    [ "$step" -lt 9 ] || command kill "$dummy"
}
(gateway_monitor "$dummy")
wait "$dummy" 2>/dev/null || :; dummy=
printf '0:DIRECT\n1:SSH-Gateway\n5:DIRECT\n8:SSH-Gateway\n' >"$tmp/expected"
cmp "$tmp/expected" "$tmp/transitions"
[ ! -e "$RUN_DIR/gateway-monitor.pid" ]
[ -z "$(find "$RUN_DIR" -type f -print)" ]
printf '%s\n' 'PASS: cached state reset, URL verdict, two-result hysteresis, recovery and monitor cleanup'
