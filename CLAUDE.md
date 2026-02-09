# Steno - macOS Speech-to-Text

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

## Architecture

Steno is a two-process system:

```
┌─────────────────┐         Unix socket          ┌──────────────────────┐
│   steno-tui     │◄──── NDJSON commands ────────►│   steno-daemon       │
│   (Go/bubbletea)│◄──── NDJSON events ──────────►│   (Swift)            │
│                 │                               │                      │
│  - Live display │                               │  - Microphone capture│
│  - Topic panel  │      SQLite (read-only)       │  - System audio      │
│  - Level meters │◄─────────────────────────────►│  - SpeechAnalyzer    │
│  - Scrollback   │                               │  - Topic extraction  │
└─────────────────┘                               │  - Segment storage   │
                                                  └──────────────────────┘
```

**Daemon** (`daemon/`): Swift 6.2+ headless service. Captures audio (mic + ScreenCaptureKit system audio), runs SpeechAnalyzer/SpeechTranscriber (macOS 26), persists segments to SQLite (GRDB), extracts topics via on-device LLMs. Exposes a Unix socket at `~/Library/Application Support/Steno/steno.sock` with NDJSON protocol.

**TUI** (`tui/`): Go thin client. Connects to the daemon, subscribes to events, reads topics from SQLite (read-only, WAL mode). Bubbletea for Elm-architecture state management, lipgloss for styling.

**Legacy TUI** (`Sources/Steno/`): Original Swift/SwiftTUI monolith. Still builds and runs standalone. Will be removed once the Go TUI is fully stable.

---

## Tech Stack

- **Daemon**: Swift 6.2+, swift-argument-parser, GRDB (SQLite), SpeechAnalyzer API (macOS 26)
- **TUI**: Go 1.24+, bubbletea, lipgloss, modernc.org/sqlite (pure Go, no CGo)
- **IPC**: Unix domain socket, NDJSON (newline-delimited JSON)
- **Testing**: Swift Testing framework (daemon), Go testing (TUI)

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
steno/
├── CLAUDE.md
├── README.md
├── daemon/                        # Swift daemon (steno-daemon)
│   ├── Package.swift
│   ├── Sources/StenoDaemon/
│   │   ├── StenoDaemon.swift      # @main entry point
│   │   ├── Commands/              # run, status, install, uninstall
│   │   ├── Audio/                 # AudioSource protocol + SystemAudioSource
│   │   ├── Engine/                # RecordingEngine, SpeechRecognizerFactory
│   │   ├── Dispatch/              # CommandDispatcher, EventBroadcaster
│   │   ├── Socket/                # UnixSocketServer, DaemonProtocol
│   │   ├── Infrastructure/        # Paths, PIDFile, SignalHandler
│   │   ├── Models/                # Domain models
│   │   ├── Permissions/           # TCC permission checks
│   │   ├── Services/              # Summarization, topic extraction
│   │   └── Storage/               # SQLite via GRDB
│   └── Tests/StenoDaemonTests/
├── tui/                           # Go TUI (steno-tui)
│   ├── go.mod
│   ├── main.go
│   └── internal/
│       ├── app/                   # Bubbletea Model, messages, keymap
│       ├── daemon/                # Socket client, protocol types
│       ├── db/                    # SQLite read-only queries
│       └── ui/                    # Lipgloss styles
├── schema/                        # SQLite schema contract (README.md)
├── Sources/Steno/                 # Legacy Swift TUI (monolith)
├── Tests/StenoTests/
├── changes/                       # Change documentation per PR
└── .githooks/                     # Pre-push test runner
```

---

## Build & Test Commands

### Daemon (Swift)
```bash
cd daemon
swift build            # Build
swift test             # Run tests (169 tests)
swift run steno-daemon run   # Run daemon (foreground)
```

### TUI (Go)
```bash
cd tui
go build -o steno-tui .   # Build
go test ./...              # Run tests (37 tests)
go run .                   # Run TUI (connects to daemon)
```

### Legacy TUI (Swift)
```bash
swift build    # Build
swift test     # Run tests (137 tests)
swift run steno   # Run monolith
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

