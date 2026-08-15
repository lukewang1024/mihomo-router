.PHONY: test lint vm-test docker-test

test:
	sh test/run.sh

lint:
	sh -n bin/mihomo-router install.sh openwrt/mihomo-router.init test/run.sh test/netns.sh test/vm.sh test/mocks/*
	shellcheck -s sh bin/mihomo-router install.sh openwrt/mihomo-router.init test/run.sh test/netns.sh test/vm.sh test/mocks/*

vm-test:
	sh test/vm.sh

docker-test:
	docker build -t mihomo-router-test -f Dockerfile.test .
	docker run --rm mihomo-router-test
