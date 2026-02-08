import Foundation
@testable import StenoDaemon

/// Mock implementation of SpeechRecognitionService for testing.
/// Uses @MainActor to avoid concurrency issues in tests.
@MainActor
final class MockSpeechService: SpeechRecognitionService {
    private var _isListening = false
    private var continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation?

    /// Results to emit when transcription starts.
    var resultsToEmit: [TranscriptionResult] = []

    /// Error to throw when starting transcription.
    var errorToThrow: Error?

    /// Tracks if startTranscription was called.
    private(set) var startCalled = false

    /// Tracks if stopTranscription was called.
    private(set) var stopCalled = false

    /// The locale passed to startTranscription.
    private(set) var lastLocale: Locale?

    nonisolated var isListening: Bool {
        false // Will be updated via MainActor context
    }

    var isListeningActual: Bool {
        _isListening
    }

    nonisolated func startTranscription(locale: Locale) -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                self.startCalled = true
                self.lastLocale = locale
                self.continuation = continuation

                if let error = self.errorToThrow {
                    continuation.finish(throwing: error)
                    return
                }

                self._isListening = true

                for result in self.resultsToEmit {
                    continuation.yield(result)
                }
            }
        }
    }

    nonisolated func stopTranscription() async {
        await MainActor.run {
            self.stopCalled = true
            self._isListening = false
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    // MARK: - Test Helpers

    /// Emits a result to the current stream.
    func emit(_ result: TranscriptionResult) {
        continuation?.yield(result)
    }

    /// Finishes the stream with an error.
    func finishWithError(_ error: Error) {
        continuation?.finish(throwing: error)
        _isListening = false
    }

    /// Finishes the stream successfully.
    func finish() {
        continuation?.finish()
        _isListening = false
    }

    /// Resets all state for a new test.
    func reset() {
        _isListening = false
        continuation = nil
        resultsToEmit = []
        errorToThrow = nil
        startCalled = false
        stopCalled = false
        lastLocale = nil
    }
}
