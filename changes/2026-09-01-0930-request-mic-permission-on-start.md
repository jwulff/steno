# Request microphone permission on start instead of failing without prompting

## Why

On a fresh install the daemon could never record. `RecordingEngine`'s
start paths (both explicit `start()` and the auto-start restore path)
gated on `permissionService.checkPermissions()`, which maps
`AVCaptureDevice.authorizationStatus(for: .audio)` to a boolean. On a
machine that has never been asked, that status is `.notDetermined` —
not `.authorized` — so the gate failed with
`Missing permissions: Microphone access` and the engine parked in
`.error`.

Nothing anywhere in the daemon called
`PermissionService.requestMicrophoneAccess()`. The protocol had the
method, `SystemPermissionService` implemented it, the mock tracked it —
but no production code path invoked it. macOS therefore never showed
the TCC prompt, `steno-daemon` never appeared under System Settings →
Privacy & Security → Microphone, and `tccutil reset Microphone
com.steno.daemon` reported no such bundle because TCC had no record of
the app at all. The user saw `✗ FAILED — see error` in the TUI with no
way to grant access.

This bites hardest in the recommended setup: `steno-daemon install`
runs the daemon under launchd, where there is no terminal session to
inherit permission from, so the daemon's own TCC identity is the only
one that matters.

## How

A single new gate, used by both start paths:

```swift
private func ensureMicrophonePermission() async throws {
    let permissions = await permissionService.checkPermissions()
    if permissions.allGranted { return }
    if await permissionService.requestMicrophoneAccess() { return }
    await setStatus(.error)
    let message = permissions.errorMessage ?? "Permissions denied"
    await emit(.error(message, isTransient: false))
    throw RecordingEngineError.permissionDenied(message)
}
```

`AVCaptureDevice.requestAccess(for: .audio)` does the right thing in
every state: prompts and waits when undetermined, returns the recorded
answer immediately when already granted or denied. So the undetermined
case now shows the system prompt, and the previously-denied case fails
exactly as before — a fast, non-transient `.error` the user resolves in
System Settings.

Both call sites (`start()` and the restore path) replace their
duplicated check-and-throw blocks with `try await
ensureMicrophonePermission()`.

## Key Decisions

- **Request at start, not at daemon launch.** The prompt appears when
  the user first tries to record — the moment they have context for
  why the app wants the mic — rather than as a surprise at login when
  launchd brings the daemon up.
- **No change to `PermissionService`.** The protocol already modeled
  request-vs-check correctly; the bug was that the engine only ever
  used half of it.
- **Keep the error message and event shape identical** for the true
  denial case, so the TUI's existing error surface is untouched.

## Testing

- New `startRequestsMicAccessWhenNotYetGranted`: check reports
  not-granted, request returns true → engine must request and proceed
  to `.recording`. (RED before the fix: threw `permissionDenied`
  without ever calling request.)
- Extended `permissionDeniedThrows`: still throws and parks in
  `.error`, and now also asserts the engine actually asked before
  giving up.
- Full suite passes (daemon + steno).

## What's Next

Nothing pending. The TUI already renders the non-transient error for
the denied case; a future nicety could be a dedicated hint pointing at
System Settings → Privacy & Security → Microphone.
