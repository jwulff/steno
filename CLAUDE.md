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
│   steno         │◄──── NDJSON commands ────────►│   steno-daemon       │
│   (Go)          │◄──── NDJSON events ──────────►│   (Swift)            │
│                 │                               │                      │
│  - TUI display  │                               │  - Microphone capture│
│  - MCP server   │      SQLite (read-only)       │  - System audio      │
│  - Daemon mgmt  │◄─────────────────────────────►│  - SpeechAnalyzer    │
│  - Level meters │                               │  - Topic extraction  │
└─────────────────┘                               │  - Segment storage   │
                                                  └──────────────────────┘
```

**Daemon** (`daemon/`): Swift 6.2+ headless service. Captures audio (mic + ScreenCaptureKit system audio), runs SpeechAnalyzer/SpeechTranscriber (macOS 26), persists segments to SQLite (GRDB), extracts topics via on-device LLMs. Exposes a Unix socket at `~/Library/Application Support/Steno/steno.sock` with NDJSON protocol.

**Steno** (`cmd/steno/`): Go binary providing both TUI and MCP server modes. Default mode shows the bubbletea TUI; `--mcp` flag runs MCP stdio server. Auto-starts the daemon if not already running. Connects via Unix socket, reads topics from SQLite (read-only, WAL mode).


---

## Tech Stack

- **Daemon**: Swift 6.2+, swift-argument-parser, GRDB (SQLite), SpeechAnalyzer API (macOS 26)
- **Steno**: Go 1.24+, bubbletea, lipgloss, mcp-go, modernc.org/sqlite (pure Go, no CGo)
- **IPC**: Unix domain socket, NDJSON (newline-delimited JSON)
- **Testing**: Swift Testing framework (daemon), Go testing (steno)

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
├── Makefile                       # Build, sign, test, run (start here)
├── daemon/                        # Swift daemon (steno-daemon)
│   ├── Package.swift
│   ├── Resources/                 # Entitlements + Info.plist for signing
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
├── cmd/steno/                     # Go binary (steno: TUI + MCP)
│   ├── go.mod
│   ├── main.go                    # --mcp flag dispatches mode
│   └── internal/
│       ├── app/                   # Bubbletea Model, messages, keymap
│       ├── daemon/                # Socket client, protocol, lifecycle manager
│       ├── db/                    # SQLite read-only queries (shared TUI + MCP)
│       ├── mcp/                   # MCP tool handlers
│       └── ui/                    # Lipgloss styles
├── schema/                        # SQLite schema contract (README.md)
├── changes/                       # Change documentation per PR
└── .githooks/                     # Pre-push test runner (runs make test)
```

---

## Build & Test Commands

```bash
make build            # Build daemon (release) + steno
make test             # Run ALL tests (daemon + steno)
make run-daemon       # Build, sign, and run daemon (debug mode)
make run-steno        # Build and run TUI
make run-mcp          # Build and run MCP server
```

### Individual targets
```bash
make build-daemon       # Swift release build with embedded Info.plist
make build-daemon-debug # Swift debug build (faster iteration)
make build-steno        # Go build
make sign-daemon        # Ad-hoc code-sign the release daemon binary
make sign-daemon-debug  # Ad-hoc code-sign the debug daemon binary
make test-daemon        # swift test (daemon only)
make test-steno         # go test ./... (steno only)
make install            # Install signed binaries to ~/.local/bin
make clean              # Remove all build artifacts
```

### Why `swift run` doesn't work for the daemon
`swift run` skips code-signing. SpeechAnalyzer requires entitlements
(`disable-library-validation`, `allow-jit`) to avoid SIGTRAP.
Use `make run-daemon` instead, which builds, signs, and runs the debug binary.

**Do NOT use `com.apple.developer.speech-recognition`** — it's a restricted
entitlement that requires a provisioning profile. CLI binaries can't embed
profiles, so AMFI kills the process (SIGKILL). macOS 26 SpeechAnalyzer
does not need this entitlement.

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

### Swift Testing Framework (daemon)
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
- **NEVER fall back to legacy speech APIs** (`SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`). The solution to SpeechAnalyzer/SpeechTranscriber issues is always to fix the runtime environment (main RunLoop, `@MainActor`, `dispatchMain()`), not to downgrade APIs. We use macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` exclusively.
