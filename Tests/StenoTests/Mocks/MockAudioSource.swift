import AVFoundation
@testable import Steno

/// Mock implementation of AudioSource for testing.
final class MockAudioSource: AudioSource, @unchecked Sendable {
    let name: String
    let sourceType: AudioSourceType

    private(set) var startCalled = false
    private(set) var stopCalled = false

    /// Error to throw when start() is called, if set.
    var errorToThrow: Error?

    /// The format returned by start(). Defaults to 16kHz mono Float32.
    var format: AVAudioFormat

    /// Continuation for sending buffers to the consumer.
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    init(
        name: String = "Mock Audio",
        sourceType: AudioSourceType = .systemAudio
    ) {
        self.name = name
        self.sourceType = sourceType
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    func start() async throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) {
        startCalled = true

        if let error = errorToThrow {
            throw error
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        return (buffers: stream, format: format)
    }

    func stop() async {
        stopCalled = true
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Test Helpers

    /// Sends a buffer to the consumer.
    func emit(_ buffer: AVAudioPCMBuffer) {
        nonisolated(unsafe) let unsafeBuffer = buffer
        continuation?.yield(unsafeBuffer)
    }

    /// Finishes the buffer stream.
    func finish() {
        continuation?.finish()
        continuation = nil
    }

    /// Resets all state for a new test.
    func reset() {
        startCalled = false
        stopCalled = false
        errorToThrow = nil
        continuation = nil
    }
}
