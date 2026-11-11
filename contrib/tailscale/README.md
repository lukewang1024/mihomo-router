# Optional Tailscale management access

This add-on installs a pinned ARM64 Tailscale client for the Xiaomi routers used
with mihomo-router. It is independent of Mihomo installation and does not
authenticate a device during installation.

The bundled archive is the 1.104.1-ax3600-minimal build already running on the
R6500. It uses Tailscale userspace networking and is launched with the
--tun=userspace-networking option. This deployment is for remote management
through Tailscale Serve; it does not create a TUN route for LAN clients, accept
routes, accept Tailnet DNS, advertise subnet routes, or enable Tailscale SSH.

## Install and register separately

From the repository checkout, install the client and persistent startup:

    ./bin/mihomo-router-deploy tailscale-install --host ROUTER_SSH_HOST

This verifies both the archive and extracted binary checksums, stores the
compressed payload below /data/userdisk, installs the procd service, and
registers a separate UCI firewall include so Xiaomi firmware can restore the
service after rebuilding /etc. Existing node state is preserved.

When ready to add that router to the Tailnet, run:

    ./bin/mihomo-router-deploy tailscale-register --host ROUTER_SSH_HOST

The router prints Tailscale's one-time sign-in URL. Open it and approve the
device. Run the same command again afterward; it then configures a
Tailnet-only TCP forwarder on port 2222 to the router's existing SSH server on
127.0.0.1:22. The install step never asks for a login and the repository never
stores an auth key or the router's private node state.

To inspect the result:

    ./bin/mihomo-router-deploy tailscale-status --host ROUTER_SSH_HOST

The router-side command is /data/tailscale-wol/tailscale-control.sh; its
register, status, start, and stop actions can also be used from a router shell.

## Optional exit node

A registered router can advertise itself as a selectable Tailnet exit node:

    ./bin/mihomo-router-deploy tailscale-exit-node --host ROUTER_SSH_HOST enable

Clients keep their current direct route until a user chooses this exit node in
Tailscale. This bundled minimal build supports userspace exit routing for TCP
and UDP. It does not route other IP protocols, and exit traffic leaves through
the router's normal WAN path; it does not pass through the Mihomo rules that
capture forwarded LAN traffic. A Linux build with OS router support is required
for kernel-mode routing and for source-based Mihomo interception.

The Tailnet administrator may need to approve the router as an exit node in
the admin console. To withdraw the advertisement later, run the same command
with `disable`. This minimal build cannot select an exit node itself, so its
own `ExitNodeOption` status may remain false after the routes are approved;
check availability in a normal client’s exit-node picker. IPv6 exit service
requires working IPv6 forwarding and upstream IPv6 connectivity on the router.

## Storage and upgrade notes

The compressed client is stored below /data/userdisk when space permits. The
installer reuses a valid archive already at /data/tailscale-wol/bin to avoid
requiring a second archive-sized block of flash space. The active executable
is verified and extracted to /tmp on startup. Tailscale's persistent identity
stays under /data/tailscale-wol/state; never copy this directory between
routers or commit it.

The bundled client reports version 1.104.1-ax3600-minimal and its extracted
SHA-256 is recorded in tailscaled.sha256. The archive checksum is recorded
beside the archive. Update both checksums and this version note when replacing
the binary. Tailscale's upstream CLI and daemon are distributed under
BSD-3-Clause; see LICENSE.tailscale and the upstream
dependency license inventory at:
https://github.com/tailscale/tailscale/tree/v1.104.1/licenses

Userspace networking is enabled with the daemon's
--tun=userspace-networking option, as described at:
https://tailscale.com/docs/concepts/userspace-networking

The SSH forwarder uses Tailscale Serve and remains private to the Tailnet:
https://tailscale.com/docs/reference/tailscale-cli/serve
