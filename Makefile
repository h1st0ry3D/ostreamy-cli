.PHONY: check lint smoke verify install

check: lint smoke verify

lint:
	./tests/lint.sh

smoke:
	./tests/smoke.sh

verify:
	./bin/ostreamy-verify

install:
	./install.sh
