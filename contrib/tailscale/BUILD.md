# Rebuilding the bundled Tailscale binary

The checked-in `tailscaled-1.104.1-exit-arm64.xz` is built from the upstream
Tailscale `v1.104.1` source release using Go 1.27.3. It targets Linux ARM64,
contains the CLI and uses userspace networking. Its long version label retains
`ax3600` for traceability; it is not restricted to that router model.

From a verified upstream `v1.104.1` source checkout, run:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -buildvcs=false -trimpath \
  -ldflags '-s -w -X tailscale.com/version.shortStamp=1.104.1 -X tailscale.com/version.longStamp=1.104.1-ax3600-exit' \
  -tags 'ts_include_cli,ts_omit_aws,ts_omit_kube,ts_omit_cloud,ts_omit_tpm,ts_omit_ssh,ts_omit_taildrop,ts_omit_drive,ts_omit_webclient,ts_omit_systray,ts_omit_desktop_sessions,ts_omit_synology,ts_omit_appconnectors,ts_omit_clientupdate,ts_omit_capture,ts_omit_bird,ts_omit_useexitnode,ts_omit_useroutes,ts_omit_networkmanager,ts_omit_dbus,ts_omit_resolved,ts_omit_iptables,ts_omit_osrouter,ts_omit_tap,ts_omit_acme,ts_omit_wakeonlan,ts_omit_posture,ts_omit_identityfederation,ts_omit_oauthkey,ts_omit_sdnotify,ts_omit_syslog,ts_omit_webbrowser,ts_omit_completion,ts_omit_completion_scripts,ts_omit_qrcodes,ts_omit_flashappliance' \
  -o tailscaled ./cmd/tailscaled
xz -6e --check=crc32 -T1 -c tailscaled > tailscaled-1.104.1-exit-arm64.xz
sha256sum tailscaled > tailscaled.sha256
sha256sum tailscaled-1.104.1-exit-arm64.xz > tailscaled-1.104.1-exit-arm64.xz.sha256
```

Do not add `ts_omit_advertiseexitnode` or `ts_omit_advertiseroutes`: the latter
prevents the advertised default routes from entering the inbound packet filter,
so a node can appear as an exit while dropping its clients' traffic. Inspect
`tailscale debug go-buildinfo` in the resulting binary before publishing, and
verify the compressed and uncompressed checksums. The 8 MiB XZ dictionary and
CRC32 are compatible with the BusyBox decoder used by these routers.
