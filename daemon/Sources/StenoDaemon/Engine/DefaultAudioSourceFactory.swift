@preconcurrency import AVFoundation

/// Real audio source factory using system APIs.
///
/// As of U7, the microphone path is implemented by
/// `MicrophoneAudioSource` (which owns its own `AVAudioEngine` and is
/// rebuilt on every config-change). The factory builds a fresh
/// `MicrophoneAudioSource` per call and delegates to its
/// `start(device:)`, preserving the existing
/// `(buffers, format, stop)` tuple shape so `RecordingEngine` consumes
/// it unchanged.
public final class DefaultAudioSourceFactory: AudioSourceFactory, Sendable {
    public init() {}

    public func makeMicrophoneSource(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void) {
        let mic = MicrophoneAudioSource()
        return try await mic.start(device: device)
    }

    public func makeSystemAudioSource() -> AudioSource {
        SystemAudioSource()
    }
}
