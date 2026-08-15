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
- Failed downloads and invalid configurations leave the active config intact.
- Firewall setup and teardown are idempotent.
- Every persistent file lives below `/data/mihomo-router`; runtime files live
  below `/tmp/mihomo-router`.
- The script is POSIX `sh` and is tested with BusyBox-compatible commands.

## Layout

- `bin/mihomo-router` — the complete controller and firewall implementation.
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
