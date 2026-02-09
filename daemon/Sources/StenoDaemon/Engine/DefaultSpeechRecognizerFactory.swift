@preconcurrency import AVFoundation
import Foundation
import Speech

/// Real speech recognizer factory using macOS 26 SpeechAnalyzer API.
public final class DefaultSpeechRecognizerFactory: SpeechRecognizerFactory, Sendable {
    public init() {}

    public func makeRecognizer(locale: Locale, format: AVAudioFormat)
        async throws -> SpeechRecognizerHandle {
        DefaultSpeechRecognizerHandle(locale: locale, format: format)
    }
}

/// Shared reference so the handle's `stop()` can reach the analyzer
/// created on `@MainActor` inside `Pipeline.run()`.
private final class AnalyzerRef: @unchecked Sendable {
    var analyzer: SpeechAnalyzer?
}

/// Real speech recognizer handle wrapping SpeechAnalyzer.
///
/// ALL Speech framework interaction (construction, start, results iteration,
/// finalization) runs on `@MainActor`. CLI executables crash with SIGTRAP
/// if any Speech framework work happens off the main actor.
final class DefaultSpeechRecognizerHandle: SpeechRecognizerHandle, @unchecked Sendable {
    private let locale: Locale
    private let format: AVAudioFormat
    private let analyzerRef = AnalyzerRef()

    init(locale: Locale, format: AVAudioFormat) {
        self.locale = locale
        self.format = format
    }

    func transcribe(buffers: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<RecognizerResult, Error> {
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        let pipeline = Pipeline(
            buffers: buffers,
            locale: locale,
            inputSequence: inputSequence,
            inputBuilder: inputBuilder,
            analyzerRef: analyzerRef
        )

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                await pipeline.run(continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func stop() async {
        do {
            try await Task { @MainActor in
                try await self.analyzerRef.analyzer?.finalizeAndFinishThroughEndOfInput()
            }.value
        } catch {
            // Ignore cleanup errors
        }
        analyzerRef.analyzer = nil
    }
}

/// Packages pipeline state into a Sendable value that can cross
/// the `sending` boundary of `Task.detached` without capture issues.
///
/// Speech framework objects are created inside `run()` on `@MainActor`,
/// not passed in from outside.
private struct Pipeline: @unchecked Sendable {
    let buffers: AsyncStream<AVAudioPCMBuffer>
    let locale: Locale
    let inputSequence: AsyncStream<AnalyzerInput>
    let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    let analyzerRef: AnalyzerRef

    func run(continuation: AsyncThrowingStream<RecognizerResult, Error>.Continuation) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await buffer in self.buffers {
                        self.inputBuilder.yield(AnalyzerInput(buffer: buffer))
                    }
                    self.inputBuilder.finish()
                }

                group.addTask {
                    // ALL Speech framework work MUST happen on @MainActor —
                    // construction, start, and results iteration.
                    // CLI executables crash with SIGTRAP otherwise.
                    try await Task { @MainActor in
                        let transcriber = SpeechTranscriber(
                            locale: self.locale,
                            transcriptionOptions: [],
                            reportingOptions: [.volatileResults],
                            attributeOptions: []
                        )
                        let analyzer = SpeechAnalyzer(modules: [transcriber])
                        self.analyzerRef.analyzer = analyzer

                        try await analyzer.start(inputSequence: self.inputSequence)

                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            continuation.yield(RecognizerResult(
                                text: text,
                                isFinal: result.isFinal,
                                source: .microphone
                            ))
                        }
                    }.value
                }

                // Wait for the results stream to finish, then cancel the feeder
                try await group.next()
                group.cancelAll()
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
