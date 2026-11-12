.PHONY: test lint vm-test docker-test gateway-core-test dashboard-test

test:
	sh test/run.sh
	sh test/boot.sh
	sh test/gateway.sh
	sh test/features.sh
	sh test/tailscale.sh

lint:
	sh -n bin/mihomo-router bin/mihomo-router-boot bin/mihomo-router-boot-include bin/mihomo-router-deploy install.sh openwrt/mihomo-router.init contrib/tailscale/install.sh contrib/tailscale/tailscale-control.sh contrib/tailscale/bin/* contrib/tailscale/openwrt/tailscale-wol.init test/run.sh test/boot.sh test/netns.sh test/tap-client.sh test/vm.sh test/mocks/* share/ssh-gateway.sh share/panel.sh test/features.sh test/gateway.sh test/gateway-core.sh test/tailscale.sh
	shellcheck -s sh -e SC2016,SC2030,SC2031,SC2329 bin/mihomo-router bin/mihomo-router-boot bin/mihomo-router-boot-include bin/mihomo-router-deploy install.sh openwrt/mihomo-router.init contrib/tailscale/install.sh contrib/tailscale/tailscale-control.sh contrib/tailscale/bin/* contrib/tailscale/openwrt/tailscale-wol.init test/run.sh test/boot.sh test/netns.sh test/tap-client.sh test/vm.sh test/mocks/* share/ssh-gateway.sh share/panel.sh test/features.sh test/gateway.sh test/gateway-core.sh test/tailscale.sh

vm-test:
	sh test/vm.sh

docker-test:
	docker build -t mihomo-router-test -f Dockerfile.test .
	docker run --rm mihomo-router-test

gateway-core-test:
	sh test/gateway-core.sh

dashboard-test:
	node test/dashboard.cjs
