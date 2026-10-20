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
