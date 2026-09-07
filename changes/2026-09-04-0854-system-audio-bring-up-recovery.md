# System audio survives a lid close/open cycle

## Why

Close the laptop lid, open it again, and system audio is gone for the rest of the
session. The microphone keeps transcribing, status still reports system audio as
enabled, and the `sys` level meter sits at zero until the user stops and starts
recording by hand.

The mic surviving the same lid cycle is what makes this specific rather than
"audio broke". Both pipelines see the same interruption; only one of them comes
back.

## What was wrong

Two defects on the same path, and it takes both to produce the symptom.

### 1. The bring-up threw away the error it needed to classify

This project already has a good answer to "what does this ScreenCaptureKit
failure mean": `SystemAudioErrorClassifier.classify(_:)`, which dispatches on the
SCStream domain and code into `.ignore` / `.retry` / `.permissionRevoked` /
`.parkUntilDisplay`. The `SCStreamDelegate` path uses it, and the `-3815
noCaptureSource` → park mapping added for #42 is right there in the table.

`SystemAudioSource.start()` destroyed the inputs that classifier runs on:

```swift
do {
    content = try await SCShareableContent.current
} catch {
    throw SystemAudioError.permissionDenied     // ← ANY failure
}
...
do {
    try await scStream.startCapture()
} catch {
    cleanup()
    throw SystemAudioError.streamStartFailed(error.localizedDescription)  // ← domain and code gone
}
```

Both throws are plain Swift enums, whose `NSError` domain is a mangled type name,
so `classify(_:)` failed its `guard ns.domain == scStreamErrorDomain` and fell
through to the default. The delegate and the bring-up disagreed about the same
ScreenCaptureKit fault: `-3815` meant "park and wait for a display" arriving from
one and "unknown, retry" arriving from the other.

The `SCShareableContent` mapping is the more damaging of the two. A display that
has not finished waking is not a revoked TCC grant, but the code said it was.

### 2. The bring-up had no recovery at all

`RecordingEngine.startSystemAudio(locale:)` named exactly one failure:

```swift
} catch SystemAudioError.noDisplaysAvailable {
    systemAudioSource = nil
    await parkSystemPipelineUntilDisplay(reason: "...")
} catch {
    await emit(.error("System audio failed: \(error)", isTransient: true))
}
```

Everything else emitted a transient error and returned, which left the pipeline
unrecoverable rather than merely broken:

- `sysParkedAwaitingDisplay` is cleared eagerly at the *top* of the bring-up, so
  a display event arriving mid-bring-up can't double-fire. A failure after that
  point leaves it `false`.
- `handleDisplayBecameAvailable()` opens with
  `guard sysParkedAwaitingDisplay else { return }`. With the flag cleared, a
  display coming back is a no-op. The one observer that exists for this situation
  cannot see it.
- No `sysRestartTask` was scheduled, so the bounded backoff never engaged either.

Nothing was waiting and nothing was retrying, while `isSystemAudioEnabled` stayed
`true`.

`restartSystemPipeline` had already learned this. Its generic catch grew an
explicit reschedule during the PR #35 review (issue 4), with a comment noting
that without one "the system pipeline stays stuck after a rebuild throw". The
bring-up path was not updated at the same time.

### How they combine

Lid-close is fine. The display list empties, `SCShareableContent` succeeds and
returns zero displays, the typed `noDisplaysAvailable` is thrown, and the #42 park
does its job.

Lid-open is where it dies. `handleDisplayBecameAvailable()` re-arms into
`startSystemAudio`, which clears the park flag on entry and then fails, because
the display is still settling. Depending on which call loses the race, that
failure was reported as `permissionDenied` or as a `streamStartFailed` string,
both of which landed in the bare catch. The park flag was already gone, so no
later display event could rescue it.

## How

**Preserve the error.** `SystemAudioError` gains a case that carries the
ScreenCaptureKit error verbatim, plus which call produced it:

```swift
case captureFailed(stage: CaptureStage, underlying: NSError)
```

Both bring-up failure sites now throw that instead of flattening. The
zero-displays guard still throws the typed `noDisplaysAvailable`, because that one
is a condition this code synthesizes rather than an error SCK reported.

**Unwrap it in one place.** `classify(_:)` and `backoffKey(for:)` both route
through a private `underlyingError(_:)`. A wrapped bring-up failure and a raw
delegate callback now produce the same action *and* the same backoff bucket, so
"same error five times" tracking doesn't silently split in two.

**Route the bring-up like every other failure.** The generic catch calls
`handleSystemAudioBringUpFailure(_:)`, which switches on the classification:
`.parkUntilDisplay` parks, `.permissionRevoked` surfaces the load-bearing
`MIC_OR_SCREEN_PERMISSION_REVOKED` token, and `.retry` goes through the existing
bounded `scheduleSysRestart`, surrendering to `.recoveryExhausted` + `.error` when
the budget is spent.

