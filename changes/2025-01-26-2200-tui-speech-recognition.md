# Real-time Speech-to-Text TUI

## Why

Need a macOS terminal application for real-time speech transcription that:
- Works entirely on-device (no cloud APIs)
- Provides immediate visual feedback as you speak
- Supports microphone selection for different input devices
- Shows a scrollable history of transcriptions

## How

Built a SwiftTUI-based terminal interface with:

1. **Audio capture** via AVAudioEngine with configurable input device
2. **Speech recognition** initially using SFSpeechRecognizer (later migrated to SpeechAnalyzer)
3. **Scrollable transcript view** with timestamps, word wrapping, and LIVE/PAUSED modes
4. **Real-time audio level meter** for visual feedback

### Architecture

```
MainView (SwiftTUI)
    └── ViewState (ObservableObject)
            ├── Audio capture (AVAudioEngine)
            ├── Speech recognition
            └── Transcript management
```

## Key Decisions

- **SwiftTUI over ncurses**: SwiftUI-like declarative API, better Swift integration
- **CoreAudio for device enumeration**: Direct access to system audio devices
- **Stabilization timer workaround**: SFSpeechRecognizer's `isFinal` rarely becomes true during continuous recognition, so we treated partial results as final after 1.5s of no change
- **Separate new text tracking**: SFSpeechRecognizer returns cumulative text, so we track `finalizedTextLength` to show only new portions per line

## Testing

- 25 unit tests covering models, view model, and mocks
- Manual testing with MacBook Air microphone and external devices
- Verified permission flows for microphone and speech recognition

[steno-tests-passed: 25 tests in 0.2s]

## What's Next

- Migrate to macOS 26 SpeechAnalyzer API for proper `isFinal` support
- Add transcript export (copy to clipboard, save to file)
- Add keyboard shortcuts for common actions
