# Fix Level Meters and Source Type Labeling (PR #21)

## Why

Two visible bugs in the freshly-stable daemon + Go TUI architecture:

1. **The audio level meters never moved.** The TUI rendered the green/yellow
   meter row at the top of the screen, but the bars sat at zero no matter
   how loud the input was. The daemon had fields for level tracking but
   never actually computed peak amplitude or emitted `level` events to
   subscribers — the event type was wired up end-to-end on paper, but no
   data ever flowed across it.

2. **Every transcript segment was labeled `[MIC]`.** With system audio
   capture working (PR #14), the TUI was supposed to show `[SYS]` for
   segments coming from ScreenCaptureKit, but the source field was
   hardcoded to `.microphone` in `DefaultSpeechRecognizerFactory`. The
   recognizer didn't know which audio source was feeding it, so it
   labeled everything as mic.

Both were polish-tier issues, but they made the dual-source feature feel
broken: identical labels and dead meters undermined the whole point of
adding system audio in the first place.

## How

### Level meters: tapped buffer stream + 10Hz throttle

Inside `RecordingEngine`, the audio buffer flow used to be:

```
AudioSource → SpeechRecognizer
```

PR #21 inserts a tap that observes each buffer in transit:

```
AudioSource → peakAmplitude(buffer) → SpeechRecognizer
                       │
                       └─→ levelTracker (per source)
```

A separate `Task` runs at 10Hz, reads the latest peak for each source
(`mic`, `sys`), and emits a single `level` event to subscribers:

```json
{"event":"level","mic":0.42,"sys":0.15}
```

10Hz is fast enough for smooth visual animation without flooding the
event stream. The throttle is a sleep loop, not a timer source — keeps
the implementation portable across actor contexts.

### Source labels: thread `source` through the factory

`SpeechRecognizerFactory.makeRecognizer()` gained a `source: AudioSourceType`
parameter:

```swift
protocol SpeechRecognizerFactory: Sendable {
    func makeRecognizer(locale: Locale,
                        format: AVAudioFormat,
                        source: AudioSourceType)
        async throws -> SpeechRecognizerHandle
}
```

`RecordingEngine` now passes `.microphone` when creating the mic
recognizer and `.systemAudio` when creating the system-audio recognizer.
The handle carries the source through to its emitted segments, so the
wire-protocol `source` field reflects reality and the TUI's `[MIC]` /
`[SYS]` labels (added in PR #12) finally work.

## Key Decisions

- **Tap inside `RecordingEngine`, not inside each `AudioSource`** — keeps
  level computation in one place, doesn't require every audio-source
  implementation to redo peak math, and makes mocking trivial in tests.
- **10Hz throttle, not per-buffer emission** — buffers arrive at ~93Hz
  (1024 frames / 48kHz). Emitting a level event per buffer would saturate
  the socket and beat the TUI's render budget for no perceived benefit.
- **`AudioSourceType` enum threaded through the factory protocol, not
  inferred from format or device name** — the engine already knows
  which source it's wiring up; making it explicit is one parameter and
  removes any chance of mislabeling drifting between layers.
- **MockSpeechRecognizerFactory updated to record the `source` it
  receives** — lets tests assert that the engine passes the right value
  per recognizer.

## Testing

[steno-tests-passed: 169 tests in 0.7s]

- Existing engine tests pass after the protocol change.
- Mock factory now records source per recognizer creation, enabling
  assertions in dual-source tests (groundwork that PR #23 leans on).

## What's Next

- The level event is emitted but the daemon doesn't yet handle the
  case where mic and system audio peaks arrive on different
  ticks — addressed implicitly by the per-source partial bookkeeping
  in PR #23.
- Consider an RMS or LUFS variant for level meters if peak proves too
  twitchy in practice. Current peak amplitude is fine for the bar UI.
