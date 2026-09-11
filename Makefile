.PHONY: help install uninstall lint smoke clean

help:
	@echo "Targets:"
	@echo "  install   Install aidc CLI into ~/.local/bin"
	@echo "  uninstall Remove the aidc symlink from ~/.local/bin"
	@echo "  lint      Lint shell scripts with shellcheck"
	@echo "  smoke     Run smoke tests against a freshly created session"
	@echo "  clean     Remove generated artifacts"

install:
	mkdir -p $$HOME/.local/bin
	ln -sf $$(pwd)/scripts/aidc $$HOME/.local/bin/aidc
	@echo "Linked aidc -> $$HOME/.local/bin/aidc"
	@echo "Ensure $$HOME/.local/bin is on PATH"

uninstall:
	rm -f $$HOME/.local/bin/aidc
	@echo "Removed $$HOME/.local/bin/aidc (if it was present)"

# Lint at warning severity: the sourced-lib pattern (`. $AIDC_SCRIPTS/lib/...`)
# produces unavoidable SC1091 info noise, and several jq filters trip SC2016
# (info) as expected false positives. warning+ is the meaningful bar and lets
# a real regression fail the build (no more `|| true` mask hiding findings).
# NOTE: proxy/forwarder/ has no shell scripts (pure socat ENTRYPOINT), so there
# is nothing to add for it here.
lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	shellcheck --severity=warning \
	    install.sh \
	    scripts/aidc scripts/cmd-*.sh scripts/lib/*.sh \
	    proxy/refresher/*.sh proxy/policy/*.sh proxy/audit/*.sh
	bash release/lint-formula-template.sh

smoke:
	bash tests/smoke/run.sh

clean:
	rm -f proxy/squid/blocklist.txt
	@echo "Cleaned generated artifacts (audit data is NOT touched)"
