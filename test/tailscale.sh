#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-tailscale.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' 0
trap 'exit 1' INT TERM HUP
RUN=$TEST_ROOT
# Used by the extracted production functions below.
# shellcheck disable=SC2034
SOCKET=$TEST_ROOT/socket
export MOCK_BUILD MOCK_ROUTES
cat >"$RUN/tailscale" <<'MOCK'
#!/bin/sh
case "$*" in
    *'debug go-buildinfo'*) printf '%s\n' "$MOCK_BUILD" ;;
    *'debug prefs'*) printf '%s\n' "$MOCK_ROUTES" ;;
    *) exit 1 ;;
esac
MOCK
chmod 755 "$RUN/tailscale"
sed -n '/^verify_exit_support() {/,/^}/p' "$PROJECT_DIR/contrib/tailscale/tailscale-control.sh" >"$TEST_ROOT/functions"
sed -n '/^advertises_exit_routes() {/,/^}/p' "$PROJECT_DIR/contrib/tailscale/tailscale-control.sh" >>"$TEST_ROOT/functions"
# shellcheck disable=SC1091
. "$TEST_ROOT/functions"
MOCK_BUILD='{"Settings":[{"Key":"-tags","Value":"ts_include_cli,ts_omit_ssh"}]}'
MOCK_ROUTES='{"AdvertiseRoutes": [
  "0.0.0.0/0",
  "::/0"
]}'
verify_exit_support
advertises_exit_routes
MOCK_BUILD='{"Settings":[{"Key":"-tags","Value":"ts_include_cli,ts_omit_advertiseroutes"}]}'
if verify_exit_support 2>/dev/null; then printf '%s\n' 'route-less build incorrectly accepted' >&2; exit 1; fi
MOCK_BUILD='{"Settings":[{"Key":"-tags","Value":"ts_include_cli,ts_omit_advertiseexitnode"}]}'
if verify_exit_support 2>/dev/null; then printf '%s\n' 'exit-less build incorrectly accepted' >&2; exit 1; fi
MOCK_ROUTES='{"AdvertiseRoutes": [
  "0.0.0.0/0"
]}'
if advertises_exit_routes; then printf '%s\n' 'incomplete exit routes incorrectly accepted' >&2; exit 1; fi
printf '%s\n' 'tailscale exit checks passed'
