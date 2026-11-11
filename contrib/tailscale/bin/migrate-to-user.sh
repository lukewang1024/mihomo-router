#!/bin/sh

set -eu

sleep 3
/etc/init.d/tailscale-wol stop
sleep 1
/etc/init.d/tailscale-wol start
