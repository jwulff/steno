# Multi-Source Audio Capture

## Why

During video calls (Zoom, FaceTime, Google Meet), Steno could only transcribe *your* microphone. The other participants' audio — coming through system audio — was completely invisible. To get a full meeting transcript, you need both sides of the conversation.

## How

Added a second audio capture pipeline that runs alongside the existing microphone path. When enabled, Steno runs **two independent SpeechAnalyzer instances** simultaneously — one for your mic ("You") and one for system audio ("Others").

### Architecture

```
ViewState
├── Microphone path (existing)
│   └── AVAudioEngine → AudioConverter → SpeechAnalyzer → [You] segments
│
└── System audio path (new)
    └── ScreenCaptureKit (SCStream) → AudioTapProcessor → SpeechAnalyzer → [Others] segments
```

### New Files

- **`Sources/Steno/Audio/AudioSource.swift`** — Protocol defining the audio source contract: `start()` returns `(AsyncStream<AVAudioPCMBuffer>, AVAudioFormat)`, `stop()` cleans up
- **`Sources/Steno/Audio/SystemAudioSource.swift`** — ScreenCaptureKit implementation that captures all system audio except Steno's own process
- **`Tests/StenoTests/Audio/AudioSourceProtocolTests.swift`** — Protocol conformance tests
- **`Tests/StenoTests/Audio/SystemAudioSourceTests.swift`** — Unit tests for error cases and properties
- **`Tests/StenoTests/Mocks/MockAudioSource.swift`** — Testable mock for the AudioSource protocol

### Modified Files

- **`TranscriptSegment.swift`** — Added `AudioSourceType` enum (`.microphone` / `.systemAudio`) and `source` property
- **`StoredSegment.swift`** — Added `source` field, propagated through init and factory method
- **`SegmentRecord.swift`** — Added `source` column mapping for database persistence
- **`DatabaseConfiguration.swift`** — Added migration `20260207_001_add_segment_source` to add `source` column to segments table
- **`MainView.swift`** — Keyboard toggle `[a]`, dual recognizer management, `[You]`/`[Others]` labels, SYS level meter, system partial text display
- **`Resources/Info.plist`** — Added `NSAudioCaptureUsageDescription` key

## Key Decisions

### ScreenCaptureKit over Core Audio Taps

We initially built system audio capture using Core Audio's `AudioHardwareCreateProcessTap` API (macOS 14.4+). This was a multi-day debugging journey:

1. **Tap created successfully** but all audio buffers contained zeros
2. Fixed non-interleaved stereo buffer copy — still zeros
3. Fixed wrong output device property (`DefaultSystemOutputDevice` vs `DefaultOutputDevice`) — still zeros
4. Added `CGPreflightScreenCaptureAccess()` permission check — passed, still zeros
5. Tried AudioTee's bare aggregate device pattern — got `nope` (1852797029) error on `AudioDeviceStart`

**Root cause:** Core Audio Taps don't properly integrate with macOS TCC (Transparency, Consent, and Control) for CLI tools. The binary doesn't appear in System Settings > Privacy & Security > Screen & System Audio Recording, no menu bar recording indicator is shown, and macOS silently delivers zero-filled buffers. This is because TCC requires an app bundle to display in the privacy panel — plain executables can't register.

**ScreenCaptureKit (`SCStream`)** solves all of these problems:
- Triggers the proper TCC permission dialog via `SCShareableContent.current`
- Shows the orange recording indicator in the menu bar
- Delivers actual audio data
- Has built-in `excludesCurrentProcessAudio`
- Much simpler API — no aggregate device / IOProc dance

### Protocol-First Design

The `AudioSource` protocol allows the system audio path to be fully testable via `MockAudioSource`. The microphone path intentionally does NOT conform to this protocol in v1 — it stays in ViewState because it has deep integration with AVAudioEngine, device selection, and format conversion that would require significant refactoring to extract.

### Dual SpeechAnalyzer Instances

Each audio source gets its own `SpeechAnalyzer` + `SpeechTranscriber` pair. This is necessary because:
- Each source has a different audio format (mic: 16kHz mono, system: 48kHz stereo)
- The `AudioTapProcessor` handles format conversion (48kHz stereo → 16kHz mono) for the system audio path
- Partial results need to be tracked independently

### Source Labels Only When Relevant

The `[You]` / `[Others]` labels only appear after system audio has been enabled at least once in a session (`hasUsedSystemAudio` flag). If you never press `[a]`, the transcript looks exactly like before — no visual clutter.

## What Changed for Users

- Press **`[a]`** during recording to toggle system audio capture
- First time triggers macOS "Screen & System Audio Recording" permission dialog
- Orange recording indicator appears in the menu bar when active
- Transcript shows `[You]` for microphone and `[Others]` for system audio
- Status bar shows `MIC + SYS` with separate level meters
- System audio segments are persisted to the database with `source = "systemAudio"`

## Testing

- 92 tests pass (16 new tests added for AudioSource protocol, SystemAudioSource, AudioSourceType, and database source column)
- Manual integration testing: Zoom calls, YouTube in Chrome, FaceTime
