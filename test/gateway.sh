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
EOF
"$controller" render "$fixture" "$render"
has '^  mr-ssh-gateways:$' "$render"
has '^  - name: SSH-Gateway$' "$render"
has '^    disable-udp: true$' "$render"
has '^  store-selected: true$' "$render"
has '^  - IP-CIDR,10.42.0.0/16,SSH-Gateway,no-resolve$' "$render"
has '^  - DOMAIN-SUFFIX,internal.example,SSH-Gateway$' "$render"
has "'+.internal.example': 'tcp://10.42.0.53:53#SSH-Gateway'" "$render"
has "^secret: 'fixture-token'$" "$render"
has '^  - name: PROXY$' "$render"
has '^  - MATCH,PROXY$' "$render"
has "path: '$inventory'" "$render"
awk '/DOMAIN-SUFFIX,internal.example/ {a=NR} /MATCH,PROXY/ {b=NR} END {exit !(a && a<b)}' "$render" || fail 'gateway routing priority'

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
[ -r "$stage/data/mihomo-router/share/ssh-gateway.sh" ] || fail 'gateway helper not installed'
[ -r "$stage/data/mihomo-router/share/ssh-gateway-overlay.awk" ] || fail 'gateway overlay not installed'
[ -r "$stage/data/mihomo-router/share/ssh-gateways.yaml.example" ] || fail 'gateway device example not installed'
printf '%s\n' 'PASS: SSH gateway overlay, switching, private targets and failure preservation'
