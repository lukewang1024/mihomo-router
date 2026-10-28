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

## Offline fallback: deployed and tested

A naive fallback group is insufficient: in this pinned core, when all
candidates are unhealthy, `findAliveProxy` returns the first candidate.
Testing an internal URL through both SSH and DIRECT can therefore select a
dead SSH endpoint again. A public probe also cannot establish that the
phone's corporate VPN is ready.

Source: https://github.com/MetaCubeX/mihomo/blob/v1.19.28/adapter/outboundgroup/fallback.go

The deployed monitor performs a single bounded probe of the selected gateway every 60
seconds with a 3-second timeout and two consecutive results before switching.
That is at most 1,440 scheduled probes per day for one selected gateway;
two failures normally detect an outage within roughly 60–126 seconds,
depending on probe scheduling. A shorter detection target increases probes.

It uses the existing core's selected-outbound URL test through the local API;
there is no external SSH client and no per-connection monitor operation.
Each check uses several bounded local API calls and one URL test of the
selected gateway, not every inventory node. It reads the URL-specific alive
flag because v1.19.28 can return HTTP 200 from the delay API even when the
expected target status did not match. The effective selector controls both
target traffic and DNS. The user device selector remains unchanged.

On-device snapshots: monitor RSS 992–1,004 KiB; its waiting `sleep` process
RSS 644 KiB, totaling about 1.6 MiB. Curl/jsonfilter run transiently during a
check; these snapshots are not a peak memory or throughput benchmark.
The source guard itself still adds no process. Probe state and authentication
files are bounded and private in /tmp. There is no per-check persistent config
write. The existing core cache.db was 32 KiB; API selector changes may update
that persistent cache on boot/health transitions, not every successful probe.

At a temporary 10-second interval, blocking the real phone SSH transport
switched to DIRECT after 22 seconds. After clearing DNS cache, a fresh real
private-domain lookup succeeded with that transport still blocked. Restoring
transport recovered SSH routing after 23 seconds and the internal HTTP target
returned 301. Core PID stayed unchanged throughout.

A separate test SSH endpoint on the phone allowed a loopback control target
but denied the private target: authentication and control forwarding succeeded,
the private URL-specific health flag was false, and the route was DIRECT.
This simulates an unavailable private path with working SSH; Android's actual
VPN switch was not toggled. A real 200 response with an expected 204 also
produced API 200 but URL-specific alive=false, verifying the status mismatch.
`test/gateway-monitor.sh` checks the actual monitor state machine against a
cached healthy state, isolated failures, isolated successes, two consecutive
results, HTTP-200-but-unhealthy verdicts and cleanup. Full mock regressions,
real-core configuration parsing and dashboard tests also passed.

Repeating the real transport outage with the production 60-second interval
switched to DIRECT after 127 seconds (including polling/API overhead), then
restored SSH after 119 seconds. Fresh private DNS succeeded while blocked;
core PID remained unchanged. Public main-LAN HTTPS (Google 204) and guest
direct HTTPS (Baidu 200) also succeeded during that outage. A separate synthetic
LAN client subsequently accessed the real internal HTTPS target with status
200 and certificate validation using a current trusted CA bundle.

During a 253.83-second observation containing health checks and fault recovery,
the monitor's Linux CPU accounting, including reaped children, increased by
one tick. This coarse process counter excludes the core's probe work and is
not an overall CPU utilization or throughput measurement.

Final physical router reboot changed the boot ID. One core and one monitor
returned automatically, retaining the selected phone and 60-second interval.
The effective route initially stayed DIRECT while checks accumulated, then
returned to SSH after consecutive successes. An upgrade also confirmed the
previous monitor PID had exited. Main/guest synthetic LAN HTTPS checks passed
again after reboot; no test namespace was left running.

DNS must follow the effective fallback route too, or a dead SSH DNS path can
prevent DIRECT connections. Switching only affects new connections; existing
sessions need reconnection. DIRECT fallback attempts the router's ordinary
route; it does not create access to private networks when the only VPN path
is absent. Tests of private path failure are fault injection, not proof of
every possible Android VPN failure mode.
