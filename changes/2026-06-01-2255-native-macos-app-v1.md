# Native SwiftUI macOS app (v1)

## Why

Steno has shipped only as a terminal TUI. That excludes anyone who doesn't live
in a terminal and makes the always-on recorder less glanceable than it should
be. This adds a native SwiftUI app — a menu-bar resident with a main window —
as a first-class alternative to the TUI, without forking the daemon.

Tracks epic #72; closes child #73.

## How

A new SwiftPM package at `app/` with two targets:

- **StenoCore** (testable, no SwiftUI) — the wire protocol, NDJSON framing, an
  `NWConnection` Unix-socket client, the daemon launcher, a read-only SQLite
  reader, and the `@Observable` `AppModel` that folds the daemon's event stream
  into UI state.
- **StenoApp** (SwiftUI) — `@main` window + `MenuBarExtra`, a small design
  system, and the views: status header, topics sidebar, transcript, transport.

The app is a thin client of the existing `steno-daemon`. It speaks the same
NDJSON socket protocol (`subscribe`, `status`, `devices`, `pause`/`resume`,
`demarcate`, `reconfigure`) and reads the same `steno.sqlite` view (topics) the
TUI uses. It auto-starts the daemon (co-located → `$STENO_DAEMON_PATH` →
`~/.local/bin` → `PATH`) and reconnects with backoff if the socket drops.

`make build-app` assembles and ad-hoc-signs `Steno.app`; `make run-app`
launches it; `make test-app` runs the unit tests. `test-app` is wired into the
top-level `make test`.

## Key Decisions

- **Thin client, not a fork.** The daemon stays the single source of truth for
  capture, transcription, dedup, and topics. The app renders; it never records.
- **Zero external dependencies.** SwiftUI, Network, and SQLite3 ship in the
  macOS SDK — fast builds, no supply chain, lean bundle. (No GRDB; the handful
  of read-only queries don't justify it.)
- **Core/UI split for testability.** All wire and state-folding logic lives in
  StenoCore behind a pure `apply(_:)` event fold, covered by 32 tests; the UI
  target carries no business logic.
- **Wire compatibility by construction.** The Codable types mirror the daemon's
  own structs property-for-property (both default-coded Swift), so JSON keys
  match exactly. Round-trip tests lock it down.
- **Status-aware, helpful empty states.** When the daemon reports `error`
  (typically missing Microphone/Screen-Recording permission), the app says so
  plainly and offers an "Open Privacy Settings" shortcut rather than pretending
  to listen.
- **Non-sandboxed.** The app needs the Unix socket, the app-support directory,
  and to spawn the daemon; it requires no capture entitlements of its own.

## Verification

- `make test-app` → 32 tests pass (protocol round-trips, framing edge cases,
  launcher path priority, event folding).
- `make build-app` → clean release build, zero warnings; `Steno.app` assembled.
- Launched the bundle: it auto-started the daemon, connected, subscribed,
  fetched status, and rendered the live UI. With the daemon in its real
  `error` state (no TCC permission for the headless-launched binary), the app
  correctly surfaced "Recording stopped" with the permission guidance — proving
  the launch → connect → status → render path end-to-end.

## Follow-ups (not in this PR)

- Embed the daemon in the bundle for standalone distribution; notarization/DMG.
- Summary overlay, error-history view, speaker-voiceprint naming (#54), session
  history browser.
- An app icon.
