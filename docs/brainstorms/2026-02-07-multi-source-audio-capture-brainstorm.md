# Multi-Source Audio Capture for Meeting Transcription

**Date:** 2026-02-07
**Status:** Brainstorm complete, ready for planning

---

## What We're Building

Multi-source audio capture so Steno can transcribe both sides of a conversation -- your microphone input AND the audio coming from other apps (Zoom, Teams, FaceTime, etc.) -- without requiring the user to install virtual audio drivers.

The end result: run Steno during a Zoom call and get a transcript with speaker attribution ("You" vs "Others").

---

## Why This Approach

### Core Audio Taps API (`AudioHardwareCreateProcessTap`)

We're using macOS's **Core Audio Taps API** (macOS 14.4+) for system/app audio capture. This is the right choice because:

- **No driver installation** -- native macOS API, zero friction for users
- **Purpose-built for audio** -- unlike ScreenCaptureKit which always captures video too
- **Less alarming permission** -- prompts for "audio capture" not "screen recording"
- **Low latency** -- important for real-time transcription
- **Per-app targeting** -- can capture from specific processes by PID
- **macOS 26 requirement is fine** -- Steno already targets macOS 26

For microphone capture, we continue using `AVAudioEngine.inputNode` as Steno already does.

Reference implementations:
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) -- Swift Core Audio taps sample
- [makeusabrew/audiotee](https://github.com/makeusabrew/audiotee) -- System audio CLI tool
- [Apple docs](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)

---

## Key Decisions

### 1. Audio Scope: All system audio by default, per-app filtering for power users

- Default mode captures everything playing through the system (simplest UX)
- Power users can filter to specific apps (e.g., just Zoom)
- Auto-detect common meeting apps (Zoom, Teams, Google Meet, FaceTime, Discord, Webex, Slack) and surface them in the picker

### 2. Speaker Attribution: Independent transcription per source

- Run **two separate SpeechRecognizer instances** -- one for mic, one for system audio
- Each transcript segment is tagged with its source: "You" (mic) or "Others" (system)
- Results merge into a single chronological timeline
- Tradeoff: uses more CPU/memory than a single muxed recognizer, but gives reliable attribution

### 3. UX Activation: Interactive source picker on launch

- On launch, show a TUI menu to select audio sources:
  - Microphone (default, always available)
  - System Audio (all apps)
  - Specific app (auto-detected meeting apps listed)
- Sources can be combined (mic + system audio, mic + specific app)
- Could also support CLI flags for scripting (e.g., `steno --sources mic,system`)

### 4. Architecture: Extract audio capture from speech recognition

Current state: `SpeechAnalyzerService` directly manages `AVAudioEngine` and audio capture. This needs to be separated:

- New `AudioSource` protocol -- abstraction for any audio input (mic, process tap, file, etc.)
- New `ProcessTapAudioSource` -- Core Audio Taps implementation for system/app audio
- New `MicrophoneAudioSource` -- wraps existing AVAudioEngine input (extracted from SpeechAnalyzerService)
- `SpeechAnalyzerService` takes an `AudioSource` dependency instead of managing AVAudioEngine directly
- Multiple `SpeechAnalyzerService` instances can run concurrently with different audio sources

### 5. Permissions

Two permission prompts needed for full functionality:
- **Microphone** (`NSMicrophoneUsageDescription`) -- already exists
- **Audio Capture** (`NSAudioCaptureUsageDescription`) -- new, required for Core Audio Taps

The audio capture permission is separate from Screen Recording and less alarming to users.

---

## Architecture Sketch

```
Source Picker TUI
    ├── MicrophoneAudioSource (AVAudioEngine.inputNode)
    │       ↓
    │   SpeechRecognizer #1 → TranscriptionResult (source: .microphone, label: "You")
    │
    └── ProcessTapAudioSource (AudioHardwareCreateProcessTap)
            ↓
        SpeechRecognizer #2 → TranscriptionResult (source: .systemAudio, label: "Others")
                                        ↓
                                Merged Timeline (chronological)
                                        ↓
                                TranscriptionViewModel
                                        ↓
                                TranscriptRepository (persisted with source tags)
```

---

## Resolved Questions

### 1. Resource Usage: Always run both recognizers

Run both SpeechRecognizer instances unconditionally when multi-source is active. Apple Silicon's Neural Engine handles concurrent speech recognition efficiently. Don't optimize until profiling shows a real problem. Keep it simple.

### 2. Segment Overlap: Interleave chronologically with labels

Display all segments in a single chronological stream, prefixed with source labels (`[You]` / `[Others]`). When both sources produce segments at the same time, they simply interleave by timestamp. Color-coding the labels is a nice-to-have for scannability.

### 3. TranscriptSegment Model: Add `AudioSourceType` enum

Add a new enum to the model:

```swift
public enum AudioSourceType: String, Sendable, Codable {
    case microphone    // "You"
    case systemAudio   // "Others"
}
```

- Add `source: AudioSourceType` field to `TranscriptSegment`
- DB migration adds a `source` TEXT column, defaulting to `"microphone"` for existing rows
- Extensible later with associated values like `.app("us.zoom.xos")` for per-app attribution

### 4. App Detection: Bundle ID lookup via NSWorkspace

Use `NSWorkspace.shared.runningApplications` to find running apps by known bundle IDs:

- `us.zoom.xos` (Zoom)
- `com.microsoft.teams` / `com.microsoft.teams2` (Teams)
- `com.apple.FaceTime` (FaceTime)
- `com.google.Chrome` (Google Meet -- captures all Chrome audio)
- `com.hnc.Discord` (Discord)
- `com.cisco.webexmeetingsapp` (Webex)
- `com.tinyspeck.slackmacgap` (Slack)

Simple, reliable, covers the vast majority of meeting apps. The Chrome/Meet case captures all Chrome audio -- acceptable tradeoff.

### 5. Permission Flow: Re-prompt with explanation

When audio capture permission is denied:
- Show an explanation in the source picker of what the permission enables
- Offer to open System Settings directly
- Still allow mic-only mode if the user ultimately declines
- Don't silently degrade -- this is a core feature worth explaining

### 6. Audio Format / Timestamps: Wall clock time, no resampling

- **Format**: Not an issue -- each recognizer handles its own audio format independently. No resampling needed.
- **Timestamps**: Tag each segment with `Date.now` when it arrives. Wall clock time is simple and sufficient for interleaving a readable transcript. Sub-second precision doesn't matter for speech segments.

---

## What's NOT in Scope

- Recording/exporting raw audio files (just transcription)
- Speaker diarization within a single source (distinguishing multiple remote speakers)
- Video capture of any kind
- Support for macOS versions older than 26
- Virtual audio device support (explicitly excluded)
