.PHONY: test lint vm-test docker-test gateway-core-test gateway-monitor-test dashboard-test

test:
	sh test/run.sh
	sh test/boot.sh
	sh test/gateway.sh
	sh test/features.sh

lint:
	sh -n bin/mihomo-router bin/mihomo-router-boot bin/mihomo-router-boot-include bin/mihomo-router-deploy install.sh openwrt/mihomo-router.init test/run.sh test/boot.sh test/netns.sh test/tap-client.sh test/gateway-monitor.sh test/gateway-failover-live.sh test/vm.sh test/mocks/* share/ssh-gateway.sh share/panel.sh test/features.sh test/gateway.sh test/gateway-core.sh
	shellcheck -s sh bin/mihomo-router bin/mihomo-router-boot bin/mihomo-router-boot-include bin/mihomo-router-deploy install.sh openwrt/mihomo-router.init test/run.sh test/boot.sh test/netns.sh test/tap-client.sh test/gateway-monitor.sh test/gateway-failover-live.sh test/vm.sh test/mocks/* share/ssh-gateway.sh share/panel.sh test/features.sh test/gateway.sh test/gateway-core.sh

vm-test:
	sh test/vm.sh

docker-test:
	docker build -t mihomo-router-test -f Dockerfile.test .
	docker run --rm mihomo-router-test

gateway-core-test:
	sh test/gateway-core.sh

gateway-monitor-test:
	sh test/gateway-monitor.sh

dashboard-test:
	node test/dashboard.cjs
