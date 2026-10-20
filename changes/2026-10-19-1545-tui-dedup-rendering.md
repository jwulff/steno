# Show dedup decisions in the live TUI

## Why

`DedupCoordinator` marks mic segments as duplicates of system-audio segments
in SQLite. MCP, markdown export and topic expansion already filter those
marks out, but the live TUI never heard about them. Every utterance the mic
picked up from the speakers showed twice in the headline view (#123,
under #32).

## How

- **Daemon.** `DedupCoordinator.runPass` returns the pairs it marked in
  `DedupOutcome.markedPairs`. `RecordingEngine` emits one
  `EngineEvent.duplicateMarked` per pair after both the debounced pass and
  the session-close pass. `EventBroadcaster` maps it to a new `dedup` event
  type, so clients that do not subscribe to it see nothing new.
- **Wire.** `DaemonEvent` and the Go `Event` gain optional
  `duplicateOfSequence` and `method` fields.
- **TUI.** Entries record their session ID and match `dedup` events on
  (session ID, sequence number). Sequence numbers are unique only within a
  session, and the entry list is not cleared between sessions, so matching
  on sequence alone could mark the wrong row. Marked rows render dimmed and
  struck through with a "dup of #N" hint, and `d` toggles hiding them.
- **Rebase onto main (2026-10-19).** Main had gained diarization speaker
  labels, model-status events, the #80 readiness hold and an `a`
  system-audio key. The rebase keeps all of them. Both `runPass` call sites
  pass `holdForSystemAudio` as main does, `DedupOutcome` carries both
  `deferred` and `markedPairs`, and a duplicate row keeps its
  "Speaker N:" prefix. The PR's own Makefile mktemp fix was dropped because
  main fixed the same bug differently.

## Validation

- `make test-daemon`: 516 passed, 0 failed.
- `go test ./...` passes apart from the live-daemon tests, which need a
  running daemon.
- New tests cover marked-pair accounting in the coordinator, event mapping
  and subscription gating, the Go wire round trip, composite-key matching
  including the cross-session case, rendering, and the `d` toggle.
- Codex reviewed the rebased branch read-only. Findings and dispositions
  are in the PR body.
