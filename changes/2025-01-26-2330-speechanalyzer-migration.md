# Migrate to macOS 26 SpeechAnalyzer API

## Why

The original SFSpeechRecognizer implementation had significant limitations:

1. **`isFinal` never true** - During continuous recognition, results rarely finalize, requiring a hacky stabilization timer
2. **Cumulative text** - Returns entire transcript history, not incremental results
3. **Optimized for short-form** - Siri's dictation model, not ideal for longer transcription
4. **Slower processing** - Server-based recognition even with `requiresOnDeviceRecognition`

The new SpeechAnalyzer API (macOS 26) solves all these issues.

## How

Replaced the speech recognition pipeline:

### Before (SFSpeechRecognizer)
```
AVAudioEngine → SFSpeechAudioBufferRecognitionRequest → SFSpeechRecognitionTask
                                                              ↓
                                                    (isFinal rarely true)
                                                              ↓
                                                    Stabilization timer hack
```

### After (SpeechAnalyzer)
```
AVAudioEngine → AudioTapProcessor → AsyncStream<AnalyzerInput> → SpeechAnalyzer
                     ↓                                                  ↓
              (format conversion                              SpeechTranscriber
               48kHz → 16kHz)                                        ↓
                                                          transcriber.results
                                                          (proper isFinal!)
```

### Key Components

- **AudioTapProcessor**: Thread-safe class handling audio callbacks, format conversion, and level metering
- **SpeechTranscriber**: Configured with `.volatileResults` for real-time partial text
- **AssetInventory**: Handles automatic model download if needed

## Key Decisions

- **Separate AudioTapProcessor class**: Swift 6 strict concurrency requires isolating the audio tap callback from MainActor-bound ViewState
- **Format conversion in tap**: SpeechAnalyzer wants 16kHz mono; mic provides 48kHz - convert in the processor
- **Volatile + Final results**: Show volatile (partial) in yellow with cursor, finalized in white with timestamp
- **No stabilization timer needed**: SpeechAnalyzer properly signals when results are final

## Testing

- All 25 existing tests continue to pass (model and view model tests)
- Manual testing confirms:
  - Proper finalization of speech segments
  - Higher quality transcription
  - Real-time volatile results showing during speech
  - Correct audio format conversion

[steno-tests-passed: 25 tests in 0.2s]

## What's Next

- Explore `transcriptionOptions` like `.etiquetteReplacements` for content filtering
- Add punctuation via `addsPunctuation` option
- Consider adding speaker diarization when available
- Evaluate DictationTranscriber fallback for older macOS versions
