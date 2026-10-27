# mihomo-router

`mihomo-router` is a small, auditable replacement for the runtime parts of
ShellCrash on older, vendor-modified OpenWrt routers using iptables.

It downloads a Clash-compatible subscription, applies router compatibility
and optional routing overlays, validates it with Mihomo, and atomically
activates it. Subscription node credentials and groups are preserved. An
optional SSH gateway selector reads a separate, private local device inventory.

## Safety properties

- The subscription's Mihomo DNS settings are preserved, including dedicated
  `proxy-server-nameserver` entries needed by some providers.
- LAN TCP/UDP port 53 is redirected to the managed Mihomo resolver, preventing
  poisoned answers from sending transparent traffic to the wrong destination.
- TUN-level `dns-hijack` remains disabled; DNS ownership is explicit in the
  firewall and is removed cleanly when the service stops.
- Fake-IP destinations are captured on every TCP/UDP port, including game and
  broker login ports outside `TCP_PORTS`. Mihomo then applies the existing
  DIRECT/proxy rules. Set `FAKE_IP_CIDR` to cover the subscription's
  `dns.fake-ip-range` (default `198.18.0.0/16`). The port allowlist still applies
  to real-IP traffic. Keep the old range until old client DNS caches expire
  when changing ranges; remove old firewall rules before changing this setting.
- Failed downloads and invalid configurations leave the active config intact.
- Firewall setup and teardown are idempotent.
- Every persistent file lives below `/data/mihomo-router`; runtime files live
  below `/tmp/mihomo-router`.
- The script is POSIX `sh` and is tested with BusyBox-compatible commands.

## Layout

- `bin/mihomo-router` — the complete controller and firewall implementation.
- `share/domestic-overlay.awk` — domestic domain DNS and routing overlay.
- `etc/mihomo-router.conf.example` — router-specific settings.
- `openwrt/mihomo-router.init` — OpenWrt/procd integration.
- `bin/mihomo-router-boot` — persistent startup and ShellCrash handover.
- `test/` — hermetic command mocks and integration tests.
- `Dockerfile.test` — an Alpine/BusyBox test environment with iptables 1.6.

## Portable setup and private settings

The installer ships mechanisms, not organization-specific routing policy. Keep
subscription URLs, real target suffixes/prefixes, endpoint addresses/users,
controller tokens, and SSH keys in the router's private files:

| File | Purpose |
| --- | --- |
| `/data/mihomo-router/router.conf` | Managed LANs, target routes, DNS, UI and token |
| `/data/mihomo-router/gateways/proxies.yaml` | Endpoint inventory and pinned host keys |
| `/data/mihomo-router/ssh/` | Dedicated endpoint access keys |

Existing files survive runtime upgrades. Repository ignore rules also exclude
these common private paths if temporarily used inside a checkout; they do not
protect arbitrary filenames or replace checking a staged diff before committing.

For a new router, bootstrap the runtime, then configure its actual main subnet
in `LAN_CIDRS`. Set up the optional gateway inventory with `gateway init`; fill
its endpoint, pin its verified host key, and explicitly configure the private
target suffixes/prefixes and a tested DNS resolver. Run `gateway check` before
restarting. Enable the dashboard only on the trusted LAN, with a private
controller token. Examples below are placeholders, not a policy to copy blindly.

Guest Wi-Fi is firmware-specific and is not created automatically by the
installer. Use the vendor's supported guest setup, keep its subnet out of
`LAN_CIDRS`, and verify independent DNS and direct internet access. The main
network's wired clients share its policy. Review routed IPv6 separately.

Acceptance needs a separate LAN client: test an actual target hostname over
HTTPS and a numeric private target, then test ordinary internet access from the
guest Wi-Fi. A successful parser check or a numeric SSH test alone does not
prove domain routing and DNS work. Verify reboot behavior during a planned
maintenance window. DNS or endpoint changes should remain machine-local; they
do not require adding an organization preset to the installer.

## Commands

```sh
./install.sh --subscription-url 'https://example.invalid/subscription' --start
mihomo-router install
mihomo-router migrate-shellcrash
mihomo-router update
mihomo-router-boot start
mihomo-router status
mihomo-router stop
mihomo-router uninstall
```

For a router that already accepts SSH, the bundled bootstrap wrapper installs
the runtime, downloads and verifies the pinned geodata, disables the legacy
ShellCrash restart task, and enables mihomo-router:

