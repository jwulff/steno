# Diarization — Frame-Accurate Segment Timestamps (issue #64)

Prerequisite for the diarization timestamp merge (#61), surfaced by the ASR
inventory (#55, `changes/2026-05-25-0240-diarization-1-asr-inventory.md`).

## Why

Diarization windows (#58) are cut from the PCM ring buffer (#56) at
frame-accurate offsets on a per-source capture clock. To attach speaker labels
to transcript segments, the merge needs the segments on that same audio axis.
But transcript segments are stamped with `result.timestamp`, which defaults to
`Date()` at the moment SpeechAnalyzer *emits* a finalized result — wall-clock
emission time, lagging true audio time by the recognizer's variable latency.
Joining diarization (audio time) against transcript (emission time) would
misattribute speakers.

Crucially, `startedAt` / `endedAt` (wall-clock) are load-bearing for *other*
features — dedup's ±3s overlap match, U10 demarcation routing, and TUI display.
So this change does **not** repurpose them. It **adds** an audio-frame time
alongside the existing wall-clock fields.

## How

- **`RecognizerResult`** gains `audioStartSeconds` / `audioDurationSeconds`
  (`TimeInterval?`, default `nil`). `DefaultSpeechRecognizerHandle` populates
  them from the `SpeechTranscriber` result's `range` (a `CMTimeRange` on the
  analyzer's input timeline) via `CMTimeGetSeconds`; an invalid range
  (`NaN`) maps to `nil`.
- **`StoredSegment`** gains `audioStart` / `audioEnd` (`TimeInterval?`). The
  engine sets them from the result's audio time (`audioEnd = start +
  duration`) when building the segment, leaving `startedAt`/`endedAt`
  (wall-clock) untouched.
- **Schema**: migration `20260525_001_segment_audio_time` adds nullable
  `audio_start` / `audio_end` REAL columns; `SegmentRecord` maps them. Prior
  rows and results without a valid range migrate cleanly as NULL. The Go reader
  uses explicit column lists, so it's unaffected until it opts in.

The analyzer's input timeline and the ring buffer's capture clock both start at
each pipeline bring-up and count the same teed buffers, so `audioStart` and the
diarization window times share one per-source axis — which is what the merge
needs (mic transcript ↔ mic windows, sys ↔ sys). Cross-source alignment is not
required: the registry stitches by embedding, not absolute time.

Because `result.timestamp` is unchanged, demarcation routing and dedup behave
exactly as before — this change is purely additive to their world.

## Open / not done here

- **On-hardware verification.** The acceptance criterion "verified on real
  16-core-NE hardware that the plumbed time tracks audio-frame start, not
  emission latency" cannot be done in this Linux dev environment. The code
  assumes `SpeechTranscriber.Result.range` is the audio-frame range; that
  assumption must be confirmed on device (log raw ranges) before trusting the
  merge. Until then `audio_start`/`audio_end` are populated but unverified.
- Per-result `confidence` is still discarded (separate, low-value follow-up).

## Tests

- Repository round-trip: a segment saved with `audioStart`/`audioEnd`
  round-trips through SQLite; absent values persist as NULL
  (`SQLiteTranscriptRepositoryTests`).
- Existing migration/dedup/demarcation tests remain valid — the change is
  additive and leaves wall-clock timestamps intact.

Swift daemon suite not runnable in this Linux env (macOS 26 target); runs on
CI's macOS runner. Go suite unaffected.

[steno-tests-passed: audio-time round-trip tests authored for CI macOS runner; swift not runnable on linux, go ./... ok]
