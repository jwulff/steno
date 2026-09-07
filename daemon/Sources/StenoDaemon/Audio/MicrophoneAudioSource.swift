@preconcurrency import AVFoundation
import Foundation

/// Failures raised while bringing up the microphone pipeline.
///
/// All three are hard failures by design (#104). Silently substituting a
/// different input when the requested one cannot be used is what made a
/// misrouted microphone look like a working recording.
public enum MicrophoneAudioSourceError: Error, Equatable, LocalizedError {
    /// The requested device matched no input on the machine.
    case deviceNotFound(requested: String, available: [String])
    /// Core Audio refused to bind the input node to the requested device.
    case deviceSelectionFailed(requested: String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let requested, let available):
            let list = available.isEmpty
                ? "no input devices are available"
                : "available: \(available.joined(separator: ", "))"
            return "Audio input device \"\(requested)\" not found (\(list))"
        case .deviceSelectionFailed(let requested, let status):
            return "Could not select audio input device \"\(requested)\": Core Audio returned \(status)"
        }
    }
}

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

    /// Resolves the machine's input devices so a requested `device` can
    /// be turned into an `AudioDeviceID`. Injected because Core Audio
    /// enumeration needs real hardware.
    private let deviceEnumerator: any AudioInputDeviceEnumerating

    public init(
        deviceUIDProvider: @Sendable @escaping () -> String? = { defaultInputDeviceUID() },
        deviceEnumerator: any AudioInputDeviceEnumerating = CoreAudioInputDeviceEnumerator()
    ) {
        self.deviceUIDProvider = deviceUIDProvider
        self.deviceEnumerator = deviceEnumerator
    }

    // MARK: - Lifecycle

    /// Bring up the mic pipeline. Builds a fresh `AVAudioEngine`,
    /// installs a tap on the input node, and returns an async stream
    /// of PCM buffers plus the resolved input format and a stop
    /// closure that tears the engine down.
    ///
    /// - Parameter device: Optional device name or UID. When supplied it
    ///   is resolved against the machine's inputs and the engine's input
    ///   node's audio unit is bound to it via `setDeviceID(_:)`.
    ///   When `nil`, capture follows the system default input, which is
    ///   the historical behavior.
    ///
    /// - Throws: `MicrophoneAudioSourceError.deviceNotFound` when the
    ///   requested device matches nothing. It deliberately does not fall
    ///   back to the default input: before #104 that fallback was
    ///   unconditional and invisible, so a session pinned to a device
    ///   that had gone away recorded from somewhere else while reporting
    ///   `recording: true`.
    public func start(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void) {

        // Resolve first, before touching any engine state. A bad device
        // name then costs nothing: an already-running capture is left
        // alone rather than being torn down for a start that cannot
        // succeed.
        let pinned = try resolveRequestedDevice(device)

        // Stop any existing engine — defensive; callers should be
        // calling `start` against a fresh `MicrophoneAudioSource`
        // instance, but a re-entrant `start` should not leak the
        // previous engine.
        await stopInternal()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Bind the input before reading the format: the negotiated
        // format belongs to whichever device the AUHAL is pointed at, so
        // reading it first would describe the default input and then tap
        // a different one.
        if let pinned {
            try Self.bindInput(inputNode, to: pinned)
        }

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
        self.currentDeviceUIDValue = Self.effectiveDeviceUID(
            pinned: pinned,
            fallback: deviceUIDProvider
        )

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

    // MARK: - Device selection

    /// Turn a requested device name/UID into a concrete input device.
    ///
    /// `nil` in, `nil` out — an absent or blank `device` means "follow
    /// the system default", which is what every existing caller does.
    private func resolveRequestedDevice(_ device: String?) throws -> AudioInputDevice? {
        guard let requested = device?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            return nil
        }

        let available = deviceEnumerator.inputDevices()
        guard let match = AudioInputDeviceResolver.resolve(requested, in: available) else {
            throw MicrophoneAudioSourceError.deviceNotFound(
                requested: requested,
                available: available.map(\.name)
            )
        }
        return match
    }

    /// Point `AVAudioEngine`'s input node at a specific device.
    ///
    /// `AVAudioEngine` has no device selector of its own; the AUHAL unit
    /// behind the input node does. It must be set before the engine is
    /// prepared or started — afterwards the graph is already wired to
    /// whatever device it came up on.
    ///
    /// `setDeviceID` rejects an ID the HAL does not recognize
    /// (`-10851`), which is the case that matters here: a device can
    /// disappear between enumeration and bring-up.
    private static func bindInput(_ inputNode: AVAudioInputNode, to device: AudioInputDevice) throws {
        do {
            try inputNode.auAudioUnit.setDeviceID(device.id)
        } catch {
            throw MicrophoneAudioSourceError.deviceSelectionFailed(
                requested: device.name,
                status: Int32(truncatingIfNeeded: (error as NSError).code)
            )
        }
    }

    /// Which UID this source should report as the one it is capturing.
    ///
    /// A pinned device reports its own UID rather than the system
    /// default's. That matters downstream: the engine restarts capture
    /// when this UID changes, and a pinned session should not rebuild
    /// just because the user switched the *default* input to something
    /// else.
    static func effectiveDeviceUID(
        pinned: AudioInputDevice?,
        fallback: () -> String?
    ) -> String? {
        pinned?.uid ?? fallback()
    }

    // MARK: - Inspection

    /// The device UID captured at the most recent successful
    /// `start(device:)` — the pinned device's UID when one was
    /// requested, otherwise the system default's. `nil` if not started
    /// or if the HAL lookup failed.
    public func currentDeviceUID() -> String? {
        currentDeviceUIDValue
    }

    /// The audio format negotiated at the most recent successful
    /// `start(device:)`. `nil` if not started.
    public func currentFormat() -> AVAudioFormat? {
        currentFormatValue
    }
}