**Use one backoff key function.** The engine's `errorCode(for:)` did its own
`error as NSError`, so it did not unwrap. Left alone, every `.captureFailed`
would have collapsed onto a single key — the mangled enum type name, code 0 — and
`BackoffPolicy` would have been unable to tell one SCStream code from another,
while the same physical fault counted in one bucket from bring-up and a different
one from the delegate. `errorCode(for:)` now delegates to
`SystemAudioErrorClassifier.backoffKey(for:)`. Unwrapped errors pass through with
identical `domain#code` behaviour, so the mic path is unchanged.

**Stop `bringUpPipelines` from overwriting a surrender.** The bring-up ends with
`setStatus(.recording)`, unconditionally. `handleSystemAudioPermissionRevoked()`
runs *inline*, so its `.error` was set and then immediately overwritten — leaving
the engine reporting `.recording` with the sys pipeline torn down and no observer
able to re-arm it, which is the exact state this change exists to prevent. It is
newly reachable, because before this PR the bare catch never called that handler.
The final `setStatus` now carries the same `status == .error` guard that
`maybeRestoreRecordingStatus` already had.

## Key decisions

- **The fix belongs in the source, not only in the engine.** An engine-only
  version — adding classifier routing to the catch and leaving the mapping alone —
  compiles, passes tests that inject a raw `NSError`, and does nothing in
  production, because the source can never emit that shape. The `.parkUntilDisplay`
  arm would have been dead code on the path it was written for.
- **`.ignore` becomes a retry at bring-up.** On the delegate path, `.ignore`
  (`attemptToStopStreamState`) means a stream stopped for a reason we caused and
  the pipeline is otherwise intact. At bring-up there is no working source at
  all, so disregarding it would leave exactly the dead-but-enabled pipeline this
  change exists to prevent.
- **Teardown stays with the handlers.** The failure handler deliberately does not
  nil `systemAudioSource` before delegating. `parkSystemPipelineUntilDisplay`,
  `handleSystemAudioPermissionRevoked` and `restartSystemPipeline` each stop the
  source first; clearing it early would turn those into no-ops and strand a
  partially-constructed `SCStream`.
- **Bounded retry, not unbounded.** A bring-up failure draws on the same
  `sysBackoff` budget as a mid-session failure rather than getting a fresh
  infinite one.
- **Scope kept to recovery.** Status reporting `systemAudio: true` while the sys
  pipeline is parked, retrying or exhausted is a real and separate problem — it is
  what turns this bug from visible into silent — but fixing it touches the
  protocol and the TUI. Filed separately.

## Testing

`SystemAudioStartFailureTests.swift` (7 tests) covers the engine path:

- `-3815` at bring-up parks the sys pipeline, leaves the mic recording, and burns
  no backoff
- a parked bring-up is re-armed by a subsequent `displayBecameAvailable()`, which
  is the lid-open path end to end
- a transient failure schedules a bounded retry, and that retry rebuilds once
  `start()` succeeds again
- a transient *display-enumeration* failure retries and recovers, and is never
  reported as a revoked grant — the direct regression guard on the old
  `permissionDenied` catch-all
- a genuine `userDeclined`, and a source reporting `.permissionDenied`, both
  surface `MIC_OR_SCREEN_PERMISSION_REVOKED` without burning backoff, and the
  resulting `.error` survives to the end of bring-up

Four tests added to the existing `SystemAudioErrorClassifier (U8)` suite pin the
wrapping contract: a wrapped error and the raw error it carries classify
identically and share a backoff key, and unwrapping does not bypass the domain
gate.

Errors are injected in the shape the real source produces rather than as raw
`NSError`s, so the tests exercise the path production actually takes. Backoff is
asserted through the injected-sleep harness rather than by waiting.

One honest limitation: `MockAudioSource` throws what it is handed, so these tests
pin the *engine's* handling of a wrapped error, not `SystemAudioSource.start()`'s
decision to wrap it. `SCShareableContent.current` has no injection seam, so that
half is covered by the classifier's wrapped-vs-raw agreement tests and by review,
not by an executable test.

[steno-tests-passed: 489 tests in 22s]

## What's next

- Status should not report system audio as enabled while the pipeline is parked,
  retrying, or exhausted.
- The daemon test harness aborts during process teardown (the known
  "freed pointer was not the last allocation" race the Makefile documents), which
  truncates the tail of the result stream. `swift test --list-tests` declares 522
  tests; observed pass counts across consecutive clean runs ranged from 477 to
  490, all with zero failures. The Makefile's "at least one pass, zero failures"
  gate therefore proves "nothing that reported, failed" rather than "everything
  passed". Worth hardening separately.
- `SystemAudioSource` has no seam for injecting `SCShareableContent`, so its
  error-wrapping cannot be tested directly.
- `streamStartFailed("Failed to create audio format")` is still a synthesized
  string failure that will classify as a retry and burn the budget before
  surrendering. Rare, and out of scope here.

## Review follow-up

The scheduled rebuild now uses the same error classification as initial
bring-up. A wrapped missing-display error parks and re-arms on a display event;
a wrapped permission denial surfaces the revoked token without further retries.
Two regression tests failed before this correction and pass after it.
