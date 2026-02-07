---
title: "feat: Multi-Source Audio Capture for Meeting Transcription"
type: feat
date: 2026-02-07
brainstorm: docs/brainstorms/2026-02-07-multi-source-audio-capture-brainstorm.md
---

# feat: Multi-Source Audio Capture for Meeting Transcription

## Overview

Add system/app audio capture alongside the existing microphone input so Steno can transcribe both sides of a conversation during Zoom/Teams/FaceTime calls. Uses macOS Core Audio Taps API (`AudioHardwareCreateProcessTap`) -- no virtual audio driver installation required. Two independent speech recognizers provide speaker attribution: "You" (mic) vs "Others" (system audio).

## Problem Statement

Steno currently only captures microphone audio. During video calls, the other participants' audio (coming through the system output) is not transcribed. Users want a complete meeting transcript without installing third-party audio routing software.

## Scope: What's In and What's Deferred

**v1 (this plan):**
- Mic + all system audio (two recognizers, speaker attribution)
- `[a]` keyboard toggle to enable/disable system audio
- `[You]` / `[Others]` labels on transcript entries
- `AudioSource` protocol for testability
- `SystemAudioSource` for Core Audio Taps
- DB migration for source tracking
- Inline permission error handling

**Deferred to v2 (next priority after v1 ships):**
- Per-app filtering (MeetingAppDetector, PID targeting, process exit monitoring)
- Interactive source picker TUI
- `--sources` CLI flag
- PermissionService protocol extension
- Markdown export with speaker labels
- Summary prompt with speaker attribution
- Refactoring ViewState into proper services (this should be the NEXT effort after v1)

---

## Phase 1: Validation Spikes (1-2 days)

Two unknowns could invalidate the architecture. Prototype these first as throwaway scripts.

### Spike 1: Dual SpeechAnalyzer Concurrency

**Question:** Can two `SpeechAnalyzer` / `SpeechTranscriber` instances run concurrently for the same locale?

**Test:** Throwaway Swift script that instantiates two `SpeechAnalyzer` instances, each with a `SpeechTranscriber` module, feeds them concurrent audio, and confirms both produce results without errors or model locking.

**If it fails:** Fall back to single muxed recognizer (loses speaker attribution). Stop and re-plan.

### Spike 2: SPM Executable Audio Capture Permission

**Question:** Does a Swift Package Manager executable properly trigger the `NSAudioCaptureUsageDescription` permission dialog?

**Test:** Throwaway script that calls `AudioHardwareCreateProcessTap` with `NSAudioCaptureUsageDescription` in the embedded Info.plist. Verify the permission dialog appears. The existing microphone permission works, so Info.plist embedding is at least partially functional.

**If it fails:** Investigate signing requirements or `.app` bundle wrapping. Potential hard blocker.

**Acceptance Criteria:**
- [x] Two concurrent SpeechAnalyzer instances produce results without errors
- [x] SPM executable triggers audio capture permission dialog
- [x] Spike code is thrown away (reimplemented via TDD in later phases)

---

## Phase 2: AudioSource Protocol + Model Changes (2-3 days)

Define the protocol, add source tracking to the data model, and run the DB migration. TDD: write tests first for each change.

### AudioSource Protocol

```swift
// Sources/Steno/Audio/AudioSource.swift
public protocol AudioSource: Sendable {
    var name: String { get }
    var sourceType: AudioSourceType { get }

    /// Starts capture. Returns audio buffers and the format they arrive in.
    func start() async throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat)

    /// Stops capture and cleans up resources. Silently handles cleanup errors.
    func stop() async
}
```

