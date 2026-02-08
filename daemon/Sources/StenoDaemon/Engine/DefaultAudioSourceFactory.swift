@preconcurrency import AVFoundation

/// Real audio source factory using system APIs.
public final class DefaultAudioSourceFactory: AudioSourceFactory, Sendable {
    public init() {}

    public func makeMicrophoneSource(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void) {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            nonisolated(unsafe) let unsafeBuffer = buffer
            continuation.yield(unsafeBuffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        nonisolated(unsafe) let unsafeEngine = audioEngine
        let stop: @Sendable () async -> Void = {
            unsafeEngine.stop()
            unsafeEngine.inputNode.removeTap(onBus: 0)
            continuation.finish()
        }

        return (buffers: stream, format: format, stop: stop)
    }

    public func makeSystemAudioSource() -> AudioSource {
        SystemAudioSource()
    }
}