### Swift Testing Framework (daemon + legacy)
```swift
import Testing

struct TranscriptSegmentTests {
    @Test func creation() {
        let segment = TranscriptSegment(text: "hello", timestamp: .now, duration: 1.0, confidence: 0.95)
        #expect(segment.text == "hello")
    }
}
```

### Go Testing (TUI)
```go
func TestProtocolRoundTrip(t *testing.T) {
    cmd := daemon.Command{Cmd: "start", Device: "MacBook Pro Microphone"}
    data, _ := json.Marshal(cmd)
    var decoded daemon.Command
    json.Unmarshal(data, &decoded)
    if decoded.Cmd != "start" {
        t.Errorf("expected start, got %s", decoded.Cmd)
    }
}
```

### Test File Naming
- Swift: Tests mirror source structure — `Models/Transcript.swift` → `Models/TranscriptTests.swift`
- Go: Tests live alongside source — `daemon/client.go` → `daemon/client_test.go`
- Mocks go in `Tests/.../Mocks/` (Swift) or `internal/testutil/` (Go)

### Test Attestation

Every commit must include:
```
[steno-tests-passed: X tests in Ys]
```

---

## Daemon Protocol (NDJSON)

### Commands (client → daemon)
```json
{"cmd":"start","device":"MacBook Pro Microphone","systemAudio":true}
{"cmd":"stop"}
{"cmd":"status"}
{"cmd":"devices"}
{"cmd":"subscribe"}
```

### Responses (daemon → client, synchronous)
```json
{"ok":true,"recording":true,"sessionId":"...","status":"Recording"}
{"ok":false,"error":"No microphone permission"}
```

### Events (daemon → subscribed clients, streaming)
```json
{"event":"partial","text":"hello world","source":"microphone"}
{"event":"segment","text":"Hello world.","source":"microphone","seqNum":1}
{"event":"level","mic":0.42,"sys":0.15}
{"event":"status","recording":true,"sessionId":"..."}
{"event":"topics","sessionId":"..."}
{"event":"error","message":"...","transient":true}
```

---

## Code Conventions

### Protocol-First Design (Swift)
```swift
protocol SpeechRecognizerFactory: Sendable {
    func makeRecognizer(locale: Locale, format: AVAudioFormat, source: AudioSourceType)
        async throws -> SpeechRecognizerHandle
}
```

### Dependency Injection
All services are injected, never instantiated internally. The daemon's `RecordingEngine` takes factories and services as init parameters.

### Naming
- **Swift**: `RecordingEngine` (actor), `SpeechRecognizerFactory` (protocol), `DefaultSpeechRecognizerFactory` (impl), `MockSpeechRecognizerFactory` (test)
- **Go**: `daemon.Client`, `daemon.Command`, `db.Store`, `app.Model`

---

## macOS 26 Speech API Notes

### SpeechAnalyzer API (used by daemon)
```swift
let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
    reportingOptions: [.volatileResults], attributeOptions: [])
let analyzer = SpeechAnalyzer(modules: [transcriber])

// MUST run on @MainActor — crashes with SIGTRAP otherwise
try await Task { @MainActor in
    try await analyzer.start(inputSequence: inputSequence)
}.value

for try await result in transcriber.results {
    // result.text, result.isFinal
}
```

### Critical: Main RunLoop Required
`SpeechAnalyzer` requires the main RunLoop to be alive. The daemon uses `ParsableCommand` (not `AsyncParsableCommand`) and calls `dispatchMain()` after launching async work in a `Task {}`.

### Required Permissions
- Microphone access (AVCaptureDevice)
- Speech recognition
- Screen & System Audio Recording (for system audio via ScreenCaptureKit)

---

## Anti-Patterns

- Writing implementation before tests
- Hardcoding service dependencies
- Using singletons
- Skipping error handling
- Force unwrapping optionals
- Business logic in views
- Committing secrets, credentials, or sensitive data (this is a public repo!)
- Using `AsyncParsableCommand` with `dispatchMain()` (crashes — use `ParsableCommand`)
- Calling `SpeechAnalyzer.start()` off the main actor (crashes with SIGTRAP)
