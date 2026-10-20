# Health pulse review fixes

## Why

This PR (issue #76) was written by Codex in June and sat as a draft while
main moved on. On rebase, a Claude review found four problems that would
have shipped with it:

- **Pulse on every TUI launch.** The TUI ran a pulse on every attach,
  ignoring the daemon's `healthPulseAutomaticEnabled` setting. That setting
  is off by default precisely because a pulse speaks out loud. A failed
  pulse then restarted the recording daemon.
- **Surrounding speech caused false failures.** The runner compared the
  spoken phrase against everything persisted in the window, using an edit
  distance normalised by the longer string. Any other speech in the room
  dragged a clean hit below threshold, and a false failure triggers a
  capture restart.
- **Concurrent callers could overlap pulses.** The coordinator's "running"
  flag only short-circuited once a previous report existed. Two first-time
  callers, such as a manual pulse racing the startup trigger, could both
  start a pulse and speak two tokens over each other.
- **Restarts that cannot help.** A pulse that never ran, for example
  because permissions were not granted, still made the TUI restart the
  daemon.

## How

- `status` responses now carry `healthPulseAutomatic`. The TUI pulses on
  attach only when it is true. The `h` key and `steno --health-pulse` still
  run a pulse on demand.
- Similarity is now the edit distance from the phrase to its best-matching
  span of the observed text (semi-global alignment), normalised by the
  phrase length. The 0.82 threshold keeps its meaning.
- The coordinator keeps the in-flight pulse as a task. Concurrent callers
  await it and get its report instead of starting another pulse.
- `shouldRestartForHealthPulse` returns false for the `cannotRun` state.

## Validation

- New Go tests cover the attach opt-in when the flag is absent or false,
  and the `cannotRun` no-restart case. The existing auto-trigger tests now
  set the opt-in.
- New Swift tests cover the token inside surrounding speech (passes),
  unrelated speech (fails), concurrent callers sharing one pulse, and
  `status` reporting the setting.
- `go test ./...` and `make test-daemon` pass locally. The real
  speaker-to-mic loop still needs a manual run on hardware with
  `scripts/run-local --health-pulse`.

## Rebase onto 5c30453 (2026-10-20)

- Main's wake path now runs through `rebuildAfterGap` and the #111 idle
  re-arm, so the wake trigger moved into `handleSystemDidWake`. It fires
  after either path leaves the engine recording.
- `StenoSettings` persistence moved into a settings store (#117). The three
  health-pulse keys now sit beside `errorRecoveryIntervalSeconds` and
  `reArmIdleOnWake`.
- The engine's trigger sink is now a synchronous closure, and `RunCommand`
  wraps the relay call in a `Task`. A stored `@Sendable async` closure on
  `RecordingEngine` made the daemon test process abort with "freed pointer
  was not the last allocation" in `restartMicPipeline`. Bisection showed
  that even an unused async closure property does this on main, while a
  synchronous one does not. Tracked in #133, which also records that main's
  own test run aborts partway.

## Restart through launchd (2026-10-20)

The cloud Codex review flagged that the TUI's restart after a failed pulse
broke launchd supervision. `Manager.Restart` sent SIGTERM to a
LaunchAgent-managed daemon, which exits 0. The plist's `KeepAlive` only
restarts on an unsuccessful exit, so launchd let it go, and the replacement
spawned by `Restart` ran outside launchd. A later crash would never be
restarted.

`Restart` now checks `launchctl print gui/<uid>/com.steno.daemon`. When the
job is loaded, it runs `launchctl kickstart -k` on it and waits for the
socket. If kickstart fails, it returns the error instead of spawning a
second, unsupervised daemon. When the job is not loaded, it falls back to
the direct kill-and-spawn path. The launchctl runner is injected, and a
`Manager` built without one never consults launchd, so tests cannot touch
the real job. Four tests cover the loaded path (no direct kill), the
not-loaded fallback, the kickstart failure, and the bare `Manager`.
