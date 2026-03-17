.PHONY: build build-daemon build-daemon-debug build-tui \
       sign-daemon sign-daemon-debug \
       run-daemon run-tui \
       test test-daemon test-tui test-legacy \
       clean install

# Directories
DAEMON_DIR    = daemon
TUI_DIR       = tui
DAEMON_RELEASE = $(DAEMON_DIR)/.build/release
DAEMON_DEBUG   = $(DAEMON_DIR)/.build/debug

# Binaries
DAEMON_BIN = steno-daemon
TUI_BIN    = steno-tui

# Signing — ad-hoc is correct for local CLI use. Apple Development
# certificates trigger provisioning profile validation which fails
# for bare CLI binaries (no bundle to embed a profile in).
CODESIGN_IDENTITY ?= -
ENTITLEMENTS      = $(DAEMON_DIR)/Resources/StenoDaemon.entitlements
INFO_PLIST        = Resources/Info.plist

# Install location
PREFIX = /usr/local/bin

# --- Build ---

build: build-daemon build-tui

build-daemon:
	cd $(DAEMON_DIR) && swift build -c release \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker $(INFO_PLIST)

build-daemon-debug:
	cd $(DAEMON_DIR) && swift build \
		-Xlinker -sectcreate -Xlinker __TEXT \
		-Xlinker __info_plist -Xlinker $(INFO_PLIST)

build-tui:
	cd $(TUI_DIR) && go build -o $(TUI_BIN) .

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

run-tui: build-tui
	$(TUI_DIR)/$(TUI_BIN)

# --- Test ---

test: test-daemon test-tui test-legacy

test-daemon:
	cd $(DAEMON_DIR) && swift test

test-tui:
	cd $(TUI_DIR) && go test ./...

test-legacy:
	swift test

# --- Clean ---

clean:
	cd $(DAEMON_DIR) && swift package clean
	rm -f $(TUI_DIR)/$(TUI_BIN)
	swift package clean

# --- Install ---

install: sign-daemon build-tui
	install -d $(PREFIX)
	install -m 755 $(DAEMON_RELEASE)/$(DAEMON_BIN) $(PREFIX)/$(DAEMON_BIN)
	install -m 755 $(TUI_DIR)/$(TUI_BIN) $(PREFIX)/$(TUI_BIN)
	@echo ""
	@echo "Installed to $(PREFIX):"
	@echo "  $(PREFIX)/$(DAEMON_BIN)"
	@echo "  $(PREFIX)/$(TUI_BIN)"
