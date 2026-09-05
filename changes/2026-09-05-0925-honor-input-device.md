# Record from the device that was asked for

## Why

`{"cmd":"start","device":"..."}` has been in the protocol since the beginning, and the
daemon has never once acted on it. `MicrophoneAudioSource.start(device:)` accepted the
parameter, documented that AVAudioEngine "does not currently route to a specific device,"
and then built a plain `AVAudioEngine` — which captures from the system default input.

Two things follow from that, and the second is the real bug:

1. Picking a device does nothing. Every session records from whatever the system default
   happens to be.
2. It reports success anyway. `status` returns `recording: true` and level events flow,
   because the default input is genuinely producing audio. The session looks healthy while
   recording the wrong room.

`{"cmd":"devices"}` had the matching hole: `availableDevices()` returned `[]`, so the one
call a client would make to find out what it could ask for answered "nothing." A user
who picked a device in the TUI, saw it accepted, and watched levels move had no signal
anywhere that the choice was inert.

## How

Three pieces, in the order a start request moves through them.

**Enumerate.** `CoreAudioInputDeviceEnumerator` walks `kAudioHardwarePropertyDevices`,
keeps the devices with a non-zero input channel count on
`kAudioDevicePropertyStreamConfiguration`, and reads each one's UID and name. It sits
behind `AudioInputDeviceEnumerating` because Core Audio enumeration needs real hardware
and none of the logic above it should.

**Resolve.** `AudioInputDeviceResolver` turns a requested string into one of those
devices: exact name, then exact UID, then the case-insensitive forms of each. Resolution
happens *before* any engine state is touched, so a request that cannot be satisfied costs
an already-running capture nothing.

**Bind.** `AVAudioEngine` has no device selector; the AUHAL unit behind its input node
does. `inputNode.auAudioUnit.setDeviceID(_:)` points it at the resolved device, before
`prepare()` and before the format is read — the negotiated format belongs to whichever
device the unit is on, so reading it first would describe the default input and then tap
a different one.

Two smaller changes fall out of it:

`availableDevices()` is implemented, so `{"cmd":"devices"}` returns the machine's real
inputs with the default flagged.

And a silence watchdog: if a source that is supposed to be capturing delivers nothing but
digital silence for 30 seconds, the daemon says so (`audio_silent`, transient, on the
existing error channel) instead of sitting there reporting `recording: true`. That is the
same failure shape as the bug above — a session that looks fine and is not — and it is
the case the device fix cannot cover, because a correctly-bound device can still be muted,
unplugged into a dead dock, or routed somewhere with no signal.

## Key decisions

- **Fail the start; never silently substitute.** An unresolvable device throws
  `deviceNotFound`, naming the request and listing what is available. Falling back to the
  default input is what the old code did — that fallback *is* #104. A session recording
  from the wrong microphone while reporting success is worse than a session that refused
  to start, because only one of the two is discoverable.
- **Exact matching only — no substring, no prefix.** Convenience matching is how
  `"MacBook"` quietly selects `"MacBook Air Microphone"` on one machine and something else
  on another. The failure mode of exact matching is a clear error; the failure mode of
  fuzzy matching is the bug being fixed here, wearing a different hat.
- **A pinned session reports the pinned device's UID.** `RecordingEngine` restarts capture
  when the device UID changes, which is correct when following the system default and
  wrong when pinned: switching the *default* input should not disturb a session that
  explicitly asked for something else. `captureDeviceUID` resolves the request through the
  enumerator so the comparison is against the device actually in use.
- **The watchdog is a pure state machine.** Peak in, "warn after N consecutive silent
  ticks" out, no clock and no I/O — so the 30-second threshold is exercised in
  microseconds and the ten-hertz level cadence it rides on stays untouched.
- **Warn once per silent stretch, not once per tick.** It re-arms only after audio comes
  back, so a muted microphone produces one event rather than one every 100ms for as long
  as the mistake lasts.
- **`nil` device still means "follow the system default."** Every existing caller passes
  `nil` or omits it; none of them change behavior.

## Testing

`make test`: 735 tests, 0 failures — 498 daemon, 193 Go, 44 app. (The daemon and app
counts drift by one or two run to run; the harness's documented macOS 26 teardown abort
truncates the log before the final tally. `✘` count is 0 across runs.)

Covering, specifically:

- A resolvable name binds; the resolver prefers an exact name over an exact UID; matching
  is case-insensitive; a substring does **not** match.
- An unresolvable device throws `deviceNotFound` and the error message names both the
  request and the available devices — a start that fails should say what to ask for
  instead.
- The failed start leaves an in-flight capture alone, which is the point of resolving
  before touching engine state.
- A pinned session ignores a change to the system default input. This one was checked
  against a deliberately reverted fix: without `captureDeviceUID`, it fails.
- `availableDevices()` reports the enumerator's devices with exactly one flagged default,
  and reports an empty list without inventing one.
- The watchdog fires at the threshold and not before, once per silent stretch, re-arms
  after audio returns, and treats a peak exactly at the floor as silence.

**Not verified end-to-end on hardware.** Confirming that buffers actually flow *from* a
pinned device needs a running signed daemon, and any locally-built binary loses the
microphone grant — TCC keys the permission to the binary's cdhash and ad-hoc signing
changes it on every build. What was verified directly against this machine's Core Audio,
outside the test suite: enumeration returns the three real inputs with the correct default
flagged, and `setDeviceID` demonstrably moves the input unit (read back via
`AudioUnitGetProperty`, and `inputFormat(forBus:)` reports the pinned device's channel
count rather than the default's).

One environment note: `swift test` aborts at process teardown on this toolchain ("freed
pointer was not the last allocation"). It reproduces on a pristine `main` and is what the
Makefile's `test-daemon` target already documents and works around.

## What's next

The silence watchdog only watches the microphone. System audio has the same failure shape
and a different cause — ScreenCaptureKit can hand back a live stream of silence after a
display change — so it wants the same treatment once #102's recovery path settles.

`devices` returns name, UID, and default-ness. Sample rate and channel count are already
read during enumeration and thrown away; surfacing them would let a client warn before a
start rather than after.

Closes #104.
