# Park system audio on -3815 instead of burning bounded backoff (PR #43)

## Why

U8 (PR #35, part of the always-on-recording effort) added bounded-backoff
recovery for `SCStream` errors — a 1s/2s/4s/8s/30s curve that surrenders
to `recoveryExhausted` after ~45s. The curve is the right shape for
*transient* errors. It is the wrong shape for **stimulus-driven** errors
that stay broken until the user does something physical to the machine.

`SCStreamError.noCaptureSource` (raw value `-3815`) is the canonical
stimulus-driven case: ScreenCaptureKit raises it when there's no
display available to capture from. That happens on lid-close with an
external-monitor-only setup, monitor unplug, and certain audio-device
swaps. None of those clear themselves on a backoff timer — they clear
when a display comes back online.

The user-visible symptom was clusters of `recovery_exhausted:
scstream:...#-3815` and `recovery_exhausted: rebuild:SystemAudioError
error 0` lines around lid-open/close and monitor plug/unplug — even
though the mic pipeline kept transcribing and the recording was
conceptually fine. The "fix" the user kept reaching for (restart the
daemon) didn't help: the new process re-threw `noDisplaysAvailable`
immediately, because the display was still gone.

PR #42 was the first attempt at this fix; it was closed in favor of
#43 after Copilot review (commit `f4ec1a2` in this PR addresses those
threads — see "Review follow-up" below).

## How

Treat "no display" as a parked state, not a transient retry. The same
observer-driven re-arm pattern U7 already uses for audio-device changes
applies cleanly:

**Classifier.** Added `.parkUntilDisplay` to `SCStreamRecoveryAction`
and routed `SCStreamError.noCaptureSource.rawValue` (-3815) there
instead of `.retry`. Other SCStream codes (-3801, -3804, -3805, -3808,
-3821) keep their existing `.retry` routes.

**Source dispatch.** `SystemAudioSource.dispatchDelegateError` for
`.parkUntilDisplay` tears down local refs and calls the new
`SystemAudioRecoveryDelegate.systemAudioParkedUntilDisplay(reason:)`.
Parking intentionally bypasses `BackoffPolicy.record(error:)`.

**Engine.** New `parkSystemPipelineUntilDisplay(reason:)` helper
cancels the in-flight sys restart, tears the sys pipeline down,
rebuilds `sysBackoff` (so the eventual re-arm has a fresh budget),
flips `sysParkedAwaitingDisplay = true`, and emits a *transient*
`.error` carrying the load-bearing `SYSTEM_AUDIO_PARKED_NO_DISPLAY`
token. Status stays at `.recording` — mic keeps capturing throughout.
`restartSystemPipeline`'s rebuild catch and `startSystemAudio`'s
initial catch both route `SystemAudioError.noDisplaysAvailable` into
this helper instead of advancing the backoff or surrendering.

**DisplayObserver.** New `Infrastructure/DisplayObserver.swift`
modeled on `AudioDeviceObserver`. Backed by
`CGDisplayRegisterReconfigurationCallback` (works in headless CLI —
`NSApplication.didChangeScreenParametersNotification` would not fire
without AppKit). 250ms trailing-edge debounce collapses CG's paired
begin/complete callbacks plus auto-detect-and-extend bursts. A
`displayPresenceProvider` gates the trailing edge so detach-only
events don't re-arm.

**Engine ↔ observer wiring.** `RecordingEngine` conforms to
`DisplayEventTarget`. `handleDisplayBecameAvailable()` re-arms the sys
pipeline iff parked, mic-attached, and not in a non-recovering terminal
state. `RunCommand` registers the observer alongside the existing
power and audio-device observers at daemon startup and tears it down
on shutdown.

**TUI.** A new `systemAudioParked bool` on the Go `Model`, set when an
`error` event has the `SYSTEM_AUDIO_PARKED_NO_DISPLAY` token prefix
(transient — does NOT enter the error-history ring buffer), cleared on
`recovering:display:available`, `recovery_exhausted:*`, and pause.
When `systemAudio && systemAudioParked`, the header chip renders
`[MIC + SYS — waiting for display]` in `ui.PausedStyle` so the user
can see at a glance that sys-audio is parked while mic continues.

## Key Decisions

- **Parking is a transient `.error`, not `recoveryExhausted`.** This
  preserves the existing surrender surface (`MIC_OR_SCREEN_PERMISSION_REVOKED`
  → `recoveryExhausted`) for genuinely non-recoverable conditions
  while giving the TUI a distinct "waiting for display" indicator.
- **No backoff key for `.parkUntilDisplay`.** Parking bypasses
  `BackoffPolicy.record(error:)` entirely. The reason string still
  embeds the `domain#code` payload for diagnostics, but no slot in
  the backoff curve gets consumed — so a parked-then-re-armed
  pipeline starts with a fresh budget if it later hits a *real*
  transient error.
- **Mic is untouched.** Parking is per-pipeline. The mic source keeps
  capturing through display events, lid-close, and monitor swaps.
  That's the whole point of the bounded-backoff carve-out: don't let
  one pipeline's recoverable state break the other.
- **`CGDisplayRegisterReconfigurationCallback`, not AppKit notifications.**
  The daemon is a headless CLI with no `NSApplication`. CG's reconfig
  callback fires correctly without AppKit; the AppKit notification
  would not.

## Review follow-up

Commit `f4ec1a2` resolves four Copilot threads:

1. Captured the `CGError` return from
   `CGDisplayRegisterReconfigurationCallback` (was previously ignored
   — silent registration failures are now logged to stderr, with a
   `subscribeThrowing(handler:)` variant for callers that want to
   fail loudly).
2. Reworded the misleading "No backoff key" comment in
   `SystemAudioSource` — parking does compute a backoff key for the
   reason string, but bypasses `BackoffPolicy.record`.
3. Refactored the global handler slot in `_DisplayReconfigState.shared`
   to per-subscriber state via an unretained opaque pointer on
   `userInfo`. Two subscribers in the same process now coexist.
4. Wired `SYSTEM_AUDIO_PARKED_NO_DISPLAY` into the TUI — the engine
   was emitting it but no Go-side code matched. Added the chip
   annotation and seven TUI tests.

## Testing

`[steno-tests-passed: 509 tests in 9s]`

- **Classifier**: the existing `-3815 → .retry` test flipped to
  `-3815 → .parkUntilDisplay`. Other code mappings unchanged.
- **Source dispatch**: new test asserts `-3815` invokes
  `systemAudioParkedUntilDisplay(reason:)` and not the retry or
  permission paths.
- **Engine** (`DisplayParkRecoveryTests`): park-not-exhaust, six
  consecutive park events (vs U5's surrender on the 6th `.retry`),
  re-arm on `displayBecameAvailable()`, no-op when not parked,
  rebuild throw → park, `userDeclined` still surrenders (U8 doesn't
  regress), `stop()` clears the flag.
- **Observer** (`DisplayObserverTests`): single-fire, presence
  gating, detach-then-attach (only attach fires), burst collapsing,
  `stop()` detaches, in-flight debounce cancellation, idempotent
  `start()`.
- **TUI**: seven tests for the parked flag, chip render gating,
  recovering/exhausted/pause clears, regression guard for unrelated
  recovering events.

## What's Next

- The same observer-driven re-arm pattern could apply to other
  stimulus-driven SCStream codes if they show up in real use. Today
  only `-3815` is routed to `.parkUntilDisplay`; expanding the set
  is a one-line classifier change.
- Consider a similar "park" path for the mic pipeline if a comparable
  stimulus-driven mic error code surfaces.
