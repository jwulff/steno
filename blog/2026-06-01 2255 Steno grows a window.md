# Steno grows a window

Until now Steno has run in one place: a terminal. The daemon captures audio and
transcribes on-device; a Go TUI draws the transcript, level meters, and topics.
It works, but it asks the user to keep a terminal open and to know what a
terminal is.

This change adds a native macOS app — a menu-bar resident with a main window —
as an alternative front-end. It does not replace the TUI. Both ship.

The deliberate constraint was that the app own no recording logic. Steno's
architecture already separates the durable part (the daemon: capture,
transcription, dedup, topics, SQLite) from the views on top of it. The TUI is
one such view. The new app is another. It speaks the same NDJSON socket
protocol — `subscribe`, `status`, `pause`, `resume`, `demarcate`,
`reconfigure` — and reads the same read-only SQLite view for topics. It
auto-starts the daemon the way the TUI does, and reconnects if the socket drops.
Nothing about the daemon changed.

The code is a SwiftPM package split in two: a `StenoCore` library holding the
wire types, the socket client, the daemon launcher, the SQLite reader, and an
observable model that folds the daemon's event stream into UI state — and a thin
SwiftUI target on top. The split exists so the wire logic is testable without a
running socket; the event fold is a pure function with thirty-two tests behind
it. The package has zero external dependencies. SwiftUI, Network, and SQLite3
all ship in the macOS SDK, so the build is fast and the bundle carries no
third-party code.

A note on honesty in the UI. When the bundle was first launched, it auto-started
the daemon, connected, and reported "Recording stopped" — because the daemon was
genuinely in an error state, lacking microphone permission. The app didn't
pretend to listen. It said recording was stopped, explained why, and offered a
button to the right pane in System Settings. A front-end that misreports the
state of the thing it fronts is worse than no front-end; the empty states are
status-aware on purpose.

Still to come: embedding the daemon for standalone distribution, a summary view,
speaker naming, and an icon. For now, Steno has a window.
