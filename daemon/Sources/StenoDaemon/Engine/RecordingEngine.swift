import AVFoundation
import Foundation

/// Errors from the recording engine.
public enum RecordingEngineError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case permissionDenied(String)
    case audioSourceFailed(String)
    case recognizerFailed(String)
}

/// The core orchestrator for recording, transcription, and summarization.
///
/// Manages audio capture + speech recognition + segment persistence + summary coordination.
/// Fully testable through protocol-driven dependency injection.
public actor RecordingEngine {
    // MARK: - Read-only state

    public private(set) var status: EngineStatus = .idle
    public private(set) var currentSession: Session?
    public private(set) var currentDevice: String?
    public private(set) var isSystemAudioEnabled: Bool = false
    public private(set) var segmentCount: Int = 0

    // MARK: - Dependencies

    private let repository: TranscriptRepository
    private let permissionService: PermissionService
    private let summaryCoordinator: RollingSummaryCoordinator
    private let audioSourceFactory: AudioSourceFactory
    private let speechRecognizerFactory: SpeechRecognizerFactory
    private var delegate: (any RecordingEngineDelegate)?

    // MARK: - Internal state

    private var micRecognizerHandle: (any SpeechRecognizerHandle)?
    private var micStopClosure: (@Sendable () async -> Void)?
    private var systemAudioSource: AudioSource?
    private var sysRecognizerHandle: (any SpeechRecognizerHandle)?
    private var recognizerTask: Task<Void, Never>?
    private var systemRecognizerTask: Task<Void, Never>?
    private var levelThrottleTask: Task<Void, Never>?
    private var currentSequenceNumber: Int = 0
    private var lastLevelEmitTime: Date = .distantPast
    private var pendingMicLevel: Float = 0
    private var pendingSystemLevel: Float = 0

    /// Minimum interval between audio level events (10Hz = 100ms).
    private let levelInterval: TimeInterval = 0.1

    // MARK: - Init

    public init(
        repository: TranscriptRepository,
        permissionService: PermissionService,
        summaryCoordinator: RollingSummaryCoordinator,
        audioSourceFactory: AudioSourceFactory,
        speechRecognizerFactory: SpeechRecognizerFactory,
        delegate: (any RecordingEngineDelegate)? = nil
    ) {
        self.repository = repository
        self.permissionService = permissionService
        self.summaryCoordinator = summaryCoordinator
        self.audioSourceFactory = audioSourceFactory
        self.speechRecognizerFactory = speechRecognizerFactory
        self.delegate = delegate
    }

    // MARK: - Public Commands

    /// Set or replace the delegate.
    public func setDelegate(_ delegate: any RecordingEngineDelegate) {
        self.delegate = delegate
    }

    /// Start recording with the given configuration.
    ///
    /// - Parameters:
    ///   - locale: Locale for speech recognition.
    ///   - device: Optional audio device identifier.
    ///   - systemAudio: Whether to also capture system audio.
    /// - Returns: The created session.
    @discardableResult
    public func start(
        locale: Locale = .current,
        device: String? = nil,
        systemAudio: Bool = false
    ) async throws -> Session {
        guard status == .idle || status == .error else {
            throw RecordingEngineError.alreadyRecording
        }

        await setStatus(.starting)

        // Check permissions
        let permissions = await permissionService.checkPermissions()
        guard permissions.allGranted else {
            await setStatus(.error)
            let message = permissions.errorMessage ?? "Permissions denied"
            await emit(.error(message, isTransient: false))
            throw RecordingEngineError.permissionDenied(message)
        }

        // Create session
        let session: Session
        do {
            session = try await repository.createSession(locale: locale)
        } catch {
            await setStatus(.error)
            await emit(.error("Failed to create session: \(error)", isTransient: false))
            throw error
        }

        let result = try await bringUpPipelines(
            session: session,
            locale: locale,
            device: device,
            systemAudio: systemAudio
        )
        // Persist last-known device + systemAudio so the next daemon-start
        // auto-start can restore the user's selection. Failure to save is
        // non-fatal — log via emit and continue.
        await persistLastKnownAudioConfig(device: device, systemAudio: systemAudio)
        return result
    }

    /// Best-effort settings persistence after a successful start. Failure
    /// is non-fatal: we emit a transient error event and continue. The
    /// recording session is unaffected — settings persistence is a
    /// next-launch convenience, not a runtime requirement.
    private func persistLastKnownAudioConfig(device: String?, systemAudio: Bool) async {
        var settings = StenoSettings.load()
        settings.lastDevice = device
        settings.lastSystemAudioEnabled = systemAudio
        do {
            try settings.save()
        } catch {
            await emit(.error("Failed to save last-known audio config: \(error)", isTransient: true))
        }
    }

    /// Bring up mic + (optional) system audio pipelines around an
    /// already-acquired `Session`. Extracted from `start(...)` so the
    /// auto-start path (`recoverOrphansAndAutoStart`) can reuse the
    /// pipeline-bringup machinery with a session created by
    /// `repository.recoverOrphansAndOpenFresh()` instead of
    /// `repository.createSession()`.
    ///
    /// Caller invariants:
    /// - Status has already been transitioned to `.starting`.
    /// - Permissions have already been checked.
    /// - The session row already exists in the repository.
    ///
    /// Postconditions on success: status is `.recording`, all engine
    /// pipeline state is initialized.
    /// Postconditions on failure: cleanup runs, status transitions to `.error`,
    /// and an audio-source error is thrown. The session row in the DB is
    /// NOT rolled back — the caller decides whether to leave it active or
    /// close it.
    private func bringUpPipelines(
        session: Session,
        locale: Locale,
        device: String?,
        systemAudio: Bool
    ) async throws -> Session {
        currentSession = session
        currentDevice = device
        currentSequenceNumber = 0
        segmentCount = 0

        // Start microphone
        do {
            let (buffers, format, stopMic) = try await audioSourceFactory.makeMicrophoneSource(device: device)
            micStopClosure = stopMic

            // Wrap buffer stream to compute mic levels as buffers pass through
            let micBuffers = tappedStream(buffers, isMic: true)

            // Start level throttle (emits audioLevel events at 10Hz)
            startLevelThrottle()

            let recognizer = try await speechRecognizerFactory.makeRecognizer(locale: locale, format: format, source: .microphone)
            micRecognizerHandle = recognizer

            let results = recognizer.transcribe(buffers: micBuffers)
            recognizerTask = Task { [weak self] in
                do {
                    for try await result in results {
                        await self?.handleRecognizerResult(result)
                    }
                } catch {
                    await self?.handleRecognizerError(error)
                }
            }
        } catch {
            await cleanup()
            await setStatus(.error)
            await emit(.error("Audio source failed: \(error.localizedDescription)", isTransient: false))
            throw RecordingEngineError.audioSourceFailed(error.localizedDescription)
        }

        // Start system audio if requested
        if systemAudio {
            await startSystemAudio(locale: locale)
        }
        isSystemAudioEnabled = systemAudio

        await setStatus(.recording)
        return session
    }

    /// Sweep stranded `active` sessions to `interrupted`, then auto-start
    /// recording into a fresh active session. Used on daemon start
    /// (LaunchAgent relaunch, login, post-crash) to fulfil R1/R9: the
    /// daemon must not land in `idle` after first launch.
    ///
    /// Sequencing (load-bearing — see PR #33 review feedback):
    ///   1. Orphan sweep (no permission gate, no pause gate) — R9 says
    ///      stranded `active` rows from a prior crash MUST be closed on
    ///      every daemon start, regardless of subsequent gating decisions.
    ///   2. Pause-state restore check. The plan's U10 fail-safe
    ///      (privacy-critical): any DB read error or unrecognized state on
    ///      the pause columns → daemon stays in paused state, surfaces a
    ///      non-transient `pause_state_unverifiable` health warning, and
    ///      requires explicit user resume. The exact `pause_state_unverifiable`
    ///      token is matched on later by U9's TUI surface and U10's
    ///      health-warning machinery — do NOT change the wording.
    ///   3. Permission check. If denied → engine `.error`, throw.
    ///   4. Open a fresh active session and bring up pipelines.
    ///
    /// Failure modes:
    ///   - Sweep failure → engine `.error`, non-transient event, return nil
    ///     (no crash; future U6/U9 retry can pick this up, or the user can
    ///     resolve it manually via a future TUI command).
    ///   - Pause-column read failure → engine `.idle`, sweep already
    ///     committed, non-transient `pause_state_unverifiable` event,
    ///     return nil. Daemon stays paused — privacy invariant.
    ///   - Pause still active → engine `.idle`, non-transient event
    ///     explaining the skip, return nil.
    ///   - Permission denial → engine `.error`, throw `.permissionDenied`.
    ///   - Bringup failure (mic/system audio) → engine `.error`, throw
    ///     `.audioSourceFailed`. Sweep + fresh-session insert have
    ///     already committed.
    ///
    /// - Parameters:
    ///   - locale: Locale for speech recognition (default: `.current`).
    ///   - device: Optional audio device identifier (default: nil = system default).
    ///   - systemAudio: Whether to also capture system audio (default: true,
    ///                  matching the always-on recording goal).
    /// - Returns: The newly opened active session, or nil if the daemon
    ///   intentionally did not auto-start (pause restored, fail-safe
    ///   tripped, or sweep failed). Throws only on permission / bringup
    ///   failure where `.error` plus a thrown error is the right signal
    ///   to the caller (RunCommand).
    @discardableResult
    public func recoverOrphansAndAutoStart(
        locale: Locale = .current,
        device: String? = nil,
        systemAudio: Bool = true
    ) async throws -> Session? {
        guard status == .idle || status == .error else {
            throw RecordingEngineError.alreadyRecording
        }

        // Step 1: orphan sweep first (independent of pause-state and
        // permissions). R9 — stranded `active` rows must be closed on
        // every daemon start. Failure here surfaces non-transiently and
        // ends the call without crashing or opening a fresh session.
        do {
            try await repository.sweepActiveOrphans()
        } catch {
            await setStatus(.error)
            await emit(.error(
                "Daemon-start: orphan sweep failed: \(error.localizedDescription)" +
                " — engine remains in error state, no fresh session opened." +
                " A future retry (U6/U9) or manual resolution will be needed.",
                isTransient: false
            ))
            return nil
        }

        // Step 2: privacy-critical pause-state restore check (ties to U10).
        // The U10 fail-safe is explicit: any DB read error or unrecognized
        // state on the pause columns → daemon stays in paused state,
        // surfaces a non-transient `pause_state_unverifiable` health
        // warning, requires explicit user resume. This closes the
        // privacy-violation path in plan-risk R-F where a corrupted /
        // unmigrated row could otherwise default to "resume into recording."
        let mostRecent: Session?
        do {
            mostRecent = try await repository.mostRecentlyModifiedSession()
        } catch {
            // Fail-safe: stay paused (engine `.idle`). The orphan sweep has
            // already committed (step 1). Surface a non-transient warning
            // whose message contains the exact `pause_state_unverifiable`
            // token — U9's TUI surface and U10's health-warning machinery
            // match on this token.
            await emit(.error(
                "pause_state_unverifiable: failed to read pause columns on daemon start" +
                " (\(error.localizedDescription)). Daemon remains paused; explicit user" +
                " resume required.",
                isTransient: false
            ))
            return nil
        }

        if let mostRecent {
            let now = Date()
            let pauseStillActive = mostRecent.pausedIndefinitely
                || (mostRecent.pauseExpiresAt.map { $0 > now } ?? false)
            if pauseStillActive {
                await emit(.error(
                    "Daemon-start: pause is still active (paused_indefinitely=\(mostRecent.pausedIndefinitely)" +
                    ", pause_expires_at=\(mostRecent.pauseExpiresAt.map { String($0.timeIntervalSince1970) } ?? "nil"))" +
                    " — not auto-starting (U10 will restore paused engine state)",
                    isTransient: false
                ))
                return nil
            }
        }

        await setStatus(.starting)

        // Step 3: permission check. Failures here are user-resolvable
        // (TCC dialog) — engine ends in `.error` with a non-transient
        // event so the TUI can prompt the user.
        let permissions = await permissionService.checkPermissions()
        guard permissions.allGranted else {
            await setStatus(.error)
            let message = permissions.errorMessage ?? "Permissions denied"
            await emit(.error(message, isTransient: false))
            throw RecordingEngineError.permissionDenied(message)
        }

        // Step 4: open a fresh active session. Sweep already ran in step 1.
        let session: Session
        do {
            session = try await repository.openFreshSession(locale: locale)
        } catch {
            await setStatus(.error)
            await emit(.error("Failed to open fresh session: \(error.localizedDescription)", isTransient: false))
            throw error
        }

        let result = try await bringUpPipelines(
            session: session,
            locale: locale,
            device: device,
            systemAudio: systemAudio
        )
        await persistLastKnownAudioConfig(device: device, systemAudio: systemAudio)
        return result
    }

    /// Stop recording and finalize the session.
    public func stop() async {
        guard status == .recording || status == .starting else { return }

        await setStatus(.stopping)

        // Stop recognizers
        recognizerTask?.cancel()
        recognizerTask = nil
        await micRecognizerHandle?.stop()
        micRecognizerHandle = nil

        // Stop microphone
        await micStopClosure?()
        micStopClosure = nil

        // Stop system audio
        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil
        await sysRecognizerHandle?.stop()
        sysRecognizerHandle = nil
        await systemAudioSource?.stop()
        systemAudioSource = nil

        // Stop level throttling
        levelThrottleTask?.cancel()
        levelThrottleTask = nil

        // End session
        if let session = currentSession {
            try? await repository.endSession(session.id)
        }
        currentSession = nil
        isSystemAudioEnabled = false

        await setStatus(.idle)
    }

    /// List available audio devices.
    public func availableDevices() async -> [AudioDevice] {
        // Placeholder — real implementation queries Core Audio
        []
    }

    // MARK: - Private

    private func setStatus(_ newStatus: EngineStatus) async {
        status = newStatus
        await emit(.statusChanged(newStatus))
    }

    private func emit(_ event: EngineEvent) async {
        await delegate?.engine(self, didEmit: event)
    }

    private func handleRecognizerResult(_ result: RecognizerResult) async {
        guard let session = currentSession else { return }

        if result.isFinal {
            guard !result.text.isEmpty else { return }

            currentSequenceNumber += 1
            segmentCount = currentSequenceNumber

            let segment = StoredSegment(
                sessionId: session.id,
                text: result.text,
                startedAt: result.timestamp,
                endedAt: Date(),
                confidence: result.confidence,
                sequenceNumber: currentSequenceNumber,
                source: result.source
            )

            // Persist
            do {
                try await repository.saveSegment(segment)
            } catch {
                await emit(.error("Failed to save segment: \(error)", isTransient: true))
                return
            }

            await emit(.segmentFinalized(segment))

            // Trigger summary
            await emit(.modelProcessing(true))
            let summaryResult = await summaryCoordinator.onSegmentSaved(sessionId: session.id)
            await emit(.modelProcessing(false))

            if let summaryResult {
                await emit(.topicsUpdated(summaryResult.topics))
            }
        } else {
            await emit(.partialText(result.text, result.source))
        }
    }

    private func handleRecognizerError(_ error: Error) async {
        let message = error.localizedDescription
        let isCancellation = message.lowercased().contains("cancel")
        if !isCancellation {
            await emit(.error(message, isTransient: true))
        }
    }

    private func startSystemAudio(locale: Locale) async {
        let source = audioSourceFactory.makeSystemAudioSource()
        systemAudioSource = source

        do {
            let (buffers, format) = try await source.start()

            let sysBuffers = tappedStream(buffers, isMic: false)

            let recognizer = try await speechRecognizerFactory.makeRecognizer(locale: locale, format: format, source: .systemAudio)
            sysRecognizerHandle = recognizer

            let results = recognizer.transcribe(buffers: sysBuffers)
            systemRecognizerTask = Task { [weak self] in
                do {
                    for try await result in results {
                        await self?.handleRecognizerResult(result)
                    }
                } catch {
                    await self?.handleRecognizerError(error)
                }
            }
        } catch {
            await emit(.error("System audio failed: \(error)", isTransient: true))
        }
    }

    // MARK: - Level Metering

    /// Wrap a buffer stream to compute peak levels as buffers pass through.
    /// Returns a new AsyncStream that yields the same buffers.
    private func tappedStream(
        _ source: AsyncStream<AVAudioPCMBuffer>,
        isMic: Bool
    ) -> AsyncStream<AVAudioPCMBuffer> {
        struct Box: @unchecked Sendable {
            let source: AsyncStream<AVAudioPCMBuffer>
            let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
        }
        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let box = Box(source: source, continuation: cont)
        Task.detached { [weak self] in
            for await buffer in box.source {
                let peak = RecordingEngine.peakLevel(buffer)
                if isMic {
                    await self?.updateMicLevel(peak)
                } else {
                    await self?.updateSystemLevel(peak)
                }
                nonisolated(unsafe) let b = buffer
                box.continuation.yield(b)
            }
            box.continuation.finish()
        }
        return stream
    }

    private func updateMicLevel(_ peak: Float) {
        pendingMicLevel = max(pendingMicLevel, peak)
    }

    private func updateSystemLevel(_ peak: Float) {
        pendingSystemLevel = max(pendingSystemLevel, peak)
    }

    /// Start a 10Hz throttle task that emits audioLevel events.
    private func startLevelThrottle() {
        guard levelThrottleTask == nil else { return }
        levelThrottleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.emitAndResetLevels()
            }
        }
    }

    private func emitAndResetLevels() async {
        await emit(.audioLevel(mic: pendingMicLevel, system: pendingSystemLevel))
        pendingMicLevel = 0
        pendingSystemLevel = 0
    }

    /// Compute peak amplitude from a buffer.
    private static func peakLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<frameLength {
            let sample = abs(channelData[i])
            if sample > peak { peak = sample }
        }
        return peak
    }

    // MARK: - Cleanup

    private func cleanup() async {
        recognizerTask?.cancel()
        recognizerTask = nil
        await micRecognizerHandle?.stop()
        micRecognizerHandle = nil
        await micStopClosure?()
        micStopClosure = nil
        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil
        await sysRecognizerHandle?.stop()
        sysRecognizerHandle = nil
        await systemAudioSource?.stop()
        systemAudioSource = nil
        levelThrottleTask?.cancel()
        levelThrottleTask = nil
        currentSession = nil
    }
}
