# mihomo-router

`mihomo-router` is a small, auditable replacement for the runtime parts of
ShellCrash on older, vendor-modified OpenWrt routers using iptables.

It intentionally does not manage proxy groups or edit node credentials.  It
downloads a Clash-compatible subscription, applies the router compatibility
overlay, validates it with Mihomo, and atomically activates it.

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
- `test/` — hermetic command mocks and integration tests.
- `Dockerfile.test` — an Alpine/BusyBox test environment with iptables 1.6.

## Commands

```sh
./install.sh --subscription-url 'https://example.invalid/subscription' --start
mihomo-router install
mihomo-router migrate-shellcrash
mihomo-router update
mihomo-router start
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

The first command is the usual fresh-router setup. It stores the URL in
`/etc/mihomo-router.conf` with mode `600`, downloads and validates the
subscription, enables the OpenWrt service, and starts it. It refuses to start
while a ShellCrash init service reports that it is running.

For a staged/offline install, omit `--start`. `--root DIR` installs into a test
or image root instead of the live router.

The URL argument is convenient on a fresh router, but it can briefly appear in
the shell history and process list. For stricter handling, omit the argument
and edit `/etc/mihomo-router.conf` (mode `600`) before running `update`.
For a migration on the same router, `migrate-shellcrash` copies the `Url` value
from `/data/ShellCrash/configs/ShellCrash.cfg` without printing it.
Subscriptions are requested with `User-Agent: clash.meta` by default so servers
that negotiate formats return Clash YAML rather than legacy/base64 content.

`install` creates runtime directories and installs the procd init script.  It
does not overwrite ShellCrash or alter its boot setting.  Disable ShellCrash
only when the new service has passed a manual test; both services must never
own the transparent-proxy rules at the same time.

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
