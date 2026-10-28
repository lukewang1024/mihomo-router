# Static gateway routing and runtime cost assessment

Observed on Xiaomi R3600, Mihomo v1.19.28, 2026-10-28. These are functional
checks and memory snapshots, not a throughput or CPU benchmark.

## Deployed source guard

With one endpoint, six private domain suffixes and two private prefixes,
`BYPASS_SOURCE_MODE=gateway` adds eight source-qualified DIRECT rules to
Mihomo. The source guard in each of the NAT and mangle ingress chains has
four rules: TCP/UDP DNS and the two private prefixes. Other endpoint traffic
continues through subscription routing. Guest ingress remains unmanaged.

Rules are generated during configuration loading. There is no extra daemon,
per-connection shell command, inventory read or health request. NAT rules
normally apply to the first packet of a connection; mangle rules add a small
fixed set of comparisons on packets traversing the chain. Rule count scales
with configured sources and private targets. No measured CPU percentage or
throughput improvement is claimed. Endpoint addresses currently come from
explicit source CIDRs; DHCP reservation keeps the phone address stable.

Correcting the init-script identity removed a duplicate core. Two cores had
RSS snapshots of 32,836 and 38,740 KiB; after correction and a second restart,
one core had RSS 39,092 KiB with 11 threads. These asynchronous samples do not
measure the guard's memory delta. The reported ~1.2 GiB virtual size is not
resident memory. Router RAM totals 402,472 KiB.

Independent TAP/netns LAN clients verified public HTTPS through transparent
proxying (Google 204) and guest direct HTTPS (Baidu 200), with certificate
verification and no explicit proxy. Test helpers are temporary and are not
part of the deployed runtime.

## Fixed routing; no automatic health monitor

Private targets and their DNS use the selected SSH gateway directly. If that
endpoint or its VPN path is unavailable, those requests fail; there is no
DIRECT fallback and no periodic probe. Public subscription routing, direct
guest ingress and static source guards remain independent.

The previously tested automatic monitor was removed because the phone is the
only path into the corporate network: choosing DIRECT cannot restore that
access. Removing it saves approximately 1.6 MiB of steady RSS (the monitor and
its waiting process), transient curl/jsonfilter work and periodic requests.
The endpoint inventory is still loaded when rendering configuration, not per
connection. No health state or automatic route-selector cache writes remain.

A client running its own VPN normally encapsulates internal traffic before the
router sees it. The outer VPN server connection is still classified by these
rules. If that server matches a managed prefix/domain, it can use the shared
gateway too. This configuration does not detect whether clients enabled a VPN.

After removal, live fault injection verified that a reachable internal HTTP
target returned 301, blocking the endpoint SSH transport produced HTTP 502
from the explicit proxy, and restoring transport recovered access without a
core restart. No fallback selector or monitor PID file remained. Independent
main-LAN HTTPS returned 204 and direct guest HTTPS returned 200. Test firewall
chains and namespaces were cleaned up after these checks.
