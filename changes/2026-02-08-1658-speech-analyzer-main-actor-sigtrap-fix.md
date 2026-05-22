# SpeechAnalyzer SIGTRAP fix: main RunLoop + @MainActor (PR #14)

## Why

Immediately after extracting the headless daemon in #11, `steno-daemon`
crashed with `EXC_BREAKPOINT` (SIGTRAP) inside `Speech.framework` the
moment `analyzer.start(inputSequence:)` was called. The monolith hadn't
hit this — but the monolith ran inside an AppKit-style runtime that
provided two things the daemon was missing:

1. **A live main RunLoop.** `SpeechAnalyzer` posts internal work to the
   main RunLoop and asserts that it's running. The daemon's
   `AsyncParsableCommand` entry point spun up a cooperative executor
   and let the main RunLoop die as soon as `run()` returned, so the
   first `analyzer.start()` call tripped the precondition.
2. **`@MainActor` isolation at the `start()` call site.**
   `SpeechAnalyzer.start()` requires the main actor. The recognizer
   pipeline was driving it from a `Task.detached` running on an
   arbitrary cooperative thread, which also tripped the precondition.

Without both, the daemon was unusable — recording started, then died
within milliseconds.

## How

The fix is two coordinated changes plus a hard rule in `CLAUDE.md`.

### 1. Keep the main RunLoop alive: `ParsableCommand` + `dispatchMain()`

`StenoDaemon` and `RunCommand` switched from
`AsyncParsableCommand` to plain `ParsableCommand`. Synchronous `run()`
launches all daemon setup inside a single `Task { ... }`, then falls
through to `dispatchMain()` — which never returns. The main RunLoop
stays alive for the lifetime of the process, exactly as
`SpeechAnalyzer` requires.

```swift
struct RunCommand: ParsableCommand {
    func run() throws {
        // ... PID file, arg validation ...
        Task {
            // database, services, engine, socket server,
            // signal handler — all here
        }
        dispatchMain()  // blocks forever; RunLoop stays up
    }
}
```

### 2. Pin `analyzer.start()` to `@MainActor`

In `DefaultSpeechRecognizerFactory.Pipeline.run()` the call to
`analyzer.start(inputSequence:)` is now wrapped in
`Task { @MainActor in ... }.value`. This hops to the main actor for
the duration of the call regardless of which executor the
surrounding `withThrowingTaskGroup` is running on:

```swift
group.addTask {
    // MUST run on @MainActor — crashes with SIGTRAP otherwise
    try await Task { @MainActor in
        try await self.analyzer.start(inputSequence: self.inputSequence)
    }.value
    // ... iterate transcriber.results ...
}
```

### 3. Anti-pattern entry in `CLAUDE.md`

Added an anti-pattern that the project still carries today:

> **NEVER fall back to legacy speech APIs** (`SFSpeechRecognizer`,
> `SFSpeechAudioBufferRecognitionRequest`). The solution to
> SpeechAnalyzer/SpeechTranscriber issues is always to fix the runtime
> environment (main RunLoop, `@MainActor`, `dispatchMain()`), not to
> downgrade APIs.

This was tempting during the debug — the old monolith used
`SFSpeechRecognizer` and worked. The right fix is to make the runtime
match what macOS 26 `SpeechAnalyzer` expects, not to abandon the
modern API.

## Key Decisions

- **Don't downgrade the API.** Falling back to `SFSpeechRecognizer`
  would have undone the #5/#6/#7 migration work and forfeited
  proper `isFinal` semantics, on-device recognition, and the
  modern volatile-results model. The runtime environment is the
  bug, not `SpeechAnalyzer`.
- **`ParsableCommand` + `dispatchMain()` over
  `AsyncParsableCommand`.** ArgumentParser's async variant is
  ergonomic but actively hostile to anything that needs the main
  RunLoop. For a daemon that owns the process lifetime, the
  synchronous form plus a long-lived `Task` plus `dispatchMain()`
  is correct, and the anti-pattern is now documented in CLAUDE.md.
- **Wrap at the call site, not the surrounding task.** Hopping to
  `@MainActor` for just `analyzer.start()` keeps the task group
  free to schedule the buffer feeder and results iteration on
  whichever executor is appropriate. Only the framework's
  precondition needs the main actor.

## Testing

- 169 daemon tests pass (Swift Testing framework)
- 137 legacy TUI tests still pass (no regression in the old code path)
- Manual smoke test: `make run-daemon` no longer crashes; SIGTRAP gone
- The fix is verified by absence of crash rather than a unit test —
  the framework's precondition can't be exercised from tests without
  a real microphone permission grant

[steno-tests-passed: 169 tests in 0.7s]

## What's Next

This unblocks daemon-side recording but leaves two latent bugs that
surfaced once recording ran long enough to actually transcribe:

- The daemon is still signed with the AMFI-restricted
  `com.apple.developer.speech-recognition` entitlement, which causes
  SIGKILL on launch under certain code-signing identities — fixed in
  #18.
- The mic delivers 48kHz mono but `SpeechAnalyzer` expects 16kHz; the
  pipeline doesn't yet convert. Plus `analyzer.start()` is a blocking
  call that needs the results iteration to run concurrently, not
  sequentially after it — both fixed in #20.
