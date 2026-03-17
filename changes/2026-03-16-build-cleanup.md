# Unified Build System

## Why

Running Steno required knowing a multi-step incantation: `swift build` then
`codesign` with the right entitlements then run the binary directly (because
`swift run` skips code-signing and crashes). The entitlements file was
incomplete, the build script only covered the legacy monolith, and the
pre-push hook only ran one of three test suites.

## How

Added a top-level Makefile that handles build, sign, test, and run for all
components. Created proper daemon entitlements and Info.plist. Removed the
stale `Scripts/build-signed.sh`. Updated docs.

## Key Decisions

- **Makefile over shell scripts**: Single entry point, discoverable targets,
  dependency tracking between build/sign/run steps
- **Debug builds for `run-daemon`**: Faster iteration during development;
  release builds via `make build` for installation
- **Daemon gets its own entitlements + Info.plist**: Co-located in
  `daemon/Resources/`, includes all four required entitlements
  (audio-input, speech-recognition, disable-library-validation, allow-jit)
  plus TCC usage descriptions via embedded Info.plist
- **Pre-push hook uses `make test`**: Runs all three test suites (daemon,
  TUI, legacy) instead of just detecting `Package.swift` at root

## Testing

[steno-tests-passed: 343 tests (169 daemon + 37 TUI + 137 legacy)]

## What's Next

- Remove legacy monolith once Go TUI is fully stable (drops `test-legacy`
  target and root `Package.swift`)
- Consider a `make dev` target that runs daemon + TUI together
