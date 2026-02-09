@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Real speech recognizer factory using macOS 26 SpeechAnalyzer API.
public final class DefaultSpeechRecognizerFactory: SpeechRecognizerFactory, Sendable {
    public init() {}

    public func makeRecognizer(locale: Locale, format: AVAudioFormat, source: AudioSourceType)
        async throws -> SpeechRecognizerHandle {
        DefaultSpeechRecognizerHandle(locale: locale, inputFormat: format, source: source)
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
    private let inputFormat: AVAudioFormat
    private let source: AudioSourceType
    private let analyzerRef = AnalyzerRef()

    init(locale: Locale, inputFormat: AVAudioFormat, source: AudioSourceType) {
        self.locale = locale
        self.inputFormat = inputFormat
        self.source = source
    }

    func transcribe(buffers: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<RecognizerResult, Error> {
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

        let pipeline = Pipeline(
            buffers: buffers,
            inputFormat: inputFormat,
            source: source,
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
    let inputFormat: AVAudioFormat
    let source: AudioSourceType
    let locale: Locale
    let inputSequence: AsyncStream<AnalyzerInput>
    let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    let analyzerRef: AnalyzerRef

    func run(continuation: AsyncThrowingStream<RecognizerResult, Error>.Continuation) async {
        // Query the format SpeechAnalyzer expects on @MainActor (Speech framework
        // calls must stay on the main actor in CLI executables).
        let analyzerFormat = await Task { @MainActor in
            await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [SpeechTranscriber(
                    locale: self.locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                )]
            )
        }.value
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

                // Task 2: Construct Speech objects on @MainActor, start the
                // analyzer, and iterate results — ALL on @MainActor.
                // MUST start BEFORE analyzer.start() because start() blocks
                // until the input stream ends.
                // CLI executables crash with SIGTRAP if any Speech framework
                // work happens off the main actor.
                group.addTask {
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
                            // #64: carry the result's audio time range (analyzer
                            // input timeline) so segments can be joined to
                            // diarization windows on the frame-accurate capture
                            // clock. CMTimeGetSeconds yields NaN for an invalid
                            // range → treated as unavailable (nil).
                            let startSeconds = CMTimeGetSeconds(result.range.start)
                            let durationSeconds = CMTimeGetSeconds(result.range.duration)
                            continuation.yield(RecognizerResult(
                                text: text,
                                isFinal: result.isFinal,
                                source: self.source,
                                audioStartSeconds: startSeconds.isFinite ? startSeconds : nil,
                                audioDurationSeconds: durationSeconds.isFinite ? durationSeconds : nil
                            ))
                        }
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
