# BambuBar — canonical build, test and run entry points.
#
# The scripts under scripts/ remain the implementation; this file is the single
# place that records how to invoke them, so README, CONTRIBUTING and CI can all
# point here instead of repeating command lines that drift apart.
#
# Recipes run under zsh: the scripts use zsh-only expansions (${0:A:h:h}) and
# every target is .PHONY — SwiftPM already does incremental rebuilds, and
# "dist/BambuBar Keychain.app" contains a space, which Make cannot express as a
# real file target.

SHELL := /bin/zsh
.DEFAULT_GOAL := help

BINARY := .build/debug/BambuBar
TEST_SCRATCH := $${TMPDIR:-/tmp}bambubar-tests

.PHONY: help build build-keychain test selftest check app app-keychain release signing run clean

help: ## Show this help
	@echo "BambuBar — available targets:"
	@echo ""
	@grep -E '^[a-z][a-z-]*:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN { FS = ":.*## " } { printf "  make %-16s %s\n", $$1, $$2 }'
	@echo ""

build: ## Compile the debug binary (local storage)
	swift build --disable-sandbox

build-keychain: ## Compile the Keychain-storage variant
	swift build --disable-sandbox -Xswiftc -DKEYCHAIN_STORAGE

test: ## Run the unit suite (parsers, MQTT codec, discovery)
	zsh scripts/run-tests.sh

selftest: build ## Run the three in-binary self-tests
	$(BINARY) --self-test
	$(BINARY) --storage-self-test
	$(BINARY) --certificate-pin-self-test

check: selftest build-keychain test ## Everything CI runs, plus the unit suite

app: ## Package dist/BambuBar.app
	zsh scripts/build-app.sh local

app-keychain: ## Package "dist/BambuBar Keychain.app"
	zsh scripts/build-app.sh keychain

release: ## Package both variants as release ZIP archives
	zsh scripts/build-release.sh

signing: ## Create the stable local code-signing identity (one-time)
	zsh scripts/setup-signing.sh

run: app ## Package and launch the local-storage app
	@pkill -x BambuBar 2>/dev/null || true
	open dist/BambuBar.app

clean: ## Remove build products, packaged apps and the test scratch directory
	rm -rf .build dist "$(TEST_SCRATCH)"
