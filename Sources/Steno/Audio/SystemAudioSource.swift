import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Errors specific to system audio capture.
public enum SystemAudioError: Error, Equatable {
    case noDisplaysAvailable
    case streamStartFailed(String)
    case permissionDenied
}

/// Captures system audio using ScreenCaptureKit.
///
/// Captures all system audio except Steno's own process. Uses SCStream
/// which properly integrates with macOS TCC permissions and shows the
/// recording indicator in the menu bar.
/// Conforms to `AudioSource` for use alongside the microphone recognizer.
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let name = "System Audio"
    public let sourceType: AudioSourceType = .systemAudio

    private var stream: SCStream?
    private var streamOutput: StreamOutputHandler?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    private let queue = DispatchQueue(label: "com.steno.system-audio", qos: .userInteractive)

    public init() {}

    public func start() async throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) {
        // 1. Get available content — triggers TCC permission dialog on first use
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw SystemAudioError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplaysAvailable
        }

        // 2. Create content filter (all apps on main display)
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        // 3. Configure stream for audio capture
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // Audio format: 48kHz stereo Float32 non-interleaved (ScreenCaptureKit default)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ) else {
            throw SystemAudioError.streamStartFailed("Failed to create audio format")
        }

        // 4. Create async stream for buffer delivery
        let (bufferStream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation

        // 5. Create stream and output handler
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = scStream

        let handler = StreamOutputHandler(format: format, continuation: continuation)
        self.streamOutput = handler

        try scStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: queue)

        // 6. Start capture
        do {
            try await scStream.startCapture()
        } catch {
            cleanup()
            throw SystemAudioError.streamStartFailed(error.localizedDescription)
        }

        return (buffers: bufferStream, format: format)
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        continuation?.finish()
        continuation = nil
    }

    private func cleanup() {
        stream = nil
        streamOutput = nil
        continuation?.finish()
        continuation = nil
    }

    deinit {
        stream = nil
        streamOutput = nil
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - Stream Output Handler

/// Receives audio sample buffers from ScreenCaptureKit and converts them
/// to AVAudioPCMBuffer for the speech recognizer pipeline.
private final class StreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    init(format: AVAudioFormat, continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let buffer = convertToPCMBuffer(sampleBuffer) else { return }
        nonisolated(unsafe) let unsafeBuffer = buffer
        continuation.yield(unsafeBuffer)
    }

    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Get raw audio data pointer from the CMBlockBuffer
        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &dataLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let srcPtr = dataPointer else { return nil }

        // ScreenCaptureKit delivers non-interleaved Float32 audio.
        // Copy each channel's data into the PCM buffer's separate channel buffers.
        let dstBufferList = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let bytesPerChannel = dataLength / Int(format.channelCount)

        for i in 0..<min(Int(format.channelCount), dstBufferList.count) {
            guard let dstData = dstBufferList[i].mData else { continue }
            let srcOffset = i * bytesPerChannel
            memcpy(dstData, srcPtr.advanced(by: srcOffset), bytesPerChannel)
        }

        return pcmBuffer
    }
}
