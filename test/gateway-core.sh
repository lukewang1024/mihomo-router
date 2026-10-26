#!/bin/sh
# Optional real-core parser test. No service, sockets or firewall are started.
set -eu
PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
core=${MIHOMO_TEST_CORE:-}
[ -n "$core" ] && [ -x "$core" ] || { printf '%s\n' 'Set MIHOMO_TEST_CORE to a compatible Mihomo executable.' >&2; exit 2; }
command -v ssh-keygen >/dev/null 2>&1 || { printf '%s\n' 'ssh-keygen is required.' >&2; exit 2; }
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-gateway-core.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
umask 077
mkdir -p "$TEST_ROOT/data/gateways" "$TEST_ROOT/run"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/key"
public_key=$(cat "$TEST_ROOT/key.pub")
cat >"$TEST_ROOT/data/gateways/proxies.yaml" <<EOF
proxies:
  - name: phone-a
    type: ssh
    server: 192.0.2.10
    port: 8022
    username: test-user
    private-key: '$TEST_ROOT/key'
    host-key:
      - '$public_key'
  - name: laptop-b
    type: ssh
    server: 192.0.2.11
    port: 22
    username: test-user
    private-key: '$TEST_ROOT/key'
    host-key:
      - '$public_key'
EOF
cat >"$TEST_ROOT/router.conf" <<EOF
DATA_DIR=$TEST_ROOT/data
RUN_DIR=$TEST_ROOT/run
SSH_GATEWAY_ENABLED=1
SSH_GATEWAY_CIDRS="10.42.0.0/16"
SSH_GATEWAY_DOMAINS="internal.example"
SSH_GATEWAY_DNS=tcp://10.42.0.53:53
SSH_GATEWAY_API_SECRET=fixture-token
EOF
# Explicit bootstrap DNS and valid unrelated policy/profile verify preservation.
awk '{print} /^dns:/ {print "  nameserver: [1.1.1.1]"}' "$PROJECT_DIR/test/fixtures/subscription.yaml" >"$TEST_ROOT/input.yaml"
printf '%s\n' 'profile:' '  store-selected: false' '  store-fake-ip: true' >>"$TEST_ROOT/input.yaml"
MIHOMO_ROUTER_CONFIG=$TEST_ROOT/router.conf "$PROJECT_DIR/bin/mihomo-router" render "$TEST_ROOT/input.yaml" "$TEST_ROOT/config.yaml"
SAFE_PATHS=$TEST_ROOT "$core" -t -d "$TEST_ROOT/run" -f "$TEST_ROOT/config.yaml"
grep -q '^  store-fake-ip: true$' "$TEST_ROOT/config.yaml"
printf '%s\n' 'PASS: real Mihomo parsed SSH devices, DNS detour and selector configuration'
