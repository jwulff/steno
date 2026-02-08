import AVFoundation

/// Factory for creating audio sources.
///
/// Abstracts the creation of microphone and system audio sources
/// so that tests can inject mock implementations.
public protocol AudioSourceFactory: Sendable {
    /// Create a microphone audio source.
    ///
    /// - Parameter device: Optional device identifier. Uses default if nil.
    /// - Returns: A tuple of buffer stream, audio format, and a stop closure.
    func makeMicrophoneSource(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void)

    /// Create a system audio source.
    ///
    /// - Returns: An AudioSource for system audio capture.
    func makeSystemAudioSource() -> AudioSource
}
