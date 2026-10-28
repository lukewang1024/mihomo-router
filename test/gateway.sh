#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-gateway.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
mkdir -p "$TEST_ROOT/data" "$TEST_ROOT/run"
export MOCK_LOG="$TEST_ROOT/commands.log"
export MIHOMO_ROUTER_CONFIG="$TEST_ROOT/router.conf"
cat >"$MIHOMO_ROUTER_CONFIG" <<EOF
DATA_DIR=$TEST_ROOT/data
RUN_DIR=$TEST_ROOT/run
CORE_SOURCE=$PROJECT_DIR/test/mocks/mihomo
SUBSCRIPTION_URL=file://$PROJECT_DIR/test/fixtures/subscription.yaml
LAN_CIDRS="192.168.31.0/24"
BYPASS_CIDRS="10.0.0.0/8 192.168.0.0/16"
CN_RULES_ENABLED=0
SSH_GATEWAY_ENABLED=0
IPTABLES=$PROJECT_DIR/test/mocks/iptables
IP=$PROJECT_DIR/test/mocks/ip
CURL=$PROJECT_DIR/test/mocks/curl
EOF
controller=$PROJECT_DIR/bin/mihomo-router
fixture=$PROJECT_DIR/test/fixtures/subscription.yaml
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
has() { grep -q "$1" "$2" || fail "missing $1"; }
render=$TEST_ROOT/result.yaml
"$controller" render "$fixture" "$render"
if grep -q SSH-Gateway "$render"; then fail 'disabled gateway changed subscription'; fi
"$controller" gateway init >/dev/null
inventory=$TEST_ROOT/data/gateways/proxies.yaml
[ -f "$inventory" ] || fail 'inventory not created'
cp "$PROJECT_DIR/etc/ssh-gateways.yaml.example" "$inventory"
inventory_sum=$(cksum "$inventory")
"$controller" gateway init >/dev/null
[ "$inventory_sum" = "$(cksum "$inventory")" ] || fail 'init overwrote device inventory'
cat >>"$MIHOMO_ROUTER_CONFIG" <<EOF
SSH_GATEWAY_ENABLED=1
SSH_GATEWAY_CIDRS="10.42.0.0/16"
SSH_GATEWAY_DOMAINS="internal.example"
SSH_GATEWAY_DNS=tcp://10.42.0.53:53
SSH_GATEWAY_API_SECRET=fixture-token
DASHBOARD_DIR=$PROJECT_DIR/share/ui
MIHOMO_LOG_LEVEL=warning
EOF
"$controller" render "$fixture" "$render"
has '^  mr-ssh-gateways:$' "$render"
has '^  - name: SSH-Gateway$' "$render"
has '^    disable-udp: true$' "$render"
has '^  store-selected: true$' "$render"
has '^  - IP-CIDR,10.42.0.0/16,SSH-Gateway,no-resolve$' "$render"
has '^  - DOMAIN-SUFFIX,internal.example,SSH-Gateway$' "$render"
has "'+.internal.example': 'tcp://10.42.0.53:53#SSH-Gateway'" "$render"
cat >>"$MIHOMO_ROUTER_CONFIG" <<EOF
SSH_GATEWAY_FAILOVER=1
SSH_GATEWAY_HEALTH_URL=http://health.internal.example/
JSONFILTER=true
EOF
"$controller" render "$fixture" "$render"
has '^  - name: SSH-Gateway-Route$' "$render"
has 'proxies: \[DIRECT, SSH-Gateway\]' "$render"
has 'DOMAIN-SUFFIX,internal.example,SSH-Gateway-Route$' "$render"
has "tcp://10.42.0.53:53#SSH-Gateway-Route" "$render"
for setting in 'SSH_GATEWAY_HEALTH_INTERVAL=1' 'SSH_GATEWAY_HEALTH_TIMEOUT=30000' 'SSH_GATEWAY_HEALTH_THRESHOLD=02' 'SSH_GATEWAY_HEALTH_EXPECTED=399-200' 'SSH_GATEWAY_HEALTH_URL='; do
    cp "$MIHOMO_ROUTER_CONFIG" "$TEST_ROOT/good.conf"
    printf '%s\n' "$setting" >>"$MIHOMO_ROUTER_CONFIG"
    "$controller" render "$fixture" "$render" >/dev/null 2>&1 && fail "invalid health setting accepted: $setting"
    cp "$TEST_ROOT/good.conf" "$MIHOMO_ROUTER_CONFIG"
