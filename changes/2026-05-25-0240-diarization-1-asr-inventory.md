# Diarization 1/8 — ASR Path Inventory (issue #55)

Investigation-only. No runtime code changed. This records the findings that
work item §6.1 of the diarization epic (#53) asked for: confirm the ASR
backend and verify whether transcript-segment timestamps can serve as the
join key for the deferred diarization layer (Layer B).

## Why

The diarization plan (#53) backfills speaker labels onto the live transcript
by intersecting **diarized audio windows** (cut from a raw-PCM ring buffer at
frame-accurate offsets) with **transcript segments** by timestamp. Before
building any of that, we need to know (a) that the ASR layer is the Apple
`SpeechAnalyzer`/`SpeechTranscriber` stack the plan assumes, and (b) that the
timestamps we'd join on actually line up with audio time. (b) turned out to
be the load-bearing finding.

## Findings

### ASR backend — pure Apple, no legacy (PASS)

- Transcription is exclusively macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`.
  No `SFSpeechRecognizer` / `SFSpeechAudioBufferRecognitionRequest` exists
  anywhere, including fallback paths.
  - `Engine/DefaultSpeechRecognizerFactory.swift:35-43` — `SpeechTranscriber`
    built with `reportingOptions: [.volatileResults]`, composed into
    `SpeechAnalyzer(modules: [transcriber])`.
  - `analyzer.start()` runs inside `Task { @MainActor in ... }`
    (`DefaultSpeechRecognizerFactory.swift:148-152`); the daemon keeps the main
    RunLoop alive with `dispatchMain()` (`Commands/RunCommand.swift`).
- DI is protocol-first: `SpeechRecognizerFactory`
  (`Engine/SpeechRecognizerFactory.swift:37`) →
  `DefaultSpeechRecognizerFactory`, injected into `RecordingEngine` at
  `Commands/RunCommand.swift:74`.
- **No availability/asset gating today.** The only runtime gate is a macOS
  26.0 version check (`Infrastructure/MacOSVersionGate.swift:29`). There is no
  `SpeechTranscriber.isAvailable`, supported-locale, or model-download check —
  confirming the runtime-gate work (§6.8 / #62) is genuinely net-new, not
  already present.

Conclusion: the §6.1 migration branch is a no-op. The ASR layer already meets
the plan's hard constraint. Keep it as-is; preserve the existing
NDJSON/SQLite output contract.

### Audio path — the tee point already exists (informs #56)

- `AudioSource` delivers audio as `AsyncStream<AVAudioPCMBuffer>`
  (`Audio/AudioSource.swift`). Mic uses an `AVAudioEngine` tap at the device's
  native format; system audio uses ScreenCaptureKit at a hardcoded 48 kHz
  stereo Float32 (`Audio/SystemAudioSource.swift`).
- Mic and system audio are transcribed by **separate recognizer instances**,
  each tagged with `AudioSourceType` (`.microphone` / `.systemAudio`).
- `RecordingEngine.tappedStream()` (`Engine/RecordingEngine.swift:1466-1490`)
  already tees each source stream to compute peak levels in transit before
  handing buffers to the recognizer. **This is the exact, clean insertion
  point for the diarization ring buffer (#56)** — extend it to fan out to a
  second sink. `micPeakDb` is measured here.

### Storage — additive and Go-safe (informs #59 / #61 / #54)

- `segments` already carries `source`, `duplicate_of`, `dedup_method`,
  `heal_marker`, `mic_peak_db`; `sessions` carries `last_deduped_segment_seq`
  (`Storage/Records/SegmentRecord.swift`, `SessionRecord.swift`). No speaker
  field is modeled yet.
- GRDB migrations register in `Storage/DatabaseConfiguration.swift`; a new
  speaker column / voiceprint table is a new `registerMigration(...)` after the
  existing `20260425_001_dedup_and_heal`.
- The Go reader uses **explicit column lists**, not `SELECT *`
  (`cmd/steno/internal/db/store.go`), so adding columns will not break it until
  Go opts in. Cross-process access is WAL; the Swift writer sets
  `PRAGMA journal_mode = WAL`, the Go side opens read-only.

### Timestamp join key — NOT usable as-is (the key risk)

`StoredSegment.startedAt` is **wall-clock at result emission**, not audio-frame
time:

- `RecognizerResult.timestamp` defaults to `Date()`
  (`Engine/SpeechRecognizerFactory.swift:8,15`).
- The result is constructed with only `text`, `isFinal`, `source` — no
  timestamp and no audio range — at
  `Engine/DefaultSpeechRecognizerFactory.swift:137-141`, so it takes the
  `Date()` default: the instant SpeechAnalyzer *emits* the finalized result.
- The engine then stores `startedAt = result.timestamp` and
  `endedAt = startedAt + duration` (`Engine/RecordingEngine.swift:~932`).
- The `SpeechTranscriber` result's actual audio time range (frame-relative on
  the analyzer's input timeline) is **discarded**. (So is per-result
  `confidence` — a minor aside; stored confidence is always nil.)

There is **no session clock**: both sources independently call `Date()` as
results arrive. Sequence numbers are per-session and global across sources
(`RecordingEngine.swift:93`), interleaving mic and system audio.

Why this breaks the merge: diarized windows are cut from the PCM ring buffer at
frame offsets (true audio time), while transcript timestamps lag true audio
time by the recognizer's variable emission latency (can be seconds for
finalized results). Intersecting the two would attach speaker labels to the
wrong words. The precision is fine (microsecond `Date`); the **reference point
is wrong**.

This is exactly the assumption the engine itself flags as unverified at
`Engine/RecordingEngine.swift:862-866` ("`result.timestamp` is the audio-frame
start instant … if testing shows otherwise, plumb wall-clock timestamps
through the audio path"). The inventory confirms the assumption is currently
false in the implementation.

## Consequence / recommended next step

A prerequisite must land before the #61 merge (and ideally alongside the #56
tee): plumb a frame-accurate time range from the `SpeechTranscriber` result
into `RecognizerResult` → `StoredSegment`, anchored to a **shared session
clock** that the diarization windower also uses, so both express time on one
axis. Filed as a follow-up and linked under #53. Until then, timestamp-based
merging is not safe.

## Tests

No code changed; no new tests. Existing suite untouched.

[steno-tests-passed: inventory-only, no code change]
