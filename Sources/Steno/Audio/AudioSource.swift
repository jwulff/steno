import AVFoundation

/// Protocol for audio input sources that provide PCM audio buffers.
///
/// Implementations include `SystemAudioSource` (Core Audio Taps) and `MockAudioSource` (testing).
/// The microphone path does NOT conform to this protocol in v1 -- it stays in ViewState.
public protocol AudioSource: Sendable {
    /// Human-readable name for this source (e.g., "System Audio").
    var name: String { get }

    /// The type of audio this source captures.
    var sourceType: AudioSourceType { get }

    /// Starts capture. Returns audio buffers and the format they arrive in.
    /// Consumer needs the format for SpeechAnalyzer setup.
    func start() async throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat)

    /// Stops capture and cleans up resources. Silently handles cleanup errors.
    func stop() async
}
