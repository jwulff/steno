# Always-On Recording: Cluster 2 — Supervisor + Heal (PR #35)

## Why

Cluster 1 (PR #33, see
`changes/2026-04-26-1200-always-on-recording-foundation.md`) gave the
daemon a fresh active session on launch and a single transaction to
recover orphans. That was the *foundation* — the daemon now starts
recording immediately and never lands in `idle`.

Cluster 2 is what makes it stay running. Today's pipeline still has
"stop on first error" behavior everywhere:

- `handleRecognizerError(_:)` is a no-op — a SpeechAnalyzer crash drops
  the pipeline silently.
- No sleep/wake handling — laptop lid close terminates the SCStream and
  the AVAudioEngine without a recovery story.
- No device-change handling — an AirPods disconnect strands the mic on
  a dead tap.
- `SCStreamDelegate.stream(_:didStopWithError:)` is thin / absent — any
  SCStream contention error (Loom started in the background,
  display reconfiguration) kills system audio for the rest of the
  session.

This PR lands all four supervisors. After it, the daemon self-heals across
recognizer crashes, sleep/wake cycles, mic device changes, and
ScreenCaptureKit interruptions — bounded by `BackoffPolicy` so a
genuinely broken environment (e.g. revoked TCC) doesn't burn CPU forever.

This is units **U5/U6/U7/U8** of
`docs/plans/2026-04-25-001-feat-always-on-recording-plan.md`.

## How

### U5 — pipeline restart with bounded backoff (commit `1078bf9`)

- New value type `BackoffPolicy` (`Engine/BackoffPolicy.swift`): delays
  `1s / 2s / 4s / 8s` capped at `30s`, surrender at 5 same-error
  attempts. **Reset condition is precise**: `attempts := 0` only after
  BOTH (a) at least one segment finalized post-restart AND (b) ≥ 30s of
  stable operation since restart. "First sample arrival" alone would
  mask cheap-restart loops where samples arrive but transcriptions never
  finalize before the next failure.
- Engine actor gains `restartMicPipeline(reason:)` and
  `restartSystemPipeline(reason:)`. Tear down (drain SpeechAnalyzer via
  `finalizeAndFinishThroughEndOfInput()`, stop AVAudioEngine or SCStream),
  wait the backoff delay, rebuild on `@MainActor` via the existing
  `Task { @MainActor in ... }.value` pattern, mark the next segment with
  `heal_marker = 'after_gap:Ns'`.
- `handleRecognizerError(_:)` now calls `restart*Pipeline(reason:
  .recognizer)`. Surrender (5 same-error attempts) emits
  `recoveryExhausted` non-transient + flips status to `.error`.
- New engine status `EngineStatus.recovering` and three new events:
  `recovering`, `healed(gapSeconds:)`, `recoveryExhausted(reason:)`.

### U6 — IOKit power observer + heal rule + power assertion (commit `b1f3a3c`)

- `PowerManagementObserver` registers `IORegisterForSystemPower` and
  trampolines messages onto actor-safe `RecordingEngine` calls.
  Crucially: it routes via
  `IONotificationPortSetDispatchQueue(port, DispatchQueue.main)`, NOT
  `CFRunLoopAddSource` — the daemon runs `dispatchMain()` (per the
  SpeechAnalyzer `@MainActor` discipline established in earlier PRs),
  and CFRunLoop sources don't get serviced in that mode.
