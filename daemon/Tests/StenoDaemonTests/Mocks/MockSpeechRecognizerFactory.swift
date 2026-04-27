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
///
/// Two modes of operation:
///   1. *Single-handle mode (default):* `micHandle` and `sysHandle` are
///      reused for every `makeRecognizer` call. Existing tests rely on
///      this — a single, persistent handle they can drive directly.
///   2. *Per-call queue mode (U5+):* If a test enqueues handles via
///      `enqueueMicHandle(_:)` / `enqueueSysHandle(_:)`, the factory
///      returns one handle per `makeRecognizer` call from that queue.
///      Used for restart-with-backoff tests where the first handle
///      throws, then a fresh handle is brought up on the rebuild.
final class MockSpeechRecognizerFactory: SpeechRecognizerFactory, @unchecked Sendable {
    /// Per-source handles for dual-source tests (single-handle mode).
    let micHandle = MockSpeechRecognizerHandle()
    let sysHandle = MockSpeechRecognizerHandle()

    /// Backward-compatible handle — returns micHandle for existing single-source tests.
    var handle: MockSpeechRecognizerHandle { micHandle }

    /// Error to throw from makeRecognizer.
    var factoryError: Error?

    /// Track calls.
    private(set) var recognizerCreated = false
    private(set) var lastLocale: Locale?

    private(set) var lastSource: AudioSourceType?

    /// Total number of `makeRecognizer` calls, regardless of source.
    private(set) var makeRecognizerCallCount: Int = 0
    /// Per-source call counts.
    private(set) var micMakeCount: Int = 0
    private(set) var sysMakeCount: Int = 0

    /// Optional queues of per-call handles. When non-empty for a given
    /// source, each `makeRecognizer` call dequeues the next handle
    /// instead of returning the persistent `micHandle` / `sysHandle`.
    private var micHandleQueue: [MockSpeechRecognizerHandle] = []
    private var sysHandleQueue: [MockSpeechRecognizerHandle] = []

    func enqueueMicHandle(_ handle: MockSpeechRecognizerHandle) {
        micHandleQueue.append(handle)
    }

    func enqueueSysHandle(_ handle: MockSpeechRecognizerHandle) {
        sysHandleQueue.append(handle)
    }

    /// All mic handles produced so far (queue mode), in order.
    private(set) var producedMicHandles: [MockSpeechRecognizerHandle] = []
    /// All sys handles produced so far (queue mode), in order.
    private(set) var producedSysHandles: [MockSpeechRecognizerHandle] = []

    func makeRecognizer(locale: Locale, format: AVAudioFormat, source: AudioSourceType)
        async throws -> SpeechRecognizerHandle {
        recognizerCreated = true
        lastLocale = locale
        lastSource = source
        makeRecognizerCallCount += 1

        if let error = factoryError {
            throw error
        }

        switch source {
        case .microphone:
            micMakeCount += 1
            if !micHandleQueue.isEmpty {
                let next = micHandleQueue.removeFirst()
                producedMicHandles.append(next)
                return next
            }
            return micHandle
        case .systemAudio:
            sysMakeCount += 1
            if !sysHandleQueue.isEmpty {
                let next = sysHandleQueue.removeFirst()
                producedSysHandles.append(next)
                return next
            }
            return sysHandle
        }
    }
}
