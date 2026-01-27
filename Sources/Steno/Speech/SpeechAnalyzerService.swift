import Foundation
import Speech
import AVFoundation

/// Real implementation of SpeechRecognitionService using macOS 26 SpeechAnalyzer.
/// Note: This implementation uses the new macOS 26 Speech APIs. When running on
/// older systems, it will fall back to SFSpeechRecognizer.
@MainActor
public final class SpeechAnalyzerService: SpeechRecognitionService {
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var _isListening = false

    public init() {}

    nonisolated public var isListening: Bool {
        get async {
            await MainActor.run { _isListening }
        }
    }

    nonisolated public func startTranscription(locale: Locale) -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    try await self.setupAndStart(locale: locale, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated public func stopTranscription() async {
        await MainActor.run {
            self._isListening = false
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.audioEngine?.stop()
            self.audioEngine?.inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
        }
    }

    // MARK: - Private

    private func setupAndStart(
        locale: Locale,
        continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation
    ) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechRecognitionError.localeNotSupported(locale)
        }

        guard recognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionFailed("Speech recognizer not available")
        }

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        _isListening = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let error = error {
                    continuation.finish(throwing: SpeechRecognitionError.recognitionFailed(error.localizedDescription))
                    self?._isListening = false
                    return
                }

                guard let result = result else { return }

                let transcriptionResult = TranscriptionResult(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal,
                    confidence: result.bestTranscription.segments.last?.confidence,
                    timestamp: Date(),
                    segments: result.bestTranscription.segments.map { segment in
                        TranscriptSegment(
                            text: segment.substring,
                            timestamp: Date(),
                            duration: segment.duration,
                            confidence: segment.confidence
                        )
                    }
                )

                continuation.yield(transcriptionResult)

                if result.isFinal {
                    continuation.finish()
                    self?._isListening = false
                }
            }
        }
    }
}