```sh
./bin/mihomo-router-deploy bootstrap --host xiaomi-r3600 --subscription-stdin < private-url.txt
./bin/mihomo-router-deploy status --host xiaomi-r3600
```

The SSH host is supplied by the caller and is not part of the repository. The
subscription URL is sent over SSH stdin and is not included in the remote
command line or wrapper output. The router still stores it in its mode-600
`/etc/mihomo-router.conf`, which is required at runtime.

To upgrade the installed scripts without refreshing the subscription:

```sh
./bin/mihomo-router-deploy upgrade --host xiaomi-r6500
```

`update` refreshes the subscription; `upgrade` uploads the current runtime,
installer, overlay and boot helpers while preserving router settings.

The first command is the usual fresh-router setup. It stores the URL in
`/etc/mihomo-router.conf` with mode `600`, downloads and validates the
subscription, enables the OpenWrt service, and starts it. Activation stops and disables an existing ShellCrash init service, writes its
persistent `.dis_startup` marker (including Xiaomi's `/data/other_vol` layout),
and removes the known `task.sh 103` and `start_legacy_wd.sh shellcrash` cron
restart jobs. If stopping fails or `CrashCore` remains alive, activation fails
instead of allowing both cores to own the same ports and firewall.

For a staged/offline install, omit `--start`. `--root DIR` installs into a test
or image root instead of the live router.

The URL argument is convenient on a fresh router, but it can briefly appear in
the shell history and process list. For stricter handling, omit the argument
and edit `/etc/mihomo-router.conf` (mode `600`) before running `update`.
For a migration on the same router, `migrate-shellcrash` copies the `Url` value
from `/data/ShellCrash/configs/ShellCrash.cfg` without printing it.
Subscriptions are requested with `User-Agent: clash.meta` by default so servers
that negotiate formats return Clash YAML rather than legacy/base64 content.

The installer stores configuration in `/data/mihomo-router/router.conf` and
the init script in `/data/mihomo-router/share/mihomo-router.init`. The `/etc`
paths are symlinks for compatibility. Existing configuration is migrated
without replacing router settings or credentials. Edit the persistent config
path when using an editor that saves by replacing files.

Use `mihomo-router-boot start` (or `restart`) to activate the installation.
It registers a persistent UCI firewall include that reconstructs `/etc` and
starts procd after `/data` is available. This handles Xiaomi firmware where
`/etc` is RAM-backed and ordinary `init.d enable` links disappear on reboot.
Firewall reloads restore transparent rules and wait for TUN initialization.
The selected proxy groups are retained in `/data/mihomo-router/cache.db`.
`mihomo-router uninstall` removes the boot include, stops procd and leaves
data in place; an explicit boot-helper start can reactivate it.

A staged/offline install only writes files. ShellCrash handover happens on
activation; its scripts and subscriptions are retained.

## Domestic domains: real DNS answers and DIRECT routing

The optional domestic overlay uses the maintained
[MetaCubeX `cn.mrs` domain set](https://github.com/MetaCubeX/meta-rules-dat)
rather than inverting GFWList. A blocked-site list is not a domestic-domain
inventory: domains absent from it are not necessarily domestic.

Set the following in `/etc/mihomo-router.conf` and restart the service:

```sh
CN_RULES_ENABLED=1
CN_RULES_INTERVAL=86400
CN_RULES_PROXY=DIRECT
CN_DNS_SERVERS="https://dns.alidns.com/dns-query https://doh.pub/dns-query"
```

If the router cannot fetch GitHub directly, set `CN_RULES_PROXY` to an existing
subscription proxy/group name. This controls the rule download, not the
routing of domestic traffic. New installations enable the overlay through the
example config; existing installations remain unchanged until explicitly enabled.
An upgrade must install both the controller and `share/domestic-overlay.awk`.

Two domain providers are shared by three settings:

| Setting | Effect for a matching domain |
| --- | --- |
| `dns.fake-ip-filter` | Return a real IP instead of a synthetic address |
| `dns.nameserver-policy` | Resolve through `CN_DNS_SERVERS` |
| Leading `RULE-SET,...,DIRECT` rules | Prefer DIRECT over subscription routing rules |

Unmatched domains retain the subscription's DNS filters and routing behavior.
The overlay preserves node credentials, proxy groups, other rule providers,
DNS policies, and `proxy-server-nameserver`. It does not force every unmatched
domain through a proxy. The managed domain policy takes precedence over
subscription rules; disable it if that conflicts with intentional proxy rules.

Mihomo's [HTTP rule-provider](https://wiki.metacubex.one/config/rule-providers/)
checks for updates every 86,400 seconds while running. The MRS cache is stored at
`/data/mihomo-router/rules/cn.mrs`, so a reboot does not discard the downloaded
list. Failed refreshes retain the loaded rules; a first installation still
needs a successful download (or a pre-seeded file from the configured source).
There is no additional cron downloader. The controller exports `SAFE_PATHS`
to allow the core's `/tmp` runtime to read this persistent provider directory.

For domains missing from the public collection, edit the separate local file:

```yaml
# /data/mihomo-router/rules/direct-local.yaml
payload:
  - '+.example.com'
```

Restart `/etc/init.d/mihomo-router` after editing. This list uses domain-provider
syntax, not `DOMAIN-SUFFIX,...,DIRECT` routing syntax; `+.example.com` matches
the root and its subdomains. It starts empty and is never overwritten by
subscription refreshes. Clients may retain old DNS answers until their caches
expire, so reconnect or clear their DNS cache when verifying a change.

The overlay deliberately accepts block-style YAML for `dns`, `rules`,
`rule-providers`, `fake-ip-filter`, and `nameserver-policy`; empty nested
lists/maps are supported. Nonempty inline managed structures are rejected
instead of being silently rewritten. The default `blacklist` filter mode and
`rule` mode with an existing filter are supported. `whitelist` mode is rejected
because adding entries there would reverse the intended meaning. Provider
names `mr-cn` and `mr-direct-local` are reserved. The stored subscription stays
separate from the generated runtime overlay, preventing duplication on restart.
See Mihomo's [DNS reference](https://wiki.metacubex.one/config/dns/) and
[domain matching syntax](https://wiki.metacubex.one/handbook/syntax/).

## Diagnosing partial connectivity

Successful browser access does not prove that every application's login or
session protocol works. A service may use HTTPS initially, then open another
TCP/UDP port for its persistent connection. With Fake-IP DNS, restricting
transparent capture to common web ports lets those later connections escape
to the WAN with an unroutable synthetic destination.

The general fix is to capture **all TCP/UDP ports addressed to `FAKE_IP_CIDR`**
from the configured LANs. Mihomo recovers the domain and applies routing rules;
capturing traffic does not necessarily send it to a remote proxy. Real-IP
traffic still follows the configured port allowlist and bypass rules. Returning
real IPs for known domestic domains improves compatibility but does not replace
the Fake-IP capture requirement for other domains or cached synthetic answers.

For diagnosis, compare DNS answers, inspect the destination port and matched
rule in Mihomo's connections API/log, then inspect iptables counters. Do not
infer an application's destination from unrelated background connections.
Check both TCP and UDP and retry after DNS caches expire.

`DIRECT` is a Mihomo routing decision, not necessarily a kernel bypass. Real-IP
traffic captured on configured ports can still enter Mihomo before going out
directly. The optional `CN_IPSET` bypass only works if that set exists; this
project does not populate it. Thus the domain overlay does not promise a
particular CPU reduction or all-port kernel bypass for domestic traffic.

## Core storage

Routers with small persistent partitions may not have room for an unpacked
Mihomo binary. Configure either:

- `CORE_ARCHIVE` pointing to a persistent `.gz`/`.tar.gz` archive that fits, or
- `CORE_SOURCE` pointing to an already unpacked executable, or
- `CORE_URL` so the core is downloaded into `/tmp` after boot.

The runtime binary is always placed under `/tmp`.

Do not assume the newest generic build is compatible with an old vendor
kernel. The example pins an ARM64 compatibility package published by
ShellCrash's update channel. Change the core source and checksum when the new
router uses another architecture.
Recheck its SHA-256 before changing the URL or accepting an upstream update.
If the router's old CA bundle requires
`CORE_TLS_INSECURE=1`, `CORE_SHA256` is mandatory and is checked with either
`sha256sum` or OpenSSL before extraction.

## Tests

```sh
make test
make vm-test
make docker-test
```

`make test` needs only POSIX sh. `make vm-test` runs the suite in a Colima Linux
VM and additionally applies the real rules inside an isolated network
namespace. `make docker-test` exercises the mock suite inside an Alpine
3.8/iptables 1.6 container. Neither path modifies the macOS host firewall.

## Ad and tracker filtering

Set these in the private `/data/mihomo-router/router.conf`:

```sh
AD_RULES_ENABLED=1
AD_RULES_INTERVAL=86400
AD_RULES_PROXY=DIRECT
```

If GitHub is unreachable directly, set `AD_RULES_PROXY` to an existing subscription
proxy/group name. Do not put router-specific group names or subscription secrets
in the shared scripts. The default source is MetaCubeX's `category-ads-all.mrs`;
`AD_RULES_URL` accepts another HTTPS domain MRS provider. Mihomo refreshes it and
keeps `/data/mihomo-router/rules/ads.mrs` across restarts. Enable this only with a
core supporting domain MRS providers and `rcode://success` DNS responses.

The policy works with or without `CN_RULES_ENABLED`. Managed routing order is
ad exceptions, ad rejection, then domestic DIRECT rules and subscription rules.
Ad domains receive empty successful DNS replies and real-IP filtering excludes
them from fake-IP allocation. Exceptions in `rules/ads-allow.yaml` take priority
in both DNS and routing; use domain payloads such as `+.example.com`. Exceptions
use the configured `CN_DNS_SERVERS` and DIRECT routing, even in ad-only mode.
They do not override unrelated subscription DNS policies with more specific matches.

After changing settings or exceptions, run `mihomo-router-boot restart`.
Setting `AD_RULES_ENABLED=0` disables this managed layer; subscription-provided
ad rules remain in effect. Subscription updates preserve settings and exceptions.
An upgrade must install both the manager and `share/domestic-overlay.awk`.
Cached/in-app ads and traffic bypassing the managed IPv4 firewall may remain;
this feature does not add IPv6 interception or encrypted-DNS blocking.

## Management API and dashboards

The default management API listens on `127.0.0.1:19090` on the router. Port 9090
is commonly occupied by Xiaomi's datacenter service. A lightweight gateway dashboard is shipped in `share/ui/index.html`. Set
`DASHBOARD_DIR=/data/mihomo-router/share/ui` to serve it at `/ui/`; it displays
active gateway devices and routes and switches devices without restarting.
It does not require external assets or send credentials to another service. The API can be accessed through an SSH tunnel:

```sh
ssh -N -L 19090:127.0.0.1:19090 YOUR_ROUTER_SSH_HOST
```

A compatible dashboard can then connect to `http://127.0.0.1:19090` on the SSH
client device. Keep the API on loopback unless authentication and access rules
have been configured deliberately.

## SSH network gateways: switch devices without editing routes

The optional `SSH-Gateway` group sends selected remote prefixes/domain suffixes
through an SSH server on a LAN device. The endpoint opens the destination TCP
connection using its own network access. No extra proxy daemon, second VPN or
root access is needed on that endpoint. Its SSH server must allow TCP forwarding.
This is generic SSH forwarding: the endpoint can be a phone, laptop or server.

Rules, devices and selection are independent:

- `router.conf`: target IPv4 prefixes and domain suffixes; normally configured once.
- `gateways/proxies.yaml`: private native Mihomo file-provider inventory. Each
  device keeps its own address, port, username and verified host public key.
- `SSH-Gateway`: manual selector, changed through the dashboard or the command
  below. `profile.store-selected` persists the selection in the existing
  `/data/mihomo-router/cache.db`. No service restart is needed for a switch.

### Stage the router

Upload/install the updated runtime using `mihomo-router-deploy upgrade --host
YOUR_ROUTER_SSH_HOST` when the router is reachable. Upgrade includes both gateway
helpers and the device example; existing inventories, keys and settings survive.
The feature defaults to disabled and does not add routes until explicitly enabled.

On the router (add the persistent command directory to this shell's PATH):

```sh
export PATH=/data/mihomo-router/bin:$PATH
mihomo-router gateway init
# Fill /data/mihomo-router/gateways/proxies.yaml using
# /data/mihomo-router/share/ssh-gateways.yaml.example as a reference.
```

Use a dedicated router-to-endpoint SSH key, stored mode 600 below
`/data/mihomo-router/ssh/`, and authorize only its public key on each endpoint.
Keep inventories mode 600 and directories mode 700. Verify each device's SSH
host public key through a trusted channel and fill `host-key`; set
`host-key-algorithms` to match the pinned key (for example `ssh-ed25519`),
otherwise negotiation may choose a different host key; Mihomo otherwise
accepts arbitrary host keys. Device addresses, usernames and private keys belong
only in the router's local files, never in subscriptions or this repository.
Use DHCP reservations or stable LAN DNS names. Node names should use letters,
numbers, dot, underscore and dash, e.g. `phone-a` and `laptop-b`.

Add explicit settings to the private persistent `router.conf`, for example:

```sh
SSH_GATEWAY_ENABLED=1
SSH_GATEWAY_CIDRS="10.42.0.0/16"
SSH_GATEWAY_DOMAINS="internal.example"
SSH_GATEWAY_DNS=tcp://10.42.0.53:53
# Optional: set a private token here to override the subscription controller
# secret consistently for the running core and gateway commands.
SSH_GATEWAY_API_SECRET=
```

The addresses/domains above are examples, not a preset corporate network.
Domain routes require a reachable TCP DNS, DNS-over-TLS or DNS-over-HTTPS server;
its requests explicitly use `SSH-Gateway`. SSH cannot carry ordinary UDP DNS.
If the subscription already has an exact DNS policy for a configured suffix,
resolve that conflict first; duplicate managed policy keys are rejected.
With no domain routes, DNS is left unchanged. The overlay preserves existing
Fake-IP filters; if a target domain gets real private IPs, include their actual
prefixes in `SSH_GATEWAY_CIDRS` so those connections are captured as well.

List every required domain suffix in `SSH_GATEWAY_DOMAINS`, even when its real
addresses belong to a configured private prefix. CIDR rules use `no-resolve`:
a Fake-IP/domain connection can otherwise match an earlier domestic rule before
its private address is resolved. Validate the actual website from a LAN client,
not only an SSH connection to a numeric address.

Check the selected resolver through the gateway endpoint itself. A VPN may
return DNS SERVFAIL for plain TCP port 53 even when HTTPS works. In that case,
use a reachable DNS-over-HTTPS resolver, for example
`SSH_GATEWAY_DNS=https://dns.alidns.com/dns-query`, if it answers the required
names correctly. Public DNS is suitable only for names published there; private
DNS zones still require the endpoint's reachable internal resolver.

Validate before activation, then restart once to load the inventory/group/rules:

```sh
mihomo-router gateway check
mihomo-router-boot restart
mihomo-router gateway status
mihomo-router gateway use phone-a
# Later, after enabling network access on the other device:
mihomo-router gateway use laptop-b
```

From a client with the router SSH alias configured, switching is one command:

```sh
./bin/mihomo-router-deploy gateway --host YOUR_ROUTER_SSH_HOST use phone-a
```

`gateway check` tests configuration compatibility, not whether the endpoint or
remote network is reachable. It does not replace the active subscription.
The existing core validation fallback may defer parsing to startup if the pinned
old core cannot run config-test; confirm startup and the live selector before use.
`status` prints the selector's current device and available nodes as JSON.
`use` changes only that selector via the controller API. A failed request returns
an error; a lost HTTP response can leave the outcome unknown, so check `status`.
The controller defaults to loopback. If a subscription has a nonempty API secret,
set the matching `SSH_GATEWAY_API_SECRET` (which also becomes the runtime secret).
Authentication is passed through a temporary mode-600 curl configuration, never
in command arguments. The temporary file is removed after the request.

### Routing boundaries

Explicit target TCP prefixes are captured on every port before the usual
private-network and real-IP port bypasses. Destinations within `LAN_CIDRS` and
core-marked traffic still bypass this capture, so a broad remote prefix cannot
swallow the local SSH endpoint. Prefer precise remote prefixes over `10/8`.
The gateway firewall has a fixed owned chain/hook, so removal still works after
changing the target prefixes. Domain routes take precedence over domestic/ad
and subscription routing. The selector has no implicit DIRECT fallback.

SSH outbounds carry TCP, not arbitrary UDP, ICMP or an entire IP VPN. Kerberos
clients must be configured to use reachable KDCs over TCP when UDP would
otherwise be chosen. Switching affects new connections; reconnect existing SSH
sessions and applications when moving to another device. The SSH host must be
reachable from the router; endpoints outside the LAN need a separately configured
reverse SSH transport or another reachable address. No public SSH exposure is
configured by this feature.

### Acceptance after returning to the LAN

1. Confirm the endpoint itself reaches an actual target service.
2. Check `gateway check`, restart, and confirm the node names with `gateway status`.
3. Select the endpoint and connect from a LAN client to a known target TCP port,
   including one outside `TCP_PORTS`; inspect the matched group and `MR_GATEWAY`
   counters. A successful public website request does not verify internal access.
4. Test an internal domain with the configured DNS and Kerberos over TCP if used.
5. Switch devices, reconnect, and confirm the new device handles the connection.
6. Restart the router and verify the selected device is retained. Stop the service
   and confirm the managed gateway firewall hook is removed.

Preparation tests use isolated command mocks and never change the host firewall.
Router/core compatibility, live DNS and endpoint connectivity require that LAN
acceptance; they are not implied by passing the mock suite.

The optional real-core parser test generates disposable keys and validates the
rendered configuration without starting a service or changing the firewall:

```sh
MIHOMO_TEST_CORE=/absolute/path/to/mihomo make gateway-core-test
```

Preparation validation passed with the official Android ARM64 v1.19.33 core
(archive SHA-256 verified against its GitHub release asset digest), in addition
to `make test` and `make lint`. The mutable compatibility-core URL in the example
currently returns different bytes from its pinned checksum; that artifact was
rejected and the existing pin was not changed. Check the router's already
installed core before deployment; this validation does not promise that a newer
core is compatible with its old vendor kernel.

### Gateway dashboard

The default controller remains on loopback. To access the dashboard directly
from a trusted LAN, set `CONTROLLER_ADDRESS` to the router's specific LAN IP
and port (not its WAN/all-interface address), set a private `CONTROLLER_SECRET`,
and set `DASHBOARD_DIR=/data/mihomo-router/share/ui`. The token remains applied
when the SSH gateway is disabled. `SSH_GATEWAY_API_SECRET` is supported for
existing configurations; prefer the generic controller setting for new ones.

Open `http://ROUTER_LAN_IP:19090/ui/`. Enter the access token once; the page stores
it in that browser. A private onboarding link may use `#secret=TOKEN`; the fragment
is not sent to the web server and is removed from browser history after loading.
The page never embeds a deployment token in public HTML. It shows actual rules
from the running core and clearly distinguishes selection from endpoint health.
Changing the inventory still requires editing the private provider file and
reloading the core; it does not expose SSH credentials in the browser.

The same page lists subscription proxy groups. Manual selectors support node
changes; automatic/fallback/load-balancing groups show their current state.
The summary displays runtime mode and follows nested selections for the default
rule or global group. In rule mode, that default is not the route for every
website: the active connections table shows each connection's target, source,
matched rule and actual outbound chain. Refresh to update the snapshot; short
connections may already have ended. Recent delay values are historical samples,
not a guarantee that a node is currently reachable. Subscription controls work
without enabling the optional SSH gateway.

`make dashboard-test` uses Node's standard library to exercise authentication,
rule display, device switching and failure handling without a browser/server.

On RAM-backed routers, `MIHOMO_LOG_LEVEL=warning` can override a subscription's
per-connection info logging. Empty keeps the subscription setting; accepted values
are debug/info/warning/error/silent. Existing logs are not discarded automatically.

### Preventing gateway traffic from looping back

Reserve each SSH/VPN endpoint's LAN address and put its `/32` in the private
`BYPASS_SOURCE_CIDRS` setting, for example:

```sh
BYPASS_SOURCE_CIDRS="192.168.31.50/32"
```

This excludes the endpoint's own traffic from managed DNS, Fake-IP, private
prefix capture, TCP redirection and UDP marking. It is independent of the
selected gateway; list all endpoint source addresses that need this treatment.
The endpoint must resolve names and reach its destinations through its own
network/VPN, without relying on this router's proxy. Cached Fake-IP answers on
an excluded endpoint may need to expire before its own applications recover.

Without this exclusion, a gateway's outbound traffic can re-enter transparent
capture. Depending on endpoint VPN/proxy routing, repeated connections can
exhaust the core's file descriptors and router memory, affecting wireless
operation too. Increasing the file descriptor limit is not a loop fix.

The optional `MR_INGRESS` chains return excluded sources to the vendor's normal
firewall processing; they do not globally accept packets or bypass vendor
security. Teardown removes these chains even after the exclusion list changes.
No endpoint addresses are discovered or committed automatically.

### Main Wi-Fi with a direct guest network

Keep only the main network's IPv4 subnet in `LAN_CIDRS`. For example,
`LAN_CIDRS="192.168.0.0/24"` captures the main LAN, while an independent guest
network on `192.168.33.0/24` falls through the managed TCP/UDP and gateway
chains without redirection or marking. The setting applies to wired clients
on that main LAN as well as its Wi-Fi clients.

Keep guest DNS independent: its DHCP/DNS service must use ordinary upstream
resolvers, not forward to Mihomo's DNS listener. Main clients' port-53 queries
are redirected by source subnet; guest clients must receive real DNS answers
rather than the main network's fake IPs. Retain the vendor guest firewall's
WAN forwarding and LAN isolation. A guest network does not need access to the
management controller.

On Xiaomi stock firmware, inspect the installed guest-network helper and
wireless driver before making changes. Some builds provide
`/usr/sbin/guestwifi.sh`, which creates both bands, the guest bridge, DHCP, and
vendor firewall rules. Its presence and behavior are firmware-specific; do not
copy a standard OpenWrt wireless configuration over the vendor configuration.
Back up wireless, network, DHCP, and firewall configuration and check their
persistent copies after enabling it. Do not include Wi-Fi passwords in command
logs or tracked configuration.

This controller currently captures IPv4 only. If the main LAN acquires routed
IPv6, it can bypass the IPv4 proxy policy; configure IPv6 handling separately
before treating that policy as complete. A network with link-local IPv6 only
does not have that routed path. Verify both SSIDs with real clients after
configuration, and verify persistence after a planned router reboot.


## Optional AI routing, sniffing and controller access

Set `AI_RULES_ENABLED=1`, an `AI_GROUP` name and a space-separated
`AI_DOMAINS` suffix list in the private router configuration.
`AI_NODE_INCLUDE` and `AI_NODE_EXCLUDE` are extended regular expressions over
concrete subscription proxy names. The selector precedes subscription rules;
the optional SSH gateway's specific target routes also remain present.
Unmatched nodes, duplicate group names, and unsupported top-level inline YAML
fail rendering. Provider-only subscriptions need another selection mechanism.
Original subscription credentials and groups are retained. Overlays are rebuilt
from the original subscription, so policy changes do not accumulate old rules.
Manual selector choices persist in the core cache.

`SNIFFER_ENABLED=preserve` retains subscription behavior (default); `1`
enables HTTP/TLS/QUIC sniffing, forced DNS mapping, pure-IP parsing and destination
overrides; `0` explicitly disables it. Sniffing cannot recover every domain
from encrypted traffic and does not prove that a site's region checks pass.

For a controller bound to a specific trusted IPv4 LAN address, configure
`PANEL_ALLOWED_CIDRS` and `PANEL_INTERFACE`. Only matching source/interface
pairs and loopback may reach its TCP port; other sources are rejected. A fixed
owned dispatcher supports changed ports and idempotent teardown/reload, including
migration of the old port-19090 MR_PANEL hook. Keep a private controller secret.
The guard supports IPv4 listeners only; handle IPv6 separately.

## Storage on small Xiaomi flash partitions

Inspect mounts before choosing paths: /data, /etc and /userdisk can be aliases
of the same UBIFS volume. Moving files among those aliases adds no capacity.
Keep scripts, private configuration, compressed core, rule data and selector cache
under /data/mihomo-router. Keep the unpacked executable, logs and temporary
subscription files under /tmp/mihomo-router. The core loader accepts raw, .gz,
.tar.gz and .xz files; .xz requires a working xz decompressor and can reduce
flash usage substantially. Preserve an already proven vendor-kernel-compatible
core rather than replacing it solely to match the controller version.

Back up legacy files to a separate machine and verify the archive before
retiring them. A compact built-in dashboard replaces the much larger legacy UI.
Store historical snapshots off-router, retain flash headroom for atomic writes
and rule updates, and check memory use too: /tmp consumes RAM. A persistent
core archive makes boot independent of a mutable download URL. Verify its
unpacked hash and a fresh extraction/start before relying on it. Normal service
restart tests do not establish full-router reboot persistence.