Design notes:
- `start()` returns format alongside buffers -- consumer needs sample rate/channels for SpeechAnalyzer setup
- No `audioLevel` on the protocol -- audio level is computed by `AudioTapProcessor` which already exists and sits between the source and the recognizer
- `stop()` does not throw -- implementations handle cleanup errors internally (log, don't propagate)
- The mic path does NOT conform to this protocol in v1 -- it stays as-is in ViewState. The protocol exists for `SystemAudioSource` + `MockAudioSource`. When the mic path is extracted in v2, it will also conform.

### AudioSourceType

```swift
// Inline in Sources/Steno/Models/TranscriptSegment.swift (not a separate file)
public enum AudioSourceType: String, Sendable, Codable, Equatable {
    case microphone    // "You"
    case systemAudio   // "Others"
}
```

### Model Changes

**Rule:** All modified initializers get `source: AudioSourceType = .microphone` as a default parameter so existing call sites do not break.

**Files to modify:**
- `Sources/Steno/Models/TranscriptSegment.swift` -- add `AudioSourceType` enum, add `source: AudioSourceType = .microphone` field
- `Sources/Steno/Models/StoredSegment.swift` -- add `source: AudioSourceType = .microphone` field, update `StoredSegment.from()` conversion
- `Sources/Steno/Storage/Records/SegmentRecord.swift` -- add `source` column mapping
- `Sources/Steno/Storage/DatabaseConfiguration.swift` -- new migration `"20260207_001_add_segment_source"`: `ALTER TABLE segments ADD COLUMN source TEXT NOT NULL DEFAULT 'microphone'`
- `Sources/Steno/Views/MainView.swift` -- add `source: AudioSourceType = .microphone` to `TranscriptEntry`

**Note:** `TranscriptionResult` in `SpeechRecognitionService.swift` does NOT get a `source` field. The recognizer doesn't know where its audio came from -- ViewState tags the source when creating `TranscriptEntry` and `TranscriptSegment` based on which recognizer task produced the result.

**Files to create:**
- `Sources/Steno/Audio/AudioSource.swift` -- protocol
- `Tests/StenoTests/Mocks/MockAudioSource.swift`

**TDD order:**
1. Write `AudioSourceType` enum and `MockAudioSource` (test-supporting types first)
2. Write failing tests for `TranscriptSegment` with source field
3. Add `source` field to make tests pass
4. Write failing DB migration test: create old-schema DB, migrate, verify `source` defaults to `"microphone"`
5. Implement migration to pass test
6. Update `StoredSegment`, `SegmentRecord`, `TranscriptEntry` (all with `= .microphone` defaults)
7. Verify all existing tests pass unchanged (defaults mean no call sites break)

**Acceptance Criteria:**
- [ ] `AudioSource` protocol defined with `start() -> (buffers, format)` and `stop()`
- [ ] `AudioSourceType` enum in `TranscriptSegment.swift`
- [ ] `TranscriptSegment`, `StoredSegment`, `TranscriptEntry` all have `source` field with `.microphone` default
- [ ] All modified `init()` methods have `source: AudioSourceType = .microphone` parameter
- [ ] DB migration named `"20260207_001_add_segment_source"` adds column with default
- [ ] Migration regression test: old schema -> migrate -> verify defaults
- [ ] `MockAudioSource` for testing
- [ ] All existing tests pass without modification (defaults preserve compat)

---

## Phase 3: SystemAudioSource (3-5 days)

Implement system audio capture using Core Audio Taps. This is the hard part.

**Files to create:**
- `Sources/Steno/Audio/SystemAudioSource.swift` -- Core Audio Taps implementation, conforms to `AudioSource`
- `Tests/StenoTests/Audio/SystemAudioSourceTests.swift`

**Files to modify:**
- `Resources/Info.plist` -- add `NSAudioCaptureUsageDescription`

**Implementation (all-system-audio mode only for v1):**

1. **Create tap:** `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessAudioObjectID])` -- captures everything except Steno's own audio
2. **Create process tap:** `AudioHardwareCreateProcessTap(tapDescription, &tapID)`
3. **Read tap UUID:** `kAudioTapPropertyUID` from the tap object
4. **Create aggregate device:** Dictionary with `kAudioAggregateDeviceTapListKey` containing the tap UUID
5. **Read tap format:** `kAudioTapPropertyFormat` to get `AudioStreamBasicDescription`
6. **Set up IOProc:** `AudioDeviceCreateIOProcIDWithBlock` on the aggregate device -- receives audio buffers in the callback
7. **Format conversion:** Convert buffers to `AVAudioPCMBuffer` using `AVAudioConverter` if tap format differs from SpeechAnalyzer expected format (reuse pattern from existing `AudioTapProcessor`)
8. **Start:** `AudioDeviceStart(aggDeviceID, procID)`
9. **Cleanup on `stop()`:** Reverse order -- `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`

**Permission handling (inline, no protocol extension):**
- If `AudioHardwareCreateProcessTap` returns permission-denied `OSStatus`: set `ViewState.errorMessage` to explain what happened, offer to open System Settings, continue mic-only
- No pre-check API exists -- the tap creation attempt IS the permission check

**Failure modes:**

| Failure | Detection | Recovery | UX |
|---|---|---|---|
| Tap creation fails (permission denied or other) | `OSStatus` from `AudioHardwareCreateProcessTap` | Don't start system audio source | Error: "System audio unavailable" + details |
| Audio stream dies mid-session | IOProc stops being called / aggregate device invalidated | Mark system audio as stopped, continue mic | Status: "System audio disconnected" |
| Audio format incompatible | `AVAudioConverter` failure | Don't start system audio source | Error: "Unsupported audio format" |

**Testing strategy:** `SystemAudioSource` wraps Core Audio C APIs that require real hardware. Unit tests mock at the protocol boundary (using `MockAudioSource`). The lifecycle and cleanup tests for `SystemAudioSource` itself are integration tests that run locally, not in CI. The plan should include manual integration testing: run with actual system audio playing.

**TDD order:**
1. Write `MockAudioSource` tests to validate the protocol contract
2. Write `SystemAudioSource` integration tests (lifecycle, cleanup order, error paths)
3. Implement `SystemAudioSource` to pass tests
4. Manual integration test: play audio through system, verify capture works

**Acceptance Criteria:**
- [ ] `SystemAudioSource` captures all system audio (excluding own process)
- [ ] Conforms to `AudioSource` protocol
- [ ] Audio format conversion handles different sample rates
- [ ] Cleanup runs in correct reverse order on `stop()` (no resource leaks)
- [ ] Permission denial handled inline with user-facing error message
- [ ] `NSAudioCaptureUsageDescription` in Info.plist
- [ ] Integration tests for lifecycle and error paths (local-only, not CI)
- [ ] Protocol-level tests using MockAudioSource (CI-safe)

---

## Phase 4: Wire Into ViewState + UI (2-3 days)

Connect the system audio source to ViewState and update the display. No coordinator class -- ViewState manages two sources directly.

**Files to modify:**
- `Sources/Steno/Views/MainView.swift` -- ViewState changes + display updates

### ViewState Changes

Add to `ViewState`:
- `systemAudioSource: SystemAudioSource?` -- nil when system audio disabled
- `systemRecognizerTask: Task<Void, Never>?` -- second recognizer loop
- `systemPartialText: String` -- partial text from system audio recognizer (separate property, not a dictionary)
- `isSystemAudioEnabled: Bool` -- toggled by `[a]` key

Keep existing `partialText` for mic. Add `systemPartialText` alongside it. Add a backward-compat computed property if needed:

```swift
// Existing code continues to read partialText for mic
// New display code reads both partialText and systemPartialText
```

The second recognizer is a parallel `Task` that:
1. Calls `systemAudioSource.start()` to get the buffer stream + format
2. Creates a second `SpeechAnalyzer` + `SpeechTranscriber`
3. Feeds buffers through a second `AudioTapProcessor` (for format conversion + level metering)
4. Creates `TranscriptionResult` values (no source tag on results -- ViewState tags the source)
5. Creates `TranscriptEntry` with `source: .systemAudio` and appends to the same `entries` array

**Error isolation:** If the system audio task throws, catch the error, set an error message, nil out `systemAudioSource`, set `isSystemAudioEnabled = false`, and let the mic recognizer continue. Don't kill the session.

### Keyboard Toggle

- `[a]` toggles system audio on/off
- When toggling ON: create `SystemAudioSource`, start second recognizer task
- When toggling OFF: cancel second recognizer task, call `systemAudioSource.stop()`, nil it out
- Status bar shows current state: `MIC + SYS` or `MIC`
- `[a]` shown in keyboard shortcuts help bar at bottom of screen

### Display Changes

- Transcript entries: `[10:30:15] [You] I think we should proceed.`
- When only mic is active (system audio never enabled this session), no label prefix (backward-compatible)
- Labels appear when system audio has been enabled at any point in the session
- Two partial text lines when both active:
  ```
  [You] I think we should pro▌
  [Others] That sounds lik▌
  ```

**TDD order:**
1. Write tests for ViewState system audio toggle behavior (using MockAudioSource)
2. Write tests for dual partial text management (`partialText` + `systemPartialText`)
3. Write tests for error isolation (system audio fails, mic continues)
4. Write tests for display with/without source labels
5. Implement ViewState changes
6. Update display code
7. Manual integration test: run during an actual Zoom call

**Acceptance Criteria:**
- [ ] `[a]` keyboard shortcut toggles system audio capture on/off
- [ ] `[a]` shown in keyboard shortcuts help bar
- [ ] Status bar shows `MIC + SYS` or `MIC`
- [ ] Transcript entries show `[You]` / `[Others]` labels when multi-source active
- [ ] No labels when session is mic-only (backward-compatible)
- [ ] Two concurrent partial texts displayed correctly (two separate String properties)
- [ ] System audio failure does not kill mic transcription
- [ ] ViewState does not exceed ~1400 lines; if it does, extract audio management into a helper before merging
- [ ] All tests pass

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Two SpeechAnalyzers can't run concurrently | Low | Critical | Phase 1 spike validates first |
| SPM executable can't trigger audio capture permission | Medium | Critical | Phase 1 spike; fallback: .app bundle wrapping |
| Core Audio Taps API underdocumented | High | Medium | Reference AudioCap/audiotee; spike testing |
| ViewState becomes more complex | Medium | Low | 1400-line guard; v2 refactor is next priority |
| Audio format mismatch between tap and recognizer | Medium | Medium | Format conversion via AVAudioConverter (existing pattern) |

---

## What's NOT in Scope (v1)

- Per-app audio filtering (MeetingAppDetector, PID targeting)
- Interactive source picker TUI
- `--sources` CLI flag
- PermissionService protocol extension
- Markdown export with speaker labels (quick v2 follow-up)
- Summary prompt with speaker attribution (quick v2 follow-up)
- ViewState refactor to TranscriptionViewModel (v2 priority)
- Recording/exporting raw audio files
- Speaker diarization within a single source
- Video capture
- macOS versions older than 26

---

## File Summary

### New files (4)
- `Sources/Steno/Audio/AudioSource.swift` -- protocol
- `Sources/Steno/Audio/SystemAudioSource.swift` -- Core Audio Taps implementation
- `Tests/StenoTests/Audio/SystemAudioSourceTests.swift`
- `Tests/StenoTests/Mocks/MockAudioSource.swift`

### Modified files (~6)
- `Sources/Steno/Models/TranscriptSegment.swift` -- add `AudioSourceType` enum + `source` field
- `Sources/Steno/Models/StoredSegment.swift` -- add `source` field
- `Sources/Steno/Storage/Records/SegmentRecord.swift` -- add `source` column
- `Sources/Steno/Storage/DatabaseConfiguration.swift` -- migration `20260207_001_add_segment_source`
- `Sources/Steno/Views/MainView.swift` -- ViewState (system audio toggle, display labels, dual partials, keyboard shortcut)
- `Resources/Info.plist` -- `NSAudioCaptureUsageDescription`

### Test files modified (~3)
- `Tests/StenoTests/Models/TranscriptSegmentTests.swift`
- `Tests/StenoTests/Storage/SQLiteTranscriptRepositoryTests.swift`
- `Tests/StenoTests/Storage/DatabaseConfigurationTests.swift`

---

## References

### Internal
- Brainstorm: `docs/brainstorms/2026-02-07-multi-source-audio-capture-brainstorm.md`
- Current audio pipeline: `Sources/Steno/Views/MainView.swift:1057-1098`
- AudioTapProcessor: `Sources/Steno/Views/MainView.swift:148-225`
- Device enumeration: `Sources/Steno/Views/MainView.swift:56-146`
- SpeechRecognitionService protocol: `Sources/Steno/Speech/SpeechRecognitionService.swift`
- TranscriptSegment model: `Sources/Steno/Models/TranscriptSegment.swift`
- DB schema: `Sources/Steno/Storage/DatabaseConfiguration.swift:61-108`
- Entitlements: `Resources/Steno.entitlements`

### External
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Apple: AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [Apple: NSAudioCaptureUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) -- Swift Core Audio taps reference
- [makeusabrew/audiotee](https://github.com/makeusabrew/audiotee) -- System audio capture CLI
- [AudioTee article](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos) -- Core Audio taps deep dive
