@preconcurrency import AVFoundation
import Foundation

/// Microphone audio source backed by `AVAudioEngine`.
///
/// Extracted from `DefaultAudioSourceFactory` (U7) so the rebuild path
/// driven by `AVAudioEngine.configurationChangeNotification` has a clean
/// owner. Each `start(device:)` call builds a fresh `AVAudioEngine` —
/// per the plan's "Key Technical Decisions": **AVAudioEngine: full
/// rebuild on configuration change, not in-place mutation.**
///
/// The engine instance and the installed tap closure are held as
/// stored properties so they survive the lifetime of the active
/// session. (The SCStream weak-output gotcha applies in spirit: a tap
/// callback that disappears under us would silently stop delivering
/// buffers.)
///
/// This class deliberately does NOT conform to `AudioSource`. The
/// existing `AudioSource` protocol returns `(buffers, format)` and a
/// separate `stop()` method, but the engine's mic-bringup site has
/// always expected a `(buffers, format, stop-closure)` tuple — see
/// `AudioSourceFactory.makeMicrophoneSource(device:)`. Keeping that
/// shape minimizes invasiveness in `RecordingEngine` while the U7
/// observer wiring lands.
public final class MicrophoneAudioSource: @unchecked Sendable {

    // MARK: - Stored state (strongly retained)

    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var currentDeviceUIDValue: String?
    private var currentFormatValue: AVAudioFormat?

    /// Resolves the current default-input device UID. Production
    /// injects `defaultInputDeviceUID()` from `CoreAudioDevice.swift`;
    /// tests inject a closure returning a synthetic UID.
    private let deviceUIDProvider: @Sendable () -> String?

    public init(deviceUIDProvider: @Sendable @escaping () -> String? = { defaultInputDeviceUID() }) {
        self.deviceUIDProvider = deviceUIDProvider
    }

    // MARK: - Lifecycle

    /// Bring up the mic pipeline. Builds a fresh `AVAudioEngine`,
    /// installs a tap on the input node, and returns an async stream
    /// of PCM buffers plus the resolved input format and a stop
    /// closure that tears the engine down.
    ///
    /// - Parameter device: Optional audio device identifier. The
    ///   underlying AVAudioEngine API does not currently route to a
    ///   specific device — the parameter is preserved for protocol
    ///   compatibility with the legacy `makeMicrophoneSource(device:)`
    ///   shape. The device UID captured by `currentDeviceUID()`
    ///   reflects whichever input device the system has selected as
    ///   default at start time.
    public func start(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void) {

        // Stop any existing engine — defensive; callers should be
        // calling `start` against a fresh `MicrophoneAudioSource`
        // instance, but a re-entrant `start` should not leak the
        // previous engine.
        await stopInternal()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            nonisolated(unsafe) let unsafeBuffer = buffer
            continuation.yield(unsafeBuffer)
        }

        engine.prepare()
        try engine.start()

        self.audioEngine = engine
        self.continuation = continuation
        self.currentFormatValue = format
        self.currentDeviceUIDValue = deviceUIDProvider()

        nonisolated(unsafe) let unsafeEngine = engine
        let stop: @Sendable () async -> Void = { [weak self] in
            unsafeEngine.stop()
            unsafeEngine.inputNode.removeTap(onBus: 0)
            continuation.finish()
            await self?.clearOnStop(engine: unsafeEngine)
        }

        return (buffers: stream, format: format, stop: stop)
    }

    /// Tear down the current engine without rebuilding.
    public func stop() async {
        await stopInternal()
    }

    private func stopInternal() async {
        if let engine = audioEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        continuation?.finish()
        audioEngine = nil
        continuation = nil
        currentFormatValue = nil
        currentDeviceUIDValue = nil
    }

    /// Clear stored state when the stop-closure fires. Only clears if
    /// the engine matches what's currently held — avoids racing with
    /// a fresh `start()` that has already installed a new engine.
    private func clearOnStop(engine: AVAudioEngine) async {
        if audioEngine === engine {
            audioEngine = nil
            continuation = nil
            currentFormatValue = nil
            currentDeviceUIDValue = nil
        }
    }

    // MARK: - Inspection

    /// The default-input device UID captured at the most recent
    /// successful `start(device:)`. `nil` if not started or if the
    /// HAL lookup failed.
    public func currentDeviceUID() -> String? {
        currentDeviceUIDValue
    }

    /// The audio format negotiated at the most recent successful
    /// `start(device:)`. `nil` if not started.
    public func currentFormat() -> AVAudioFormat? {
        currentFormatValue
    }
}
