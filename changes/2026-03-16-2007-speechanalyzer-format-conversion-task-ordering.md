# SpeechAnalyzer SIGTRAP: format conversion + concurrent task ordering (PR #20)

## Why

After #14 (main RunLoop + `@MainActor`), #18 (drop the restricted
entitlement), and #19 (drop the legacy permission check), the daemon
finally launched and started feeding audio. But the first real
microphone buffer triggered a *second* SIGTRAP inside
`Speech.framework` — different precondition than #14, same crash
signature.

Investigation found two independent bugs in
`DefaultSpeechRecognizerFactory.Pipeline.run()` that had been
sitting latent the whole time:

### Bug 1: Audio format mismatch

The microphone delivers 48kHz mono `Float32` buffers (the default
output of `AVAudioEngine`'s input tap). The pipeline was feeding
those buffers straight into `AnalyzerInput` and handing them to
`SpeechAnalyzer`.

But `SpeechAnalyzer` is internally pinned to **16kHz mono** for the
SpeechTranscriber module. Feeding it 48kHz audio trips a precondition
inside the framework and crashes with SIGTRAP — same crash class as
#14, completely different cause.

The legacy monolith code path had handled this with an
`AudioTapProcessor` that ran an `AVAudioConverter` in front of the
analyzer. The daemon's extraction in #11 had not carried that step
over.

### Bug 2: `analyzer.start()` is a blocking call, treated as fire-and-forget

The pipeline used a `withThrowingTaskGroup` with two child tasks:

- Task A: feed `AVAudioPCMBuffer`s into the analyzer's input stream
- Task B: call `analyzer.start(inputSequence:)` and then iterate
  `transcriber.results`

The bug: `analyzer.start(inputSequence:)` **blocks the calling task
until the input stream finishes**. It is not a "kick off and return"
call — it owns the task for the entire recording session. Because
Task B awaited `start()` and *then* tried to iterate
`transcriber.results`, the results iteration never ran while audio
was being processed. By the time `start()` returned, the stream
was over and there was nothing to iterate.

This wouldn't have caused a SIGTRAP on its own, but combined with
the format-mismatch crash it made debugging confusing: the results
listener was never reached, so logs showed only the buffer feeder
running and then a hard crash. The fix has to address both — even
once the format is right, results-iteration sequenced after
`start()` is a silent hang.

## How

Both bugs are fixed inside `Pipeline.run()`.

### 1. Format conversion via `bestAvailableAudioFormat` + `AVAudioConverter`

At the top of the run, query `SpeechAnalyzer` for the format it
actually wants for the configured `SpeechTranscriber`, and build a
converter if the input format doesn't match:

```swift
let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
    compatibleWith: [transcriber]
)
let converter: AVAudioConverter? = if let analyzerFormat,
                                      inputFormat != analyzerFormat {
    AVAudioConverter(from: inputFormat, to: analyzerFormat)
} else {
    nil
}
```

Then in the buffer-feeder task, convert each buffer if a converter
is present:

```swift
for await buffer in self.buffers {
    if let converter, let targetFormat = analyzerFormat {
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * ratio
        )
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else { continue }

        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
        }
        if error == nil {
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }
    } else {
        inputBuilder.yield(AnalyzerInput(buffer: buffer))
    }
}
```

The `bestAvailableAudioFormat` query is the correct way to ask
the analyzer what it wants — not a hard-coded 16kHz constant,
because the answer could in principle vary by transcriber
configuration or future macOS versions.

The recognizer factory's API also changed:
`makeRecognizer(locale:format:)` now passes `format` as
`inputFormat:` into the handle, making the name match its actual
role (the format coming *into* the pipeline, not the format
`SpeechAnalyzer` consumes).

### 2. Three concurrent tasks, no sequencing

The task group now has three tasks running in parallel, not
sequenced via `await`:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    // Task 1: feed audio buffers (with format conversion)
    group.addTask { /* see above */ }

    // Task 2: iterate transcriber.results
    // MUST start BEFORE analyzer.start() because start() blocks
    // until the input stream ends.
    group.addTask {
        for try await result in self.transcriber.results {
            let text = String(result.text.characters)
            continuation.yield(RecognizerResult(...))
        }
    }

    // Task 3: drive analyzer.start() on @MainActor
    // SpeechAnalyzer MUST run on @MainActor — crashes with
    // SIGTRAP otherwise.
    group.addTask {
        try await Task { @MainActor in
            try await self.analyzer.start(inputSequence: self.inputSequence)
        }.value
    }

    try await group.waitForAll()
}
```

The previous `group.next()` + `cancelAll()` pattern is replaced
with `waitForAll()` because all three tasks now run for the full
session — feeder until the buffer stream finishes, results
iterator until the transcriber finishes, analyzer until the input
stream ends. They all complete together.

The `@MainActor` wrapping of `analyzer.start()` from #14 is
preserved; this PR adds the *other* concurrency requirement
alongside it.

## Key Decisions

- **Query `bestAvailableAudioFormat` instead of hardcoding 16kHz.**
  The framework can in principle change what it wants, and the
  query is cheap. Hardcoding the format would be wrong-by-default
  the day Apple introduces a higher-rate transcriber.
- **Convert in the feeder task, not at the audio-source layer.**
  Different audio sources (mic vs system audio) have different
  native formats. Putting the conversion immediately before
  `AnalyzerInput` keeps the conversion logic adjacent to the
  consumer's requirements. Audio sources stay format-honest.
- **Three concurrent tasks, no sequencing.** `analyzer.start()`
  blocks for the lifetime of the recording — treat it as a
  long-running peer to the feeder and the results iterator, not
  as a setup step. Sequencing it before the results iterator
  guarantees zero output.
- **`waitForAll()` over `next()` + `cancelAll()`.** The previous
  pattern assumed the analyzer task would finish first and the
  feeder could then be cancelled. With three peer tasks all
  running for the full session, the natural completion order is
  buffer-stream-ends → analyzer-returns →
  transcriber-results-finishes, and `waitForAll()` captures any
  thrown error from any task without us needing to choose which
  to await first.
- **Don't fall back to legacy `SFSpeechRecognizer`.** Same rule as
  #14: when SpeechAnalyzer crashes, fix the runtime contract
  (format, threading, task ordering). Never downgrade.

## Testing

- All 169 daemon tests pass (Swift Testing framework)
- The factory's protocol is exercised by `MockSpeechRecognizerFactory`
  in integration tests; the format conversion is exercised by manual
  smoke test (`make run-daemon` followed by recording from the TUI)
- Verified absence of SIGTRAP across a multi-minute recording with
  both mic-only and mic+system-audio modes

[steno-tests-passed: 169 tests in 0.7s]

## What's Next

This is the last fix in the SpeechAnalyzer-debugging arc that began
in #14. With #14 + #18 + #19 + #20 together, the daemon:

- Launches without SIGKILL (correct entitlements, ad-hoc signing)
- Passes its permission check (microphone only, no legacy speech check)
- Starts `SpeechAnalyzer` on `@MainActor` under a live main RunLoop
- Feeds it 16kHz mono buffers in the format it actually wants
- Iterates `transcriber.results` concurrently with `start()`

The combined ruleset is preserved in `CLAUDE.md`'s "macOS 26 Speech
API Notes", "Anti-Patterns", and the build-system warning about
`com.apple.developer.speech-recognition`. Future regressions in any
of these dimensions should be diagnosed against this file plus the
three companion change docs, not by hopping back to
`SFSpeechRecognizer`.

Followups from here are feature work (multi-source recognizer pairs,
NDJSON event consolidation, MCP server, always-on recording) rather
than further crashes on the recognition critical path.
