#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-features.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
export MIHOMO_ROUTER_CONFIG="$TEST_ROOT/router.conf" MOCK_LOG="$TEST_ROOT/commands.log"
cat >"$MIHOMO_ROUTER_CONFIG" <<SETTINGS
DATA_DIR=$TEST_ROOT/data
RUN_DIR=$TEST_ROOT/run
AI_RULES_ENABLED=1
AI_GROUP=AI-Selected
AI_NODE_INCLUDE='JP|SG'
AI_NODE_EXCLUDE=HK
AI_DOMAINS='ai.example chat.example'
SNIFFER_ENABLED=1
PANEL_ALLOWED_CIDRS='192.168.31.0/24 192.168.19.0/24'
CONTROLLER_ADDRESS=192.168.31.1:19091
IPTABLES=$PROJECT_DIR/test/mocks/iptables
IP=$PROJECT_DIR/test/mocks/ip
SETTINGS
cat >"$TEST_ROOT/input" <<'YAML'
proxies:
  - {name: 'JP one', type: direct}
  - name: SG two
    type: direct
  - {name: 'JP HK excluded', type: direct}
proxy-groups:
  - name: PROXY
    type: select
    proxies: [DIRECT]
rules:
  - MATCH,PROXY
sniffer: {enable: false}
YAML
manager=$PROJECT_DIR/bin/mihomo-router
"$manager" render "$TEST_ROOT/input" "$TEST_ROOT/output"
grep -q -- "- 'JP one'" "$TEST_ROOT/output" || exit 1
grep -q -- "- 'SG two'" "$TEST_ROOT/output" || exit 1
[ "$(grep -c 'JP HK excluded' "$TEST_ROOT/output")" -eq 1 ]
grep -q "DOMAIN-SUFFIX,ai.example,AI-Selected" "$TEST_ROOT/output"
grep -q 'override-destination: true' "$TEST_ROOT/output"
awk '/DOMAIN-SUFFIX/ {a=NR} /MATCH,PROXY/ {b=NR} END {exit !(a<b)}' "$TEST_ROOT/output"
# Vendor subscriptions often indent sequences four spaces.
sed 's/^  /    /' "$TEST_ROOT/input" >"$TEST_ROOT/indented"
"$manager" render "$TEST_ROOT/indented" "$TEST_ROOT/output"
grep -q "^    - name: 'AI-Selected'" "$TEST_ROOT/output"
# Refuse collisions rather than silently replacing a subscription group.
sed 's/name: PROXY/name: AI-Selected/' "$TEST_ROOT/input" >"$TEST_ROOT/collision"
if "$manager" render "$TEST_ROOT/collision" "$TEST_ROOT/output" 2>/dev/null; then exit 1; fi
printf '%s\n' "AI_NODE_INCLUDE=NOT_FOUND" >>"$MIHOMO_ROUTER_CONFIG"
if "$manager" render "$TEST_ROOT/input" "$TEST_ROOT/output" 2>/dev/null; then exit 1; fi
printf '%s\n' 'AI_RULES_ENABLED=0' 'SNIFFER_ENABLED=preserve' >>"$MIHOMO_ROUTER_CONFIG"
"$manager" render "$TEST_ROOT/input" "$TEST_ROOT/output"
grep -q '^sniffer: {enable: false}' "$TEST_ROOT/output"
"$manager" firewall-up
# Dispatch only the configured port, require source AND interface, reject others.
grep -q 'MR_PANEL_INPUT -p tcp --dport 19091 -j MR_PANEL' "$MOCK_LOG"
grep -q 'MR_PANEL -i br-lan -s 192.168.19.0/24 -j ACCEPT' "$MOCK_LOG"
grep -q 'MR_PANEL -j REJECT' "$MOCK_LOG"
"$manager" firewall-down
grep -q 'filter -X MR_PANEL_INPUT' "$MOCK_LOG"
grep -q 'filter -X MR_PANEL' "$MOCK_LOG"
printf '%s\n' 'feature tests passed'
