# Remove legacy SFSpeechRecognizer permission check (PR #19)

## Why

#18 stripped the restricted `com.apple.developer.speech-recognition`
entitlement so the daemon could launch at all. But the daemon
immediately failed in a new, quieter way: every recording request
was rejected at the `PermissionService` layer with
`"Missing permissions: Speech recognition"`, even after the user
granted microphone access.

The cause: `SystemPermissionService` was still calling
`SFSpeechRecognizer.authorizationStatus()` from the legacy
`Speech` framework to gate recording. Two problems with that call
in the post-#18 world:

1. **The entitlement that backs it is gone.** Without
   `com.apple.developer.speech-recognition`, the TCC database has
   no record of a "speech recognition" grant for this binary, so
   the API returns `.notDetermined` (which we mapped to "denied")
   forever, regardless of what the user does in System Settings.
2. **`SpeechAnalyzer` doesn't need it anyway.** Per the rule
   established in #14 and reinforced in #18: macOS 26
   `SpeechAnalyzer` is on a separate authorization path —
   microphone access is the only TCC grant that actually matters.
   The `SFSpeechRecognizer` authorization gate is a vestige of
   the legacy API and is irrelevant to our pipeline.

This PR removes the check entirely, which is the correct fix —
not "make it lenient", not "always return granted", but "don't ask
about a permission that no longer applies to our code path."

## How

Surgical removal across three files.

### `PermissionStatus` — drop the `speechRecognitionGranted` field

```swift
public struct PermissionStatus: Sendable, Equatable {
    public let microphoneGranted: Bool
    public var allGranted: Bool { microphoneGranted }
    public var errorMessage: String? {
        microphoneGranted ? nil : "Missing permissions: Microphone access"
    }
    // ...
}
```

The struct now reflects what actually matters: did the user grant
microphone access?

### `PermissionService` protocol — drop `requestSpeechRecognitionAccess()`

This method had a single in-tree call site (a TUI-era code path
that no longer exists) and was unused by the daemon. Removing it
prevents a future caller from trying to "request" a permission
that macOS 26 won't actually grant.

### `SystemPermissionService` — drop `import Speech` and the `SFSpeechRecognizer` calls

```swift
public func checkPermissions() async -> PermissionStatus {
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    return PermissionStatus(microphoneGranted: micStatus == .authorized)
}
```

The implementation now only touches `AVCaptureDevice`. The
`import Speech` line is gone — there's no remaining reason for
the daemon's permission layer to depend on the legacy framework.

### `MockPermissionService` — drop the matching test scaffolding

The mock loses its `speechRecognitionRequested` tracking flag and
`requestSpeechRecognitionAccess()` stub. All daemon tests still
pass; the affected test (`permissionDeniedThrows`) just relies on
`microphoneGranted = false` to exercise the denial path.

## Key Decisions

- **Delete the check, don't soften it.** A tempting alternative
  was to make the speech-recognition check non-fatal — log a
  warning, continue anyway. That would be wrong for two reasons:
  (a) it would leave a confusing log line on every start, and (b)
  it would imply that someday we might want to re-enable the
  check, which we never will. The legacy API path is closed
  forever (per CLAUDE.md anti-pattern); the legacy permission
  query goes with it.
- **Also remove `requestSpeechRecognitionAccess()`, not just the
  passive check.** Leaving the request method in the protocol
  would invite a future caller to prompt the user for a permission
  that macOS 26 can't grant against an ad-hoc-signed CLI binary —
  the user would see no system dialog, the call would resolve to
  `.notDetermined`, and we'd be back here debugging a phantom
  permission.
- **No new tests for the removal.** The removal is provable by the
  existing test suite continuing to pass with the field gone —
  any test that relied on `speechRecognitionGranted: false` to
  trigger a denial path is now exercised via `microphoneGranted:
  false`. Adding tests for the absence of a permission check
  would be tautological.
- **`import Speech` deletion matters for clarity.** Even though it
  has no runtime cost, keeping the import around would suggest to
  future readers that the daemon still has a legacy-Speech code
  path. It doesn't, and grep should confirm that.

## Testing

- All 343 tests pass (169 daemon + 37 TUI + 137 legacy)
- The previously failing `permissionDeniedThrows` test still
  exercises the denial path via microphone-only state
- Manual: `make run-daemon` + press Space in TUI now starts
  recording without the false "Missing permissions" error

[steno-tests-passed: 343 tests (169 daemon + 37 TUI + 137 legacy)]

## What's Next

After this PR, the daemon launches (post-#18), passes its
permission check (post-#19), and begins feeding audio buffers
into the recognizer pipeline. The next bug — a fresh SIGTRAP from
inside the pipeline itself, caused by a 48kHz/16kHz format
mismatch and incorrect task ordering around the blocking
`analyzer.start()` call — is fixed in #20.

The daemon's permission model is now stable for the macOS 26
SpeechAnalyzer era: microphone, plus (for the system-audio path)
screen-recording TCC, plus the three signing-entitlement keys
from #18. Nothing else.
