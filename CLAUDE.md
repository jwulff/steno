# Steno - macOS Speech-to-Text TUI

---

## STOP - READ THIS BEFORE ANY CODE CHANGES

**BEFORE modifying ANY code file, you MUST:**

1. Create a feature/fix branch - NEVER commit directly to `main`
2. Create a worktree for the branch
3. Open a PR on first push

---

## Public Open Source Project

**This is a public repository on GitHub: https://github.com/jwulff/steno**

Everything committed here is visible to the world. NEVER commit:

- API keys, tokens, or secrets of any kind
- Passwords or credentials
- Private URLs or internal server addresses
- Personal information (emails, phone numbers, addresses)
- `.env` files or environment configurations with secrets
- Signing certificates or private keys (`.p12`, `.pem`, `.key`)
- Database dumps or files containing user data

If you accidentally commit sensitive data, it's NOT enough to delete it in a new commit - the data remains in git history. You must rewrite history or consider the secret compromised.

When in doubt, add it to `.gitignore` first.

---

## Project Overview

A macOS TUI app that uses Apple's Speech framework (SpeechAnalyzer/SpeechTranscriber from macOS 26) for real-time microphone transcription.

**Tech Stack:**
- Swift 6.2+ / Swift Package (executable)
- SwiftTUI for terminal UI
- swift-argument-parser for CLI
- macOS 26 SpeechAnalyzer API (on-device, 55% faster than Whisper)
- Swift Testing framework

---

## TDD IS PARAMOUNT

**Every feature starts with a failing test.**

### The Red-Green-Refactor Cycle
1. **RED**: Write a failing test that defines expected behavior
2. **GREEN**: Write minimum code to make the test pass
3. **REFACTOR**: Clean up while keeping tests green

### Key Design Decisions for Testability
- **Protocol-first**: Define interfaces before implementations
- **Dependency injection**: All services passed in, never instantiated internally
- **No singletons**: Everything injectable
- **Pure functions**: Side-effect-free where possible

---

## Repository Structure

```
steno/main/
├── CLAUDE.md
├── Package.swift
├── changes/
├── .githooks/
├── .claude/
├── Sources/Steno/
│   ├── main.swift
│   ├── App/
│   │   ├── StenoApp.swift
│   │   └── TranscriptionViewModel.swift
│   ├── Views/
│   │   ├── MainView.swift
│   │   └── TranscriptView.swift
│   ├── Speech/
│   │   ├── SpeechRecognitionService.swift  # Protocol
│   │   ├── SpeechAnalyzerService.swift
│   │   └── AudioCaptureManager.swift
│   ├── Permissions/
│   │   ├── PermissionService.swift         # Protocol
│   │   └── SystemPermissionService.swift
│   ├── Models/
│   │   ├── Transcript.swift
│   │   └── TranscriptSegment.swift
│   └── Storage/
│       └── TranscriptRepository.swift
└── Tests/StenoTests/
    ├── Models/
    ├── ViewModel/
    ├── Speech/
    ├── Mocks/
    └── Integration/
```

---

## Build & Test Commands

### Build
```bash
swift build
```

### Run Tests
```bash
swift test
```

### Run App
```bash
swift run steno
```

---

## Git Worktree Workflow

```bash
# Create worktree for feature work
cd ~/Development/steno/main
git branch feature/NAME
git push -u origin feature/NAME
git worktree add ../feature-NAME feature/NAME
cd ../feature-NAME

# Cleanup after merge
cd ~/Development/steno/main
git worktree remove ../feature-NAME
```

---

## Testing Conventions

### Swift Testing Framework
```swift
import Testing

struct TranscriptSegmentTests {
    @Test func creation() {
        let segment = TranscriptSegment(text: "hello", timestamp: .now, duration: 1.0, confidence: 0.95)
        #expect(segment.text == "hello")
    }
}
```

### Test File Naming
- Tests mirror source structure: `Models/Transcript.swift` → `Models/TranscriptTests.swift`
- Mocks go in `Tests/StenoTests/Mocks/`

### Test Attestation

Every commit must include:
```
[steno-tests-passed: X tests in Ys]
```

---

## Code Conventions

### Protocol-First Design
```swift
// 1. Define protocol first
protocol SpeechRecognitionService: Sendable {
    var isListening: Bool { get async }
    func startTranscription(locale: Locale) -> AsyncThrowingStream<TranscriptionResult, Error>
    func stopTranscription() async
}

// 2. Then implement
final class SpeechAnalyzerService: SpeechRecognitionService {
    // ...
}
```

### Dependency Injection
```swift
// Good: Dependencies injected
@Observable
final class TranscriptionViewModel {
    init(speechService: SpeechRecognitionService, permissionService: PermissionService) {
        // ...
    }
}

// Bad: Hardcoded dependencies
@Observable
final class TranscriptionViewModel {
    let speechService = SpeechAnalyzerService()  // Not testable!
}
```

### Naming
- Views: `MainView`, `TranscriptView`
- ViewModels: `TranscriptionViewModel`
- Models: `Transcript`, `TranscriptSegment`
- Services: `SpeechRecognitionService` (protocol), `SpeechAnalyzerService` (impl)
- Mocks: `MockSpeechService`, `MockPermissionService`

---

## macOS 26 Speech API Notes

### SpeechAnalyzer API
```swift
import Speech

let analyzer = SpeechAnalyzer()
let transcriber = SpeechTranscriber(analyzer: analyzer, locale: .current)

for try await result in transcriber.results {
    // Handle transcription result
}
```

### Required Permissions
- Microphone access (AVCaptureDevice)
- Speech recognition (SFSpeechRecognizer or new API)

### Info.plist Keys
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Steno needs microphone access to transcribe your speech.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>Steno uses on-device speech recognition to convert your speech to text.</string>
```

---

## Anti-Patterns

- Writing implementation before tests
- Hardcoding service dependencies
- Using singletons
- Skipping error handling
- Force unwrapping optionals
- Business logic in views
- Committing secrets, credentials, or sensitive data (this is a public repo!)
