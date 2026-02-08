import AVFoundation
@testable import StenoDaemon

/// Mock recognizer handle that yields configurable results.
final class MockSpeechRecognizerHandle: SpeechRecognizerHandle, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<RecognizerResult, Error>.Continuation?
    private(set) var stopCalled = false

    /// Error to throw during transcription.
    var errorToThrow: Error?

    /// Results to yield immediately when transcribe is called.
    var resultsToYield: [RecognizerResult] = []

    func transcribe(buffers: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<RecognizerResult, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation

            if let error = self.errorToThrow {
                continuation.finish(throwing: error)
                return
            }

            for result in self.resultsToYield {
                continuation.yield(result)
            }
        }
    }

    func stop() async {
        stopCalled = true
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Test Helpers

    /// Emit a result to the active stream.
    func emit(_ result: RecognizerResult) {
        continuation?.yield(result)
    }

    /// Finish the stream with an error.
    func finishWithError(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    /// Finish the stream normally.
    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

/// Mock factory that creates MockSpeechRecognizerHandle instances.
final class MockSpeechRecognizerFactory: SpeechRecognizerFactory, @unchecked Sendable {
    /// The handle returned by makeRecognizer.
    let handle = MockSpeechRecognizerHandle()

    /// Error to throw from makeRecognizer.
    var factoryError: Error?

    /// Track calls.
    private(set) var recognizerCreated = false
    private(set) var lastLocale: Locale?

    func makeRecognizer(locale: Locale, format: AVAudioFormat)
        async throws -> SpeechRecognizerHandle {
        recognizerCreated = true
        lastLocale = locale

        if let error = factoryError {
            throw error
        }

        return handle
    }
}
