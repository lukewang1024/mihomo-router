# Gateway loop prevention and failover cost assessment

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

## Offline fallback: proposed, not deployed

A naive fallback group is insufficient: in this pinned core, when all
candidates are unhealthy, `findAliveProxy` returns the first candidate.
Testing an internal URL through both SSH and DIRECT can therefore select a
dead SSH endpoint again. A public probe also cannot establish that the
phone's corporate VPN is ready.

Source: https://github.com/MetaCubeX/mihomo/blob/v1.19.28/adapter/outboundgroup/fallback.go

Prefer a single bounded probe of the selected gateway, initially every 60
seconds with a 3-second timeout and two consecutive results before switching.
That is at most 1,440 scheduled probes per day for one selected gateway;
two failures normally detect an outage within roughly 60–126 seconds,
depending on probe scheduling. This is a design budget, not an implemented
or measured monitor. A shorter detection target would increase probes.

Use existing core health machinery if it can satisfy explicit DIRECT fallback
semantics; otherwise measure a small monitor before deployment. Do not probe
every connection or every inventory node. Switch via the controller rather
than rebuilding rules or restarting the core. Keep probe state in /tmp and
avoid flash writes on health transitions. Any monitor's resident memory,
CPU time and traffic still need measurement.

DNS must follow the effective fallback route too, or a dead SSH DNS path can
prevent DIRECT connections. Switching only affects new connections; existing
sessions need reconnection. DIRECT fallback attempts the router's ordinary
route; it does not create access to private networks when the only VPN path
is absent. Test phone absence and VPN absence separately, then recovery and
flapping, before enabling this behavior.
