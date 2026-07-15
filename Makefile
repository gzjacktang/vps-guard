.PHONY: test lint format-check check

test:
	./tests/run.sh

lint:
	shellcheck vps-guard.sh install.sh lib/*.sh tests/*.sh

format-check:
	shfmt --diff --indent 2 --case-indent vps-guard.sh install.sh lib/*.sh tests/*.sh

check: lint format-check test