done
printf '%s\n' 'SSH_GATEWAY_FAILOVER=0' >>"$MIHOMO_ROUTER_CONFIG"
"$controller" render "$fixture" "$render"
has '^log-level: warning$' "$render"
has "^external-ui: '$PROJECT_DIR/share/ui'$" "$render"
has "^secret: 'fixture-token'$" "$render"
has '^  - name: PROXY$' "$render"
has '^  - MATCH,PROXY$' "$render"
has "path: '$inventory'" "$render"
awk '/DOMAIN-SUFFIX,internal.example/ {a=NR} /MATCH,PROXY/ {b=NR} END {exit !(a && a<b)}' "$render" || fail 'gateway routing priority'

# Dashboard authentication must survive disabling the gateway feature.
printf '%s\n' 'SSH_GATEWAY_ENABLED=0' 'CONTROLLER_SECRET=fixture-token' >>"$MIHOMO_ROUTER_CONFIG"
"$controller" render "$fixture" "$render"
has "^secret: 'fixture-token'$" "$render"
has "^external-ui: '$PROJECT_DIR/share/ui'$" "$render"
if grep -q SSH-Gateway "$render"; then fail 'disabled gateway selector retained'; fi
printf '%s\n' 'SSH_GATEWAY_ENABLED=1' >>"$MIHOMO_ROUTER_CONFIG"
# Local dashboard assets override stale subscription download instructions.
cp "$fixture" "$TEST_ROOT/old-ui.yaml"
printf '%s\n' 'external-ui: /old-ui' 'external-ui-url: https://example.invalid/ui.zip' 'external-ui-name: old' >>"$TEST_ROOT/old-ui.yaml"
"$controller" render "$TEST_ROOT/old-ui.yaml" "$render"
has "^external-ui: '$PROJECT_DIR/share/ui'$" "$render"
if grep -q '^external-ui-url:\|^external-ui-name:' "$render"; then fail 'stale dashboard override retained'; fi

# Overlays are recomposed from the original active subscription on each start.
export MOCK_CURL_SOURCE="$fixture" MOCK_CURL_FAIL=0
"$controller" update
active=$TEST_ROOT/data/config.yaml
if grep -q SSH-Gateway "$active"; then fail 'private overlay baked into subscription'; fi
active_sum=$(cksum "$active")
"$controller" gateway check
for malformed in inline collision; do
    case $malformed in
        inline) sed 's/^proxy-groups:/proxy-groups: [{name: other}]/' "$fixture" >"$TEST_ROOT/bad.yaml" ;;
        collision) sed 's/name: PROXY/name: SSH-Gateway/' "$fixture" >"$TEST_ROOT/bad.yaml" ;;
    esac
    MOCK_CURL_SOURCE=$TEST_ROOT/bad.yaml "$controller" update >/dev/null 2>&1 && fail 'bad overlay activated'
    [ "$active_sum" = "$(cksum "$active")" ] || fail 'failed overlay changed active subscription'
done

