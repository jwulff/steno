@preconcurrency import AVFoundation
import Foundation
import Speech

/// Real speech recognizer factory using macOS 26 SpeechAnalyzer API.
public final class DefaultSpeechRecognizerFactory: SpeechRecognizerFactory, Sendable {
    public init() {}

    public func makeRecognizer(locale: Locale, format: AVAudioFormat)
        async throws -> SpeechRecognizerHandle {
        DefaultSpeechRecognizerHandle(locale: locale, inputFormat: format)
    }
}

/// Real speech recognizer handle wrapping SpeechAnalyzer.
///
/// Uses `@unchecked Sendable` because `SpeechAnalyzer` and `SpeechTranscriber`
/// are not yet marked Sendable by Apple. Access is serialized: `transcribe` sets
/// up state synchronously, then a single Task drives the pipeline.
final class DefaultSpeechRecognizerHandle: SpeechRecognizerHandle, @unchecked Sendable {
    private let locale: Locale
    private let inputFormat: AVAudioFormat
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    init(locale: Locale, inputFormat: AVAudioFormat) {
        self.locale = locale
        self.inputFormat = inputFormat
    }

    func transcribe(buffers: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<RecognizerResult, Error> {
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

        let pipeline = Pipeline(
            buffers: buffers,
            inputFormat: inputFormat,
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
    let inputFormat: AVAudioFormat
    let analyzer: SpeechAnalyzer
    let transcriber: SpeechTranscriber
    let inputSequence: AsyncStream<AnalyzerInput>
    let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

    func run(continuation: AsyncThrowingStream<RecognizerResult, Error>.Continuation) async {
        // Get the format SpeechAnalyzer expects and create a converter if needed.
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        )
        let converter: AVAudioConverter? = if let analyzerFormat, inputFormat != analyzerFormat {
            AVAudioConverter(from: inputFormat, to: analyzerFormat)
        } else {
            nil
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Task 1: Feed audio buffers, converting format if needed.
                group.addTask {
                    for await buffer in self.buffers {
                        if let converter, let targetFormat = analyzerFormat {
                            let ratio = targetFormat.sampleRate / self.inputFormat.sampleRate
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
                                self.inputBuilder.yield(AnalyzerInput(buffer: converted))
                            }
                        } else {
                            self.inputBuilder.yield(AnalyzerInput(buffer: buffer))
                        }
                    }
                    self.inputBuilder.finish()
                }

                // Task 2: Listen for transcription results.
                // MUST start BEFORE analyzer.start() because start() blocks
                // until the input stream ends.
                group.addTask {
                    for try await result in self.transcriber.results {
                        let text = String(result.text.characters)
                        continuation.yield(RecognizerResult(
                            text: text,
                            isFinal: result.isFinal,
                            source: .microphone
                        ))
                    }
                }

                // Task 3: Start the analyzer on @MainActor.
                // SpeechAnalyzer MUST run on @MainActor — crashes with
                // SIGTRAP otherwise.
                group.addTask {
                    try await Task { @MainActor in
                        try await self.analyzer.start(inputSequence: self.inputSequence)
                    }.value
                }

                try await group.waitForAll()
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
