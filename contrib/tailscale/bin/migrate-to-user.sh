#!/bin/sh

set -eu

sleep 3
/etc/init.d/tailscale-wol stop
sleep 1
# Force boot-run to extract and verify the installed archive on upgrade.
rm -f /tmp/tailscale-wol/tailscaled
/etc/init.d/tailscale-wol start