# Targeted all-port capture precedes broad private-IP/port bypasses, while local
# networks and marked core traffic return before remote target redirects.
: >"$MOCK_LOG"
"$controller" firewall-up
has 'nat -A MR_GATEWAY -m mark --mark 0x1ed6 -j RETURN' "$MOCK_LOG"
has 'nat -A MR_GATEWAY -d 192.168.31.0/24 -j RETURN' "$MOCK_LOG"
has 'nat -A MR_GATEWAY -s 192.168.31.0/24 -d 10.42.0.0/16 -p tcp -j REDIRECT --to-ports 7892' "$MOCK_LOG"
awk '/-A PREROUTING -p tcp -j MR_GATEWAY/ {a=NR} /-A PREROUTING -p tcp -m multiport/ {b=NR} END {exit !(a && a<b)}' "$MOCK_LOG" || fail 'private gateway bypass still wins'
"$controller" firewall-down
has 'nat -F MR_GATEWAY' "$MOCK_LOG"
has 'nat -X MR_GATEWAY' "$MOCK_LOG"
# A gateway endpoint must bypass every managed hook, not just private targets.
printf '%s\n' 'BYPASS_SOURCE_CIDRS="192.168.31.50/32 192.168.31.51/32"' >>"$MIHOMO_ROUTER_CONFIG"
: >"$MOCK_LOG"
"$controller" firewall-up
has 'nat -A MR_INGRESS -s 192.168.31.50/32 -j RETURN' "$MOCK_LOG"
has 'mangle -A MR_INGRESS -s 192.168.31.51/32 -j RETURN' "$MOCK_LOG"
has 'nat -A MR_INGRESS -s 192.168.31.0/24 -p udp --dport 53' "$MOCK_LOG"
has 'nat -A MR_INGRESS -s 192.168.31.0/24 -d 198.18.0.0/16 -p tcp' "$MOCK_LOG"
has 'mangle -A MR_INGRESS -s 192.168.31.0/24 -d 198.18.0.0/16 -p udp' "$MOCK_LOG"
has 'nat -A MR_INGRESS -p tcp -j MR_GATEWAY' "$MOCK_LOG"
if grep -q -- '-A PREROUTING -s 192.168.31.0/24' "$MOCK_LOG"; then fail 'managed rule escapes source exclusions'; fi
awk '/nat -A MR_INGRESS -s 192.168.31.50/ {a=NR} /nat -A MR_INGRESS .*--dport 53/ {b=NR} END {exit !(a && a<b)}' "$MOCK_LOG" || fail 'DNS precedes source bypass'
# Scoped mode retains public transparency and prevents gateway recursion.
printf '%s\n' 'BYPASS_SOURCE_MODE=gateway' >>"$MIHOMO_ROUTER_CONFIG"
: >"$MOCK_LOG"
"$controller" firewall-up
has 'nat -A MR_INGRESS -s 192.168.31.50/32 -p udp --dport 53 -j RETURN' "$MOCK_LOG"
has 'mangle -A MR_INGRESS -s 192.168.31.51/32 -d 10.42.0.0/16 -j RETURN' "$MOCK_LOG"
if grep -q -- '-s 192.168.31.50/32 -j RETURN' "$MOCK_LOG"; then fail 'scoped mode bypassed all endpoint traffic'; fi
"$controller" render "$fixture" "$render"
has 'AND,((SRC-IP-CIDR,192.168.31.50/32),(DOMAIN-SUFFIX,internal.example)),DIRECT' "$render"
has 'AND,((SRC-IP-CIDR,192.168.31.51/32),(IP-CIDR,10.42.0.0/16,no-resolve)),DIRECT' "$render"
awk '/AND,.*internal.example/ {a=NR} /DOMAIN-SUFFIX,internal.example,SSH-Gateway/ {b=NR} END {exit !(a && a<b)}' "$render" || fail 'source guard must precede gateway routes'
printf '%s\n' 'BYPASS_SOURCE_MODE=invalid' >>"$MIHOMO_ROUTER_CONFIG"
: >"$MOCK_LOG"
"$controller" firewall-up >/dev/null 2>&1 && fail 'invalid bypass mode accepted'
[ ! -s "$MOCK_LOG" ] || fail 'invalid mode changed firewall'
printf '%s\n' 'BYPASS_SOURCE_MODE=all' >>"$MIHOMO_ROUTER_CONFIG"
# Teardown works after exclusions are removed; vendor chains are never flushed.
printf '%s\n' 'BYPASS_SOURCE_CIDRS=""' >>"$MIHOMO_ROUTER_CONFIG"
"$controller" firewall-down
has 'nat -F MR_INGRESS' "$MOCK_LOG"
has 'mangle -X MR_INGRESS' "$MOCK_LOG"
printf '%s\n' 'BYPASS_SOURCE_CIDRS="192.168.31.999/32"' >>"$MIHOMO_ROUTER_CONFIG"
: >"$MOCK_LOG"
"$controller" firewall-up >/dev/null 2>&1 && fail 'invalid source exclusion accepted'
[ ! -s "$MOCK_LOG" ] || fail 'invalid source exclusion changed firewall'
printf '%s\n' 'BYPASS_SOURCE_CIDRS=""' >>"$MIHOMO_ROUTER_CONFIG"
printf '%s\n' 'SSH_GATEWAY_CIDRS="10.999.0.0/16"' >>"$MIHOMO_ROUTER_CONFIG"
: >"$MOCK_LOG"
"$controller" firewall-up >/dev/null 2>&1 && fail 'invalid CIDR accepted'
[ ! -s "$MOCK_LOG" ] || fail 'invalid settings changed firewall'
printf '%s\n' 'SSH_GATEWAY_CIDRS="10.42.0.0/16"' >>"$MIHOMO_ROUTER_CONFIG"

