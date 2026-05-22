# Remove restricted speech-recognition entitlement that causes SIGKILL (PR #18)

## Why

After #14 fixed the SIGTRAP, the daemon could in principle start —
but on machines signing with anything beyond ad-hoc, or when running
under certain TCC states, the daemon was killed by the kernel
**before** any Swift code in `RunCommand.run()` even ran. Exit code
was `9` (`SIGKILL`), no crash log, no Swift backtrace — just an
immediate, silent termination by AMFI (Apple Mobile File Integrity).

The cause is a class of macOS entitlement that bare CLI binaries
cannot legally carry:

- `com.apple.developer.speech-recognition` is a **restricted
  entitlement**. To use it, the binary must be signed against a
  provisioning profile that lists the entitlement in its
  `com.apple.developer.team-identifier`-scoped allow-list.
- **Provisioning profiles can only be embedded in app bundles**
  (specifically, at `Contents/embedded.provisionprofile`). A plain
  CLI executable has nowhere to put one.
- At launch, AMFI checks every restricted entitlement against the
  binary's embedded profile. No profile, no match, SIGKILL — with
  no opportunity for the process to log anything.

We had inherited this entitlement from the monolithic
`Steno.entitlements` file from the SwiftTUI days. It was never
actually required: **macOS 26 `SpeechAnalyzer` does not need
`com.apple.developer.speech-recognition`.** The entitlement is only
relevant to the legacy `SFSpeechRecognizer` API path, which the
project doesn't use anymore (and per the anti-pattern added in #14,
never will again).

The lesson: this entitlement was a load-bearing booby trap that did
nothing useful and killed the daemon dead. This file is the canonical
writeup of that lesson — read it before touching daemon entitlements.

## How

Three coordinated changes.

### 1. Strip the restricted entitlement from both entitlement files

```diff
 <dict>
     <key>com.apple.security.device.audio-input</key>
     <true/>
-    <key>com.apple.developer.speech-recognition</key>
-    <true/>
     <key>com.apple.security.cs.disable-library-validation</key>
     <true/>
     <key>com.apple.security.cs.allow-jit</key>
     <true/>
 </dict>
```

Applied to both `daemon/Resources/StenoDaemon.entitlements` (the
daemon's signing input) and `Resources/Steno.entitlements` (the
legacy monolith's, still present at this point for the old TUI).

### 2. Make the codesign identity configurable, default to ad-hoc

Apple Development certificates also trigger provisioning-profile
validation that fails for non-bundled CLIs. Ad-hoc signing
(`codesign --sign -`) is the correct identity for a CLI binary —
it grants the entitlements without dragging in the profile check.

The Makefile previously hard-coded `--sign -`. It now reads
`CODESIGN_IDENTITY` (defaulting to `-`), so CI or contributors with
Developer ID certificates can override only if they know what they're
doing:

```make
# Signing — ad-hoc is correct for local CLI use. Apple Development
# certificates trigger provisioning profile validation which fails
# for bare CLI binaries (no bundle to embed a profile in).
CODESIGN_IDENTITY ?= -
```

### 3. Document the rule in `CLAUDE.md`

Added to the build section:

> **Do NOT use `com.apple.developer.speech-recognition`** — it's a
> restricted entitlement that requires a provisioning profile. CLI
> binaries can't embed profiles, so AMFI kills the process
> (SIGKILL). macOS 26 SpeechAnalyzer does not need this entitlement.

## Key Decisions

- **The working entitlement recipe for the daemon is exactly three
  keys:** `com.apple.security.device.audio-input`,
  `com.apple.security.cs.disable-library-validation`,
  `com.apple.security.cs.allow-jit`. That's it. Adding anything else
  from the "speech" or "developer" namespaces is almost certainly a
  restricted entitlement and will SIGKILL the daemon.
- **Ad-hoc signing is correct, not a workaround.** This is not a
  shortcut around "real" signing — for a CLI binary on macOS 26
  with the modern SpeechAnalyzer API, ad-hoc is the right answer.
  Apple Development / Developer ID identities cause the binary to
  be inspected for a provisioning profile it can't carry. The new
  `CODESIGN_IDENTITY` Makefile variable exists as an escape hatch
  for a future bundled-app build, not as guidance for the daemon.
- **Never quiet a SIGKILL by guessing.** When the daemon died with
  exit code 9 and no logs, the temptation was to flip individual
  entitlements off and retry. Don't do that — read the
  `provisioning-profile-required` section in Apple's "Bundle
  Resources > Entitlements" reference and treat any flagged
  entitlement as restricted unless proven otherwise.
- **Companion fix is in #19.** After this PR, the daemon launches
  without SIGKILL, but recording is still blocked by a leftover
  `SFSpeechRecognizer.authorizationStatus()` check in
  `SystemPermissionService` that returns `notDetermined` now that
  the entitlement is gone. #19 removes that check.

## Testing

- All 343 tests pass (169 daemon + 37 TUI + 137 legacy)
- Manual smoke test: `make run-daemon` starts successfully — was
  exit code 9 before. Daemon listens on the socket and shuts down
  cleanly on SIGTERM.
- Daemon binary is verified to have only the three required keys
  via `codesign -d --entitlements - bin/steno-daemon`

[steno-tests-passed: 343 tests (169 daemon + 37 TUI + 137 legacy)]

## What's Next

- #19 removes the now-broken `SFSpeechRecognizer` permission check
  that this PR's entitlement removal silently disables (the call
  starts returning `notDetermined`, making `checkPermissions()`
  always report "speech recognition denied").
- #20 fixes a remaining SIGTRAP that surfaces once the daemon
  actually starts feeding audio buffers — separate from the
  entitlement issue, but on the same critical path to working
  transcription.
- Long-term: when we eventually bundle `steno-daemon` inside an app
  for distribution, we can reconsider Developer ID signing. Until
  then, ad-hoc is the only option that works.
