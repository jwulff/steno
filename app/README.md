# Steno (macOS app)

A native SwiftUI front-end to `steno-daemon` — a graphical alternative to the
terminal TUI for everyday use.

The app owns **no** capture or transcription logic. It is a thin client of the
exact same daemon the TUI uses:

- **Live loop** over the daemon's NDJSON Unix socket
  (`~/Library/Application Support/Steno/steno.sock`): partial + finalized
  transcript, mic/system level meters, recording/pause/recovery status, model
  readiness, and speaker labels.
- **Topics** read from the daemon's SQLite view
  (`~/Library/Application Support/Steno/steno.sqlite`, read-only).
- **Daemon lifecycle**: locates `steno-daemon` (co-located → `$STENO_DAEMON_PATH`
  → `~/.local/bin` → `PATH`), auto-starts it, and reconnects if the socket drops.
- **Health + restart**: an engine-health chip (header and menu bar) shows whether
  the daemon is healthy / unreachable / stopped / errored, with a one-click
  **Restart Engine** that safely stops the process (confirming identity before
  signaling) and brings up a fresh one.

## Run

```bash
make run-app      # build, bundle, sign, and launch Steno.app
make build-app    # just assemble app/.build/Steno.app
make test-app     # StenoCore unit tests
```

Requires the daemon installed (`make install`) or discoverable on `PATH`.

## Layout

```
app/
├── Package.swift
├── Sources/
│   ├── StenoCore/        # testable, no SwiftUI
│   │   ├── DaemonProtocol.swift   # Codable wire types (mirror the daemon)
│   │   ├── LineFramer.swift       # NDJSON framing
│   │   ├── DaemonClient.swift     # NWConnection socket client
│   │   ├── DaemonLauncher.swift   # locate + spawn the daemon
│   │   ├── SQLiteReader.swift     # read-only topic/segment/summary queries
│   │   ├── Models.swift           # UI domain models
│   │   └── AppModel.swift         # @Observable state; folds the event stream
│   └── StenoApp/         # SwiftUI
│       ├── StenoApp.swift         # @main: window + menu bar + commands
│       ├── Design/Theme.swift
│       └── Views/                 # transcript, topics, transport, status, menu bar
└── Tests/StenoCoreTests/
```

## Design notes

- **Zero external dependencies.** SwiftUI, Network, and SQLite3 all ship in the
  macOS SDK. Fast builds, no supply chain.
- **Non-sandboxed.** The app needs the Unix socket, the app-support directory,
  and the ability to spawn the daemon. It does not access the microphone — the
  daemon does, under its own entitlements.
- **Keyboard:** `Space` new session · `p` (or ⌘P) pause/resume · ⌘N new session
  · ⌘L toggle system audio.