# Switching uses the core selector API, without editing nodes or restarting.
cat >"$TEST_ROOT/api-curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
while [ "$#" -gt 0 ]; do
    if [ "$1" = --config ]; then
        shift
        [ -f "$1" ] || exit 2
        grep -q 'Authorization: Bearer fixture-token' "$1" || exit 2
    fi
    shift
done
[ "${MOCK_API_FAIL:-0}" = 0 ] || exit 22
printf '%s' '{"now":"phone-a","all":["phone-a","laptop-b"]}'
EOF
chmod +x "$TEST_ROOT/api-curl"
printf 'CURL=%s\n' "$TEST_ROOT/api-curl" >>"$MIHOMO_ROUTER_CONFIG"
: >"$MOCK_LOG"
"$controller" gateway use laptop-b >/dev/null
has 'PUT.*{"name":"laptop-b"}.*http://127.0.0.1:19090/proxies/SSH-Gateway' "$MOCK_LOG"
if grep -q fixture-token "$MOCK_LOG"; then fail 'API secret leaked into arguments'; fi
"$controller" gateway status >"$TEST_ROOT/status"
has '"now":"phone-a"' "$TEST_ROOT/status"
"$controller" gateway use 'bad"name' >/dev/null 2>&1 && fail 'unsafe device name accepted'
MOCK_API_FAIL=1 "$controller" gateway use laptop-b >/dev/null 2>&1 && fail 'failed selection reported success'
[ "$inventory_sum" = "$(cksum "$inventory")" ] || fail 'switch changed inventory'
[ "$active_sum" = "$(cksum "$active")" ] || fail 'switch changed subscription'
if ls "$TEST_ROOT/run"/gateway-curl.* >/dev/null 2>&1; then fail 'temporary API credentials retained'; fi
# A client-side switch uses the private router command, no manual router shell.
cat >"$TEST_ROOT/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$MOCK_LOG"
EOF
chmod +x "$TEST_ROOT/ssh"
: >"$MOCK_LOG"
MIHOMO_ROUTER_SSH=$TEST_ROOT/ssh "$PROJECT_DIR/bin/mihomo-router-deploy" gateway --host home-router use laptop-b
has '^home-router$' "$MOCK_LOG"
has '^/data/mihomo-router/bin/mihomo-router gateway use laptop-b$' "$MOCK_LOG"
: >"$MOCK_LOG"
MIHOMO_ROUTER_SSH=$TEST_ROOT/ssh "$PROJECT_DIR/bin/mihomo-router-deploy" gateway --host home-router use 'name;invalid' >/dev/null 2>&1 && fail 'remote command injection accepted'
[ ! -s "$MOCK_LOG" ] || fail 'invalid selection reached SSH'

# Runtime upgrades install helpers but never replace private device inventory.
stage=$TEST_ROOT/stage
"$PROJECT_DIR/install.sh" --root "$stage" >/dev/null
mkdir -p "$stage/data/mihomo-router/gateways"
printf '%s\n' 'private inventory fixture' >"$stage/data/mihomo-router/gateways/proxies.yaml"
"$PROJECT_DIR/install.sh" --root "$stage" >/dev/null
has '^private inventory fixture$' "$stage/data/mihomo-router/gateways/proxies.yaml"
[ -r "$stage/data/mihomo-router/share/ui/index.html" ] || fail 'gateway dashboard not installed'
[ -r "$stage/data/mihomo-router/share/ssh-gateway.sh" ] || fail 'gateway helper not installed'
[ -r "$stage/data/mihomo-router/share/ssh-gateway-overlay.awk" ] || fail 'gateway overlay not installed'
[ -r "$stage/data/mihomo-router/share/ssh-gateways.yaml.example" ] || fail 'gateway device example not installed'
printf '%s\n' 'PASS: SSH gateway overlay, switching, private targets and failure preservation'
