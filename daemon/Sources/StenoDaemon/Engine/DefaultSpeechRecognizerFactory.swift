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

/// Real speech recognizer handle wrapping SpeechAnalyzer.
///
/// Uses `@unchecked Sendable` because `SpeechAnalyzer` and `SpeechTranscriber`
/// are not yet marked Sendable by Apple. Access is serialized: `transcribe` sets
/// up state synchronously, then a single Task drives the pipeline.
final class DefaultSpeechRecognizerHandle: SpeechRecognizerHandle, @unchecked Sendable {
    private let locale: Locale
    private let format: AVAudioFormat
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    init(locale: Locale, format: AVAudioFormat) {
        self.locale = locale
        self.format = format
    }

    func transcribe(buffers: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<RecognizerResult, Error> {
        // Set up all Speech framework objects synchronously.
        let transcriber = SpeechTranscriber(
            locale: self.locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        // Package everything into a Sendable struct so a single `sending`
        // boundary transfer is clean.
        let pipeline = Pipeline(
            buffers: buffers,
            analyzer: analyzer,
            transcriber: transcriber,
            inputSequence: inputSequence,
            inputBuilder: inputBuilder
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
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Ignore cleanup errors
        }
        analyzer = nil
        transcriber = nil
    }
}

/// Packages all pipeline state into a Sendable value that can cross
/// the `sending` boundary of `Task.detached` without capture issues.
private struct Pipeline: @unchecked Sendable {
    let buffers: AsyncStream<AVAudioPCMBuffer>
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let inputSequence: AsyncStream<AnalyzerInput>
    let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

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
                    try await self.analyzer.start(inputSequence: self.inputSequence)

                    for try await result in self.transcriber.results {
                        let text = String(result.text.characters)
                        continuation.yield(RecognizerResult(
                            text: text,
                            isFinal: result.isFinal,
                            source: .microphone
                        ))
                    }
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
