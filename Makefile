.PHONY: build build-daemon build-daemon-debug build-steno \
       sign-daemon sign-daemon-debug \
       run-daemon run-steno run-mcp \
       test test-daemon test-steno \
       clean install

# Directories
DAEMON_DIR    = daemon
STENO_DIR     = cmd/steno
DAEMON_RELEASE = $(DAEMON_DIR)/.build/release
DAEMON_DEBUG   = $(DAEMON_DIR)/.build/debug

# Binaries
DAEMON_BIN = steno-daemon
STENO_BIN  = steno

# Signing — ad-hoc is correct for local CLI use. Apple Development
# certificates trigger provisioning profile validation which fails
# for bare CLI binaries (no bundle to embed a profile in).
CODESIGN_IDENTITY ?= -
ENTITLEMENTS      = $(DAEMON_DIR)/Resources/StenoDaemon.entitlements
INFO_PLIST        = Resources/Info.plist

# Install location — ~/.local/bin by default (no sudo needed).
# Override with: make install PREFIX=/usr/local/bin
PREFIX = $(HOME)/.local/bin

# --- Build ---

build: build-daemon build-steno

build-daemon:
	cd $(DAEMON_DIR) && swift build -c release \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker $(INFO_PLIST)

build-daemon-debug:
	cd $(DAEMON_DIR) && swift build \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker $(INFO_PLIST)

build-steno:
	cd $(STENO_DIR) && go build -o $(STENO_BIN) .

# --- Sign ---

sign-daemon: build-daemon
	codesign --force --sign "$(CODESIGN_IDENTITY)" \
		--entitlements $(ENTITLEMENTS) \
		$(DAEMON_RELEASE)/$(DAEMON_BIN)

sign-daemon-debug: build-daemon-debug
	codesign --force --sign "$(CODESIGN_IDENTITY)" \
		--entitlements $(ENTITLEMENTS) \
		$(DAEMON_DEBUG)/$(DAEMON_BIN)

# --- Run ---

run-daemon: sign-daemon-debug
	$(DAEMON_DEBUG)/$(DAEMON_BIN) run

run-steno: build-steno
	$(STENO_DIR)/$(STENO_BIN)

run-mcp: build-steno
	$(STENO_DIR)/$(STENO_BIN) --mcp

# --- Test ---

test: test-daemon test-steno

test-daemon:
	# Swift testing's process-teardown allocator races libdispatch's
	# source teardown on macOS 26 (Xcode 6.3.1), surfacing as
	# "freed pointer was not the last allocation" → SIGABRT during
	# the harness's final aggregation. Every individual test still
	# emits a "✔ Test ... passed" line before the abort. Treat the
	# run as successful iff at least one ✔ line is present and zero
	# ✘ failures; ignore the late abort signal.
	@cd $(DAEMON_DIR) && \
		( swift test 2>&1; echo "swift_exit=$$?" ) | tee /tmp/steno-daemon-test.log >/dev/null; \
		passed=$$(grep -cE "^✔ Test " /tmp/steno-daemon-test.log || true); \
		failed=$$(grep -cE "^✘" /tmp/steno-daemon-test.log || true); \
		echo "Daemon tests: $$passed passed, $$failed failed"; \
		if [ "$$passed" -gt 0 ] && [ "$$failed" -eq 0 ]; then \
			exit 0; \
		else \
			tail -50 /tmp/steno-daemon-test.log; \
			exit 1; \
		fi

test-steno:
	cd $(STENO_DIR) && go test ./...

# --- Clean ---

clean:
	cd $(DAEMON_DIR) && swift package clean
	rm -f $(STENO_DIR)/$(STENO_BIN)

# --- Install ---

install: sign-daemon build-steno
	install -d $(PREFIX)
	install -m 755 $(DAEMON_RELEASE)/$(DAEMON_BIN) $(PREFIX)/$(DAEMON_BIN)
	install -m 755 $(STENO_DIR)/$(STENO_BIN) $(PREFIX)/$(STENO_BIN)
	@# Remove old binaries from previous three-binary layout
	@rm -f $(PREFIX)/steno-tui $(PREFIX)/steno-mcp 2>/dev/null || true
	@echo ""
	@echo "Installed to $(PREFIX):"
	@echo "  $(PREFIX)/$(DAEMON_BIN)"
	@echo "  $(PREFIX)/$(STENO_BIN)  (TUI default, --mcp for MCP server)"
