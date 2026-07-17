.PHONY: test lint format-check check single release sensitive vm-gate

test:
	./tests/run.sh

lint:
	shellcheck vps-guard.sh install.sh lib/*.sh scripts/*.sh tests/*.sh

format-check:
	shfmt --diff --indent 2 --case-indent vps-guard.sh install.sh lib/*.sh scripts/*.sh tests/*.sh

check: lint format-check test

single:
	./scripts/build-single.sh

release:
	./scripts/build-release.sh

sensitive:
	./scripts/check-sensitive.sh .

vm-gate:
	./scripts/check-vm-gate.sh
