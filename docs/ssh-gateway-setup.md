# Fixed SSH gateway setup

This guide describes the current recommended setup: the main LAN uses subscription proxy rules and a fixed SSH gateway for explicit internal targets; guests connect directly; gateway devices cannot route their own internal traffic back into themselves. An unavailable gateway causes connection failure. There is no automatic DIRECT fallback or periodic health monitor.

All networks, addresses, usernames and `internal.example` below are documentation examples. Replace them in your device-local configuration. Keep real internal domains, endpoint inventories, subscription URLs, tokens and private keys outside this repository. The setup does not depend on a particular remote-access client.

## Prerequisites and storage

Deploy the base proxy service using the [README installation instructions](../README.md), and verify public connectivity first. The SSH endpoint must allow TCP forwarding and already have access to the target network. The router borrows that endpoint's network access.

| Content | Router location |
| --- | --- |
| Persistent settings | `/data/mihomo-router/router.conf` |
| Private endpoint inventory | `/data/mihomo-router/gateways/proxies.yaml` |
| Dedicated SSH private key | `/data/mihomo-router/ssh/` |
| Rendered configuration, runtime logs and unpacked core | `/tmp/mihomo-router/` |
| Management page | `/ui/` on the controller address |

Use mode `600` for private settings and keys, and `700` for private directories. On small flash partitions, keep a compressed compatible core in persistent storage and unpack it into RAM at boot instead of downloading it on every startup. See [storage guidance](../README.md#storage-on-small-xiaomi-flash-partitions) for formats, checksums and space requirements.

## 1. Prepare the SSH endpoint

Reserve a stable address for every endpoint. For example, use `192.168.50.0/24` as the main LAN and `192.168.50.100` for one endpoint. The router must reach its SSH port directly.

Generate a dedicated Ed25519 key on the management machine. Securely transfer its private key to `/data/mihomo-router/ssh/gateway_ed25519` on the router, and install only its public key in the endpoint's `authorized_keys`. Do not reuse an administrator's everyday login key. Restrict authorization to the router address and forwarding, for example:

```text
restrict,port-forwarding,from="192.168.50.1",command="exit 1" ssh-ed25519 REPLACE_WITH_ROUTER_PUBLIC_KEY
```

The SSH server must allow TCP forwarding. Verify its host public key through a trusted channel rather than trusting an unauthenticated scan alone.

Initialize the inventory on the router:

```sh
export PATH=/data/mihomo-router/bin:$PATH
mihomo-router gateway init
```

Use the [inventory example](../etc/ssh-gateways.yaml.example) as a reference. Fill the local inventory with the actual address, SSH username, port, private-key path and pinned host public key. A single endpoint has this structure:

```yaml
proxies:
  - name: phone-a
    type: ssh
    server: 192.168.50.100
    port: 8022
    username: REPLACE_WITH_SSH_USERNAME
    private-key: /data/mihomo-router/ssh/gateway_ed25519
    host-key-algorithms:
      - ssh-ed25519
    host-key:
      - 'ssh-ed25519 REPLACE_WITH_VERIFIED_HOST_PUBLIC_KEY'
```

An Android/Termux endpoint can start OpenSSH when its terminal environment opens. This setup does not require starting the terminal application at Android boot. For the specific compatibility issue where system tracing bytes corrupt SSH forwarding, see the [Termux troubleshooting notes](../contrib/termux/README.md). Do not load that workaround unconditionally.

## 2. Configure targets and static loop prevention

Edit the router's private `router.conf`. Retain existing subscription and core settings, and add or update:

```sh
# Include only the managed main LAN, not the guest subnet.
LAN_CIDRS='192.168.50.0/24'

SSH_GATEWAY_ENABLED=1
SSH_GATEWAY_CIDRS='10.42.0.0/16'
SSH_GATEWAY_DOMAINS='internal.example'
SSH_GATEWAY_DNS='tcp://10.42.0.53:53'

# List all endpoint source addresses so switching devices remains loop-safe.
BYPASS_SOURCE_CIDRS='192.168.50.100/32'
BYPASS_SOURCE_MODE=gateway

# Optional LAN dashboard: replace the address and private random token.
CONTROLLER_ADDRESS='192.168.50.1:19090'
CONTROLLER_SECRET='REPLACE_WITH_PRIVATE_RANDOM_TOKEN'
DASHBOARD_DIR='/data/mihomo-router/share/ui'
PANEL_INTERFACE=br-lan
PANEL_ALLOWED_CIDRS='192.168.50.0/24'
```

Use precise target prefixes instead of classifying entire large address ranges as internal. List required domain suffixes explicitly as well: relying only on the eventual resolved IP can let Fake-IP traffic match other rules first.

Domain DNS uses the same SSH gateway. Choose TCP DNS, DNS-over-TLS or DNS-over-HTTPS that the endpoint can reach. SSH outbounds do not carry ordinary UDP DNS. A public resolver is suitable only when it actually answers the required names; private zones require a reachable internal resolver.

`BYPASS_SOURCE_MODE=gateway` has these effects:

- Ordinary main-LAN clients use the selected SSH gateway for configured internal targets.
- An endpoint's own traffic to those targets follows its own network path instead of returning to its SSH outbound.
- Endpoint port-53 queries bypass main-LAN DNS interception. Its ordinary public traffic still follows subscription proxy rules.

`BYPASS_SOURCE_MODE=all` remains the legacy default for compatibility. It also excludes the endpoint's public traffic from transparent proxying. Explicitly use `gateway` when the endpoint still needs the router's public proxy.

Do not configure automatic probing or fallback. The current implementation has no monitor process. If the endpoint leaves the network, SSH is unavailable or the remote target cannot be reached, requests fail with a connection error or normal timeout; they do not switch to DIRECT. Static loop prevention does not depend on endpoint availability.

## 3. Keep guest access direct

For example, keep a guest subnet such as `192.168.60.0/24` out of `LAN_CIDRS`. Guest DHCP/DNS must use independent ordinary upstream resolution rather than the main Mihomo DNS listener, or guests can receive unusable Fake-IP answers.

Preserve vendor guest-to-WAN forwarding and main/guest isolation. Do not expose the controller to guests. Bridge creation, wireless configuration and persistence differ by firmware; do not overwrite vendor wireless settings with a generic OpenWrt configuration.

## 4. Load settings, select a device and open the dashboard

```sh
mihomo-router gateway check
mihomo-router-boot restart
mihomo-router gateway status
mihomo-router gateway use phone-a
```

`gateway check` validates configuration, not actual connectivity. The core persists the selected endpoint across reboots. Both internal routing and its DNS refer to that fixed selection.

From the main LAN, open the example URL `http://192.168.50.1:19090/ui/` and enter the locally stored controller token. The page selects internal endpoints and subscription nodes. A selected endpoint is a routing choice, not proof that it is reachable. Changes affect new connections; reconnect existing sessions.

To deploy a later repository version from the management machine:

```sh
./bin/mihomo-router-deploy upgrade --host YOUR_ROUTER_SSH_HOST
```

Upgrades preserve the router's private settings and inventory. Do not copy actual deployment settings into the repository as a template.

## 5. Acceptance checks

1. Verify an actual internal service from the endpoint itself.
2. From a main-LAN client without its own proxy or remote-access client, test public and internal access independently. The endpoint phone's own connectivity does not verify LAN transparency.
3. Test both names and target IPs, including an internal TCP service outside the ordinary public port allowlist.
4. Verify real guest DNS answers, direct public access, and isolation from the management page and restricted main-LAN services.
5. During an authorized maintenance window, make the endpoint temporarily unavailable. Internal requests should fail while public and guest access continue. After restoring the endpoint, new requests should work again. There should be no automatic route change or extra monitoring process.
6. After a planned router reboot, verify one Mihomo core, the retained endpoint selection, and consistent main/guest behavior.

The repository includes a [TAP client test helper](../test/tap-client.sh) for manual acceptance on compatible kernels. Test helpers are not installed as background services. See [runtime costs and verified behavior](../test/GATEWAY-COST.md).

## Clients with their own remote-access tunnel

A client's own tunnel normally encapsulates internal requests before the router sees them. The router classifies the outer connection's address and domain. If the remote server itself matches a managed internal target, that outer connection can still use the shared SSH gateway.

The router does not detect which clients have enabled their own tunnel. To exempt a known client from shared internal routing, add its reserved source address to `BYPASS_SOURCE_CIDRS` and retain `gateway` mode for ordinary public proxying. Guest ingress continues through the ordinary WAN path.

This controller primarily manages IPv4, and SSH outbounds carry TCP. It is not a full IP tunnel. Routed IPv6, UDP and other protocol requirements need separate design and acceptance.
