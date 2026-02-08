import AVFoundation
@testable import StenoDaemon

/// Mock factory that returns configurable audio sources.
final class MockAudioSourceFactory: AudioSourceFactory, @unchecked Sendable {
    /// Continuation for sending mic buffers.
    private var micContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Error to throw from makeMicrophoneSource.
    var micError: Error?

    /// The mock system audio source returned by makeSystemAudioSource.
    let systemAudioSource = MockAudioSource(name: "Mock System Audio", sourceType: .systemAudio)

    /// Track calls.
    private(set) var micSourceCreated = false
    private(set) var systemSourceCreated = false
    private(set) var lastDevice: String?

    /// Default mic format: 16kHz mono.
    let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    func makeMicrophoneSource(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void) {
        micSourceCreated = true
        lastDevice = device

        if let error = micError {
            throw error
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.micContinuation = continuation

        let stop: @Sendable () async -> Void = { [weak self] in
            self?.micContinuation?.finish()
        }

        return (buffers: stream, format: micFormat, stop: stop)
    }

    func makeSystemAudioSource() -> AudioSource {
        systemSourceCreated = true
        return systemAudioSource
    }

    // MARK: - Test Helpers

    /// Emit a mic buffer.
    func emitMicBuffer(_ buffer: AVAudioPCMBuffer) {
        nonisolated(unsafe) let unsafeBuffer = buffer
        micContinuation?.yield(unsafeBuffer)
    }

    /// Finish the mic stream.
    func finishMicStream() {
        micContinuation?.finish()
        micContinuation = nil
    }
}
