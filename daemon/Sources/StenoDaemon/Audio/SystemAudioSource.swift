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
///
/// **U8: error-code-aware recovery.** This class is the
/// `SCStreamDelegate` for the underlying stream. When the stream stops
/// with an error, `stream(_:didStopWithError:)` classifies the SCStream
/// error code via `SystemAudioErrorClassifier` and dispatches:
///
///   - `.ignore` (e.g. `attemptToStopStreamState`) → no-op; backoff
///     counter does NOT advance.
///   - `.retry` → notify the recovery delegate; engine drives U5's
///     `restartSystemPipeline(reason:errorCode:)` with the stable
///     `domain#code` backoff key.
///   - `.permissionRevoked` (`userDeclined`) → notify the recovery
///     delegate; engine emits `recoveryExhausted` carrying the
///     load-bearing `MIC_OR_SCREEN_PERMISSION_REVOKED` token.
///
/// **SCStream weak-output gotcha:** SCStream retains stream outputs
/// weakly. The `streamOutput` property below is the strong reference
/// that keeps the output handler alive. Without this stored property
/// the output callback would be silently dropped and no audio would
/// flow.
public final class SystemAudioSource: NSObject, AudioSource, SCStreamDelegate, @unchecked Sendable {
    public let name = "System Audio"
    public let sourceType: AudioSourceType = .systemAudio

    /// Strongly-retained reference to the active SCStream. SCStream
    /// itself weakly references its output, which is why
    /// `streamOutput` below MUST also be a stored property.
    private var stream: SCStream?

    /// **Load-bearing strong reference.** SCStream retains
    /// `SCStreamOutput` weakly; if this property goes nil while the
    /// stream is live, the audio output handler is silently dropped
    /// and no buffers flow. Always non-nil between successful
    /// `start()` and the next `stop()` / `cleanup()` call.
    private var streamOutput: StreamOutputHandler?

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    private let queue = DispatchQueue(label: "com.steno.system-audio", qos: .userInteractive)

    /// Recovery-orchestration delegate (the engine). Weak — the engine
    /// owns the source through a strong reference, so a weak link back
    /// avoids the retain cycle.
    public weak var recoveryDelegate: SystemAudioRecoveryDelegate?

    public override init() {
        super.init()
    }

    public func start() async throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) {
        // 1. Get available content — triggers TCC permission dialog on first use.
        // U8: always fetch fresh. Cached `SCShareableContent` references
        // go stale across rebuilds; the plan's "Key Technical Decisions"
        // calls this out explicitly. The first call here is also the
        // "fresh fetch" the rebuild path needs.
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

        // 5. Create stream and output handler.
        // U8: pass `self` as the SCStream delegate so we receive
        // `stream(_:didStopWithError:)` callbacks. Pre-U8 this was nil
        // — meaning errors were silently dropped and the stream
        // appeared to "die" without recovery.
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = scStream

        let handler = StreamOutputHandler(format: format, continuation: continuation)
        // Stored property — load-bearing per SCStream weak-output
        // gotcha (see class doc).
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

    // MARK: - SCStreamDelegate (U8)

    /// SCStream delegate callback. Fires on the SCStream's internal
    /// delivery queue when the stream stops with an error.
    ///
    /// We classify the error and dispatch via the `recoveryDelegate`:
    ///
    ///   - `.ignore` (currently `attemptToStopStreamState`, -3808):
    ///     the stream stopped because we asked it to stop. No
    ///     recovery, no backoff advance.
    ///   - `.permissionRevoked` (`userDeclined`, -3801): tear down
    ///     local references and notify the engine that recovery is
    ///     exhausted (non-retryable).
    ///   - `.retry` (transient SCK errors): tear down local
    ///     references and notify the engine to drive U5's
    ///     `restartSystemPipeline` with the `domain#code` backoff key.
    ///
    /// Visible on `SCStream` via the delegate-weak protocol; this
    /// implementation is `nonisolated` to allow SCK to call it from
    /// any thread.
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Production path: classify the error, optionally tear down
        // local strong references, and notify the recovery delegate.
        // The classifier owns the dispatch table; see
        // `dispatchDelegateError(_:)` for the table.
        dispatchDelegateError(error)
    }

    /// Best-effort local teardown after a delegate error fires. The
    /// SCStream is already stopped (the delegate-error path means the
    /// system has already torn down its end), so we just nil the
    /// strong refs and finish the buffer continuation.
    private func tearDownAfterDelegateError() {
        stream = nil
        streamOutput = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Test seam

    /// Test-only entry point that mimics the SCStream's internal
    /// delivery queue invoking `stream(_:didStopWithError:)`. We can't
    /// synthesize a real `SCStream` instance in the unit-test target
    /// without Screen Recording permission, so this seam lets tests
    /// exercise the classifier-and-dispatch path against synthetic
    /// `NSError` values.
    ///
    /// **Production code MUST NOT call this method.** The real path
    /// is `SCStreamDelegate.stream(_:didStopWithError:)`.
    internal func handleStreamStopForTesting(error: any Error) {
        // We pass a placeholder via the SCStream parameter using
        // unsafeBitCast. The implementation never reads that parameter
        // — it only consumes `error`. Using `Optional<SCStream>.none`
        // forced-unwrapped would be incorrect; instead we call into
        // an internal classify-and-dispatch helper directly so the
        // test seam doesn't fabricate a fake SCStream.
        dispatchDelegateError(error)
    }

    /// Internal classify-and-dispatch path. Shared between the
    /// production `stream(_:didStopWithError:)` callback and the
    /// `handleStreamStopForTesting(error:)` seam.
    private func dispatchDelegateError(_ error: Error) {
        let action = SystemAudioErrorClassifier.classify(error)
        switch action {
        case .ignore:
            return

        case .permissionRevoked:
            tearDownAfterDelegateError()
            let delegate = self.recoveryDelegate
            Task {
                await delegate?.systemAudioPermissionRevoked()
            }

        case .retry:
            tearDownAfterDelegateError()
            let key = SystemAudioErrorClassifier.backoffKey(for: error)
            let reason = "scstream:\(key):\(error.localizedDescription)"
            let delegate = self.recoveryDelegate
            Task {
                await delegate?.systemAudioRequestsRetry(errorCode: key, reason: reason)
            }
        }
    }
}

// MARK: - Stream Output Handler

/// Receives audio sample buffers from ScreenCaptureKit and converts them
/// to AVAudioPCMBuffer for the speech recognizer pipeline.
///
/// **U8 note:** This type is held as a strong stored property on
/// `SystemAudioSource` (`streamOutput`). SCStream retains stream
/// outputs weakly, so the source must keep this reference alive for
/// the stream's lifetime — otherwise audio buffers stop flowing
/// silently.
final class StreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
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
