.PHONY: test ipk inspect

test:
	./tests/test-core.sh
	./tests/test-procd.sh
	./tests/test-luci.sh
	@if command -v node >/dev/null 2>&1; then node --check luci/root/www/luci-static/resources/view/ax9000-fan/overview.js; fi

ipk:
	./scripts/build-packages-in-docker.sh

inspect:
	./scripts/inspect-packages.sh dist