- `kIOMessageCanSystemSleep` → `IOAllowPowerChange`.
  `kIOMessageSystemWillSleep` → `RecordingEngine.handleSystemWillSleep()`
  must complete synchronously inside a **25s budget** (5s margin under
  IOKit's 30s deadline): record `gap_started_at`, drain pipelines, persist
  in-flight segments, release power assertion, then `IOAllowPowerChange`.
  `kIOMessageSystemHasPoweredOn` → `handleSystemDidWake()`.
- `HealRule.apply(gap:deviceUID:)`:
  - `gap < 30s && deviceUID == lastDeviceUID` → reuse current session,
    write `heal_marker = 'after_gap:Ns'` on the next segment.
  - else → close current session as `interrupted`, open fresh active
    session.
- `PowerAssertion`: thin wrapper around `IOPMAssertionCreateWithName` /
  `IOPMAssertionRelease`. Named `"Steno: capturing audio"` so
  `pmset -g assertions` shows what's holding the system awake. Taken on
  `.recording` entry, released on every transition out (`.paused`,
  `.recovering`, `.error`, `.stopping`); re-taken on transition back.

### U7 — AVAudioEngine config-change healer (commit `3d38d03`)

- `MicrophoneAudioSource` extracted from `RecordingEngine` so the rebuild
  path has a clean owner — it owns its own `AVAudioEngine` instance,
  rebuilt on every config-change.
- `AudioDeviceObserver` subscribes to
  `AVAudioEngine.configurationChangeNotification` on
  `NotificationCenter.default`, debounces with a **250ms trailing-edge
  window**, and resolves the current default-input device UID via
  `kAudioHardwarePropertyDefaultInputDevice` only at the trailing edge.
- Engine compares new UID + format vs cached:
  - same UID + same format → cheap re-tap (restart only; no heal-rule
    trigger).
  - UID differs OR format differs → restart + invoke heal rule with
    `gap_secs = time-since-engine-stopped` and the new UID.

### U8 — SCStream error-code recovery + TCC-revocation surface (commit `13d89d6`)

- `SCStreamDelegate.stream(_:didStopWithError:)` now dispatches on
  `SCStreamError.Code`:
  - `userDeclined` (-3801) → non-transient
    `MIC_OR_SCREEN_PERMISSION_REVOKED` event, no retry — distinct from
    generic FAILED so the TUI can show actionable "open System Settings"
    UI later (lands in U9 / PR #37).
  - `connectionInvalid` / `noCaptureSource` / `noDisplayList` /
    `systemStoppedStream` → backoff + rebuild from fresh
    `SCShareableContent`.
  - `attemptToStopStreamState` (-3808) → ignored. Counter does not
    advance.
  - Unknown → backoff + rebuild, log the code prominently.
- **Mic-side TCC revocation gets the same treatment**: identified
  AVAudioEngine error class is mapped to
  `MIC_OR_SCREEN_PERMISSION_REVOKED` and short-circuits the U5 backoff
  loop. Cycling backoff on a TCC-revoked mic produces ambiguous
  orange-indicator flicker while silently failing — better to surface
  the actual problem.
- Stream output stored as a `let` property on `SystemAudioSource` so it
  survives rebuild (the SCStream weak-output gotcha).

## Key Decisions

- **Bounded backoff, not exponential-forever.** The exponential curve
  caps at 30s and surrenders at 5 same-error attempts because the
  failure modes that *would* benefit from infinite retry (transient
  contention) recover within a few attempts; everything else is a
  configuration / permission problem that no amount of retrying fixes.
  Capped backoff also keeps an unfixable failure from burning CPU on
  battery.
- **Reset gate requires segment-finalized AND 30s stable.** First-sample
  arrival alone would let a "samples arrive, transcribe, crash before
  finalize" loop look healthy. Requiring a finalized segment proves the
  whole pipeline is producing output.
- **Power assertion held only while `.recording`.** The whole point of
  the assertion is to prevent the laptop from sleeping the audio stack
  out from under us during long meetings. Holding it while paused or
  errored would mislead users about why the laptop isn't sleeping —
  `pmset -g assertions` is now self-documenting about *why* Steno is
  awake.
- **IOKit via libdispatch port, not CFRunLoopAddSource.** Documented
  inline because the constant `0xE0000270` (`kIOMessageSystemWillSleep`)
  is hardcoded — Swift importer can't resolve the IOKit macros, so the
  raw values appear with a comment pointing at the C header.
- **250ms trailing-edge debounce on config-change.** Empirically a
  Bluetooth audio renegotiation fires 2–4 notifications across ~200ms;
  trailing-edge means we resolve the device UID *after* the burst
  settles. Resolving on every notification would race against the
  HAL's own re-enumeration.
- **TCC revocation skips backoff.** A revoked TCC permission is not a
  transient error; cycling through 1/2/4/8s backoff while the mic stays
  dead is worse than failing loudly the first time. The
  `MIC_OR_SCREEN_PERMISSION_REVOKED` event is distinct from
  `recoveryExhausted` so the TUI can surface the actionable
  "open System Settings → Privacy" recovery, not a generic "failed".
- **Heal markers vs session boundaries.** `gap < 30s` reuses the
  session and writes a `heal_marker` on the next segment; `≥ 30s`
  closes the current session as `interrupted` and opens a fresh one.
  The threshold matches the empirical "did the user step away from the
  meeting" intuition without making lid-close-for-a-minute (e.g., to
  switch rooms) chop the session.
- **Pause-state preservation is still load-bearing.** This PR does NOT
  introduce engine `paused` state — that arrives in U10 (PR #37). Until
  then, the U4 privacy invariant (a daemon restart never silently
  re-engages the mic) is preserved because U4's daemon-start path
  already checks the pause columns; the supervisors here only fire while
  the engine is already `recording`.

## Plan deviations (each captured in the relevant commit body)

- **U5** — heal-marker plumbed via `StoredSegment.healMarker` rather
  than a new repository overload. Minimal touch, existing call sites
  unchanged.
- **U6** — IOKit message constants hardcoded (`0xE0000270`, etc.) with
  inline comments because the Swift importer can't resolve the macros.
- **U7** — `MicrophoneAudioSource` deliberately does NOT conform to the
  `AudioSource` protocol. The existing engine site uses a `(buffers,
  format, stop)` tuple shape; conforming would have rippled through
  `RecordingEngine` for no benefit.
- **U8** — SDK constant `-3805` is
  `failedApplicationConnectionInterrupted` (not `connectionInvalid` as
  the plan listed). Both are retryable, so the behavioral outcome
  matches.

## Testing

- **U5**: backoff curve end-to-end (1s → 2s → 4s → 8s → cap 30s);
  same-error vs different-error counter behavior; reset gate (segment
  finalized AND 30s stable); cancellation during backoff (e.g. `stop`
  arrives mid-wait).
- **U6**: heal rule at `gap=12s same`, `45s same`, `10s diff-device`,
  boundary at exactly `30s`, `gap=0s`; willSleep cleanup unconditional
  even from `.error`; power-assertion ordering test (release strictly
  between willSleep entry/exit, after acquire); 50 in-flight segments
  drain before `IOAllowPowerChange`; mock IOKit observer fires synthetic
  `kIOMessageSystemWillSleep` / `HasPoweredOn`.
- **U7**: single notification → debounced 250ms; 3 notifications inside
  200ms collapse to 1; UID resolved at trailing edge;
  same-UID-same-format restart-only; format-only-change reuses session
  with marker; UID-differs rolls over; engine throws on `start()` after
  rebuild → falls into U5 backoff.
- **U8**: classifier table for every documented `SCStreamError`;
  `userDeclined` → `MIC_OR_SCREEN_PERMISSION_REVOKED` non-retryable; 5
  `systemStoppedStream` → surrender, mic unaffected; `attemptToStopStreamState`
  ignored; mic TCC revocation skips backoff loop; cancellation during
  backoff.

`[steno-tests-passed: 394 tests in 1.4s]` (304 Swift + 90 Go) per commit
attestation.

A pre-existing live-daemon Go test flake under parallel `make test`
exists (three tests in `internal/daemon/` assume `status=idle`, which
Cluster 1's auto-open invalidated). They skip cleanly when no daemon is
running; flagged for cleanup with the TUI changes in U9 / PR #37.

## What's Next

- **Cluster 3 (PR #36)** — U11 cross-source dedup background coordinator
  (uses the U2 schema fields `duplicate_of`, `dedup_method`,
  `last_deduped_segment_seq`) and U12 empty-session prune at close + the
  90-day retention guard.
- **Cluster 4 (PR #37)** — the user-facing payoff: U10 daemon
  `pause`/`resume`/`demarcate` with the wall-clock pause timer, and U9
  the TUI surface (spacebar = demarcate, `p` / `shift-p` for pause,
  full health surface). Cluster 4 finally adds `EngineStatus.paused`
  to the engine; until then, restored paused state across daemon restart
  leaves the engine `idle` (privacy invariant preserved by U4's
  daemon-start path).
