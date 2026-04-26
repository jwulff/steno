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

    /// Sleep used by the U5 restart-with-backoff loop. Production passes
    /// `Task.sleep(for:)`; tests inject a faster (or zero-duration)
    /// closure so the curve is observable without paying real wall-clock.
    /// The closure must throw `CancellationError` when its task is
    /// cancelled — otherwise `stop()` cannot abort an in-flight backoff.
    private let backoffSleep: @Sendable (Duration) async throws -> Void

    // MARK: - U6 dependencies (sleep/wake supervisor)

    /// IOKit-backed power assertion held while the engine is in the
    /// `.recording` status. Acquired on first transition into
    /// `.recording`, released on every transition OUT of `.recording`,
    /// re-acquired on transitions back into `.recording`. Surfaces in
    /// `pmset -g assertions` as `"Steno: capturing audio"`.
    private let powerAssertion: any PowerAssertionManaging

    /// Resolves the current default-input device UID for the heal rule.
    /// Production injects a Core Audio HAL lookup
    /// (`kAudioHardwarePropertyDefaultInputDevice` → device UID); tests
    /// inject a closure that returns synthetic UIDs to exercise the
    /// "device changed across sleep" rollover branch.
    private let deviceUIDProvider: @Sendable () -> String?

    /// Heal-rule reuse threshold in seconds. Resolved from
    /// `StenoSettings.healGapSeconds` at construction time.
    private let healThresholdSeconds: Int

    /// Wall-clock provider. Tests inject a deterministic clock so the
    /// rollover-vs-reuse path can be exercised without a real 30-second
    /// sleep.
    private let nowProvider: @Sendable () -> Date

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

    // MARK: - U5 restart-with-backoff state

    /// Locale captured at start time so the restart path can rebuild
    /// recognizers without re-threading locale through every call.
    private var currentLocale: Locale = .current

    /// Independent backoff policies per source. The mic and system audio
    /// pipelines fail (and recover) independently per the plan: a
    /// recognizer error on the system audio pipeline must not throttle
    /// mic-pipeline rebuilds.
    private var micBackoff = BackoffPolicy()
    private var sysBackoff = BackoffPolicy()

    /// In-flight restart tasks. While non-nil for a source, that source
    /// is mid-restart — additional errors arriving via the (already
    /// cancelled) recognizer stream are ignored. `stop()` cancels both
    /// to terminate the cancellable backoff sleep cleanly.
    private var micRestartTask: Task<Void, Never>?
    private var sysRestartTask: Task<Void, Never>?

    /// Heal markers staged for the *first* segment finalized after a
    /// successful restart on each source. Cleared by the segment-save
    /// path on consumption.
    private var pendingMicHealMarker: String?
    private var pendingSysHealMarker: String?

    /// Wall-clock timestamps of restart entry per source. Used to
    /// compute the `healed(gapSeconds:)` value once the rebuild
    /// completes and the next segment lands.
    private var micRestartEntryTime: Date?
    private var sysRestartEntryTime: Date?

    /// Pre-computed gap-seconds awaiting consumption by the next
    /// finalized segment of the rebuilt pipeline. Set after a successful
    /// rebuild, cleared on consumption.
    private var pendingMicHealedGap: Double?
    private var pendingSysHealedGap: Double?

    /// Whether `stop()` has been entered. Restart loops check this to
    /// abort cleanly mid-backoff.
    private var isStopping: Bool = false

    // MARK: - U6 sleep/wake state

    /// Wall-clock moment the most recent `handleSystemWillSleep()` (or
    /// equivalent teardown) recorded the gap entry. The wake handler
    /// computes `gap = nowProvider() - gapStartedAt` to drive the heal
    /// rule. Cleared when the wake handler returns (success or rollover).
    private var gapStartedAt: Date?

    /// Device UID captured at the last successful pipeline bring-up
    /// (start, restart, or wake-reuse). Used by the heal rule on the
    /// next wake to detect "device changed across sleep" and force a
    /// rollover even when the gap is short.
    private var lastDeviceUID: String?

    // MARK: - U7 device-change observer state

    /// Audio format captured at the last successful pipeline
    /// bring-up. Used by `handleAudioDeviceChange(deviceUID:format:)`
    /// to distinguish "device changed" (rollover candidate) from
    /// "format changed within same device" (still triggers heal rule
    /// because format affects the analyzer) from "neither changed"
    /// (cheap restart, no heal-rule trigger).
    private var lastMicFormat: AVAudioFormat?

    // MARK: - Init

    public init(
        repository: TranscriptRepository,
        permissionService: PermissionService,
        summaryCoordinator: RollingSummaryCoordinator,
        audioSourceFactory: AudioSourceFactory,
        speechRecognizerFactory: SpeechRecognizerFactory,
        delegate: (any RecordingEngineDelegate)? = nil,
        backoffSleep: @Sendable @escaping (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        powerAssertion: (any PowerAssertionManaging)? = nil,
        deviceUIDProvider: @Sendable @escaping () -> String? = { nil },
        healThresholdSeconds: Int = 30,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.permissionService = permissionService
        self.summaryCoordinator = summaryCoordinator
        self.audioSourceFactory = audioSourceFactory
        self.speechRecognizerFactory = speechRecognizerFactory
        self.delegate = delegate
        self.backoffSleep = backoffSleep
        self.powerAssertion = powerAssertion ?? PowerAssertion()
        self.deviceUIDProvider = deviceUIDProvider
        self.healThresholdSeconds = healThresholdSeconds
        self.nowProvider = now
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
        currentLocale = locale
        currentSequenceNumber = 0
        segmentCount = 0
        // U6: capture the device UID at this bring-up so the next wake
        // / config-change can compare against it for the heal rule.
        lastDeviceUID = deviceUIDProvider()

        // Start microphone
        do {
            let (buffers, format, stopMic) = try await audioSourceFactory.makeMicrophoneSource(device: device)
            micStopClosure = stopMic
            // U7: remember the format so the device-change handler can
            // distinguish "format changed within same device" from
            // "neither changed."
            lastMicFormat = format

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
                    await self?.handleRecognizerError(error, source: .microphone)
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
        // Allow stopping from `.recovering` too (U5): an in-flight
        // restart must be cancellable mid-backoff so user-initiated
        // teardown is not blocked by the wait.
        guard status == .recording
            || status == .starting
            || status == .recovering else { return }

        isStopping = true
        await setStatus(.stopping)

        // Cancel any in-flight restart tasks. Their `Task.sleep(for:)`
        // raises CancellationError and the loop returns early without
        // re-arming a rebuild attempt.
        micRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask?.cancel()
        sysRestartTask = nil

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

        // Clear U5 restart bookkeeping for the next start.
        micBackoff = BackoffPolicy()
        sysBackoff = BackoffPolicy()
        pendingMicHealMarker = nil
        pendingSysHealMarker = nil
        pendingMicHealedGap = nil
        pendingSysHealedGap = nil
        micRestartEntryTime = nil
        sysRestartEntryTime = nil
        lastMicFormat = nil

        await setStatus(.idle)
        isStopping = false
    }

    /// List available audio devices.
    public func availableDevices() async -> [AudioDevice] {
        // Placeholder — real implementation queries Core Audio
        []
    }

    // MARK: - Private

    private func setStatus(_ newStatus: EngineStatus) async {
        let previous = status
        status = newStatus
        // U6: power assertion lifecycle. Take on entry into `.recording`,
        // release on every transition OUT of `.recording`. Idempotent in
        // both directions so concurrent rebuild paths can call freely
        // without leaking duplicate assertions.
        if previous != .recording && newStatus == .recording {
            do {
                try powerAssertion.acquire()
            } catch {
                await emit(.error(
                    "Failed to acquire power assertion: \(error.localizedDescription)",
                    isTransient: true
                ))
            }
        } else if previous == .recording && newStatus != .recording {
            powerAssertion.release()
        }
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

            // U5: stamp the heal marker on the *first* segment after a
            // successful pipeline restart on the matching source. The
            // marker is consumed (cleared) here so subsequent normal
            // segments have heal_marker = NULL.
            let healMarker: String?
            switch result.source {
            case .microphone:
                healMarker = pendingMicHealMarker
                pendingMicHealMarker = nil
            case .systemAudio:
                healMarker = pendingSysHealMarker
                pendingSysHealMarker = nil
            }

            let segment = StoredSegment(
                sessionId: session.id,
                text: result.text,
                startedAt: result.timestamp,
                endedAt: Date(),
                confidence: result.confidence,
                sequenceNumber: currentSequenceNumber,
                source: result.source,
                healMarker: healMarker
            )

            // Persist
            do {
                try await repository.saveSegment(segment)
            } catch {
                await emit(.error("Failed to save segment: \(error)", isTransient: true))
                return
            }

            await emit(.segmentFinalized(segment))

            // U5: a finalized segment counts toward the per-source
            // backoff reset (segment-finalized gate). The wall-clock
            // gate is enforced separately in `tryReset(now:)` below.
            switch result.source {
            case .microphone:
                micBackoff.recordSegmentFinalized()
                micBackoff.tryReset()
            case .systemAudio:
                sysBackoff.recordSegmentFinalized()
                sysBackoff.tryReset()
            }

            // U5: emit `healed(gapSeconds:)` once on the first segment
            // after a successful restart. The gap was pre-computed at
            // rebuild-success time, so this lands deterministically.
            switch result.source {
            case .microphone:
                if let gap = pendingMicHealedGap {
                    await emit(.healed(gapSeconds: gap))
                    pendingMicHealedGap = nil
                }
            case .systemAudio:
                if let gap = pendingSysHealedGap {
                    await emit(.healed(gapSeconds: gap))
                    pendingSysHealedGap = nil
                }
            }

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

    /// Recognizer-error entry point. Dispatches to the per-source
    /// `restart…Pipeline(reason:)` so U5's bounded-backoff machinery can
    /// rebuild without surfacing the failure to the user as long as the
    /// policy stays under the surrender threshold.
    ///
    /// Cancellation errors arriving from a teardown (e.g. an in-flight
    /// `restartMicPipeline` finishing the previous handle's stream) are
    /// silently ignored — only genuine recognizer failures should
    /// trigger a fresh restart attempt.
    private func handleRecognizerError(_ error: Error, source: AudioSourceType) async {
        let message = error.localizedDescription
        let isCancellation = (error is CancellationError)
            || message.lowercased().contains("cancel")
        if isCancellation { return }

        // If we're already in the middle of stopping, don't spawn a
        // restart — the user-initiated teardown owns the state machine.
        if isStopping || status == .stopping || status == .idle { return }

        switch source {
        case .microphone:
            // Drop duplicate failures while a restart is already running.
            if micRestartTask != nil { return }
            await scheduleMicRestart(reason: "recognizer:\(message)", errorCode: errorCode(for: error))
        case .systemAudio:
            if sysRestartTask != nil { return }
            await scheduleSysRestart(reason: "recognizer:\(message)", errorCode: errorCode(for: error))
        }
    }

    /// Compute a stable error code for backoff "same-error" tracking.
    /// Strategy: if the error is an `NSError`, use `domain#code`; otherwise,
    /// use the type name. This gives U5's `BackoffPolicy` a deterministic
    /// key string without coupling to any specific error enum.
    private nonisolated func errorCode(for error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }

    // MARK: - U5 Restart machinery

    /// Schedule a mic-pipeline restart and remember the in-flight task
    /// so concurrent error reports / `stop()` can join or cancel it.
    private func scheduleMicRestart(reason: String, errorCode: String) async {
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.restartMicPipeline(reason: reason, errorCode: errorCode)
        }
        micRestartTask = task
    }

    private func scheduleSysRestart(reason: String, errorCode: String) async {
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.restartSystemPipeline(reason: reason, errorCode: errorCode)
        }
        sysRestartTask = task
    }

    /// Restart the microphone pipeline with bounded exponential backoff (U5).
    ///
    /// Sequence:
    ///   1. Set status to `.recovering`, broadcast `.recovering(reason:)`.
    ///   2. Tear down the current mic pipeline (recognizer task, recognizer
    ///      handle, audio source).
    ///   3. Record the error in `micBackoff`. If the policy surrenders,
    ///      broadcast `.recoveryExhausted(reason:)`, set status to
    ///      `.error`, exit. The engine will only recover via external
    ///      stimulus (resume, device-change — see plan's "Engine-state
    ///      recovery from `error`" section).
    ///   4. Sleep for the backoff delay. The sleep is cancellable —
    ///      `stop()` cancels the restart task and the wait aborts cleanly.
    ///   5. Rebuild the mic pipeline (audio source + recognizer +
    ///      consumer task). The recognizer is created via the same
    ///      `speechRecognizerFactory` used at start time; the
    ///      SpeechAnalyzer factory implementation owns the `@MainActor`
    ///      hop internally per project convention.
    ///   6. On success: stage `pendingMicHealMarker` for the first
    ///      finalized segment, pre-compute `pendingMicHealedGap`, restore
    ///      status to `.recording` (unless sys is also recovering).
    ///
    /// **Heal-rule scope (U5):** always reuses the current session and
    /// stamps `heal_marker = "after_gap:<N>s"` on the next segment.
    /// Session rollover for long gaps is U6's heal-rule decision, not U5's.
    func restartMicPipeline(reason: String, errorCode: String) async {
        await beginRecovering(reason: reason)
        let entryTime = Date()
        micRestartEntryTime = entryTime

        // Tear down the current mic pipeline. Cancellation of the
        // existing recognizerTask is the load-bearing step — it stops
        // the consumer that would otherwise re-emit the same error and
        // re-enter this method.
        recognizerTask?.cancel()
        recognizerTask = nil
        await micRecognizerHandle?.stop()
        micRecognizerHandle = nil
        await micStopClosure?()
        micStopClosure = nil

        // Record the error and decide whether to wait or surrender.
        let outcome = micBackoff.record(error: errorCode)
        switch outcome {
        case .exhausted:
            await emit(.recoveryExhausted(reason: reason))
            await setStatus(.error)
            micRestartTask = nil
            micRestartEntryTime = nil
            return
        case .delay(let duration):
            // Cancellable sleep — `stop()` triggers Task cancellation
            // which makes this throw and return cleanly.
            do {
                try await backoffSleep(duration)
            } catch {
                // Either cancelled by `stop()` or by another teardown.
                micRestartTask = nil
                micRestartEntryTime = nil
                return
            }
        }

        // If `stop()` arrived during the wait, do NOT rebuild.
        if isStopping || status == .stopping || status == .idle || Task.isCancelled {
            micRestartTask = nil
            micRestartEntryTime = nil
            return
        }

        // Rebuild.
        do {
            let (buffers, format, stopMic) = try await audioSourceFactory.makeMicrophoneSource(device: currentDevice)
            micStopClosure = stopMic
            // U7: refresh cached mic format on successful rebuild so
            // a subsequent device-change handler compares against the
            // post-restart format, not the pre-restart format.
            lastMicFormat = format
            // Refresh the cached device UID — a config-change-driven
            // restart may have landed on a new default-input device.
            lastDeviceUID = deviceUIDProvider()

            let micBuffers = tappedStream(buffers, isMic: true)
            let recognizer = try await speechRecognizerFactory.makeRecognizer(
                locale: currentLocale,
                format: format,
                source: .microphone
            )
            micRecognizerHandle = recognizer

            let results = recognizer.transcribe(buffers: micBuffers)
            recognizerTask = Task { [weak self] in
                do {
                    for try await result in results {
                        await self?.handleRecognizerResult(result)
                    }
                } catch {
                    await self?.handleRecognizerError(error, source: .microphone)
                }
            }

            // Successful rebuild. Compute gap, stage heal marker, mark
            // restart-time for backoff reset.
            let gap = Date().timeIntervalSince(entryTime)
            let gapSeconds = max(0, Int(gap.rounded()))
            pendingMicHealMarker = "after_gap:\(gapSeconds)s"
            pendingMicHealedGap = gap
            micBackoff.recordRestart()
        } catch {
            // Rebuild itself failed — record under a fresh error code
            // and re-enter the restart loop. We'll be re-driven by
            // `handleRecognizerError` when the next consumer task fails,
            // OR — for an immediate factory throw — surface the error
            // as an exhaustion path: bump the policy with the current
            // error and check.
            await emit(.error(
                "Mic pipeline rebuild failed: \(error.localizedDescription)",
                isTransient: true
            ))
            // Bump the policy on the rebuild failure; if it pushes us
            // past the surrender threshold, exhaustion fires now.
            let nested = micBackoff.record(error: self.errorCode(for: error))
            if case .exhausted = nested {
                await emit(.recoveryExhausted(reason: "rebuild:\(error.localizedDescription)"))
                await setStatus(.error)
            }
            micRestartTask = nil
            micRestartEntryTime = nil
            return
        }

        // Restore status. If sys is still recovering, leave status at
        // `.recovering` until both pipelines are healthy.
        micRestartTask = nil
        micRestartEntryTime = nil
        await maybeRestoreRecordingStatus()
    }

    /// Restart the system-audio pipeline with bounded exponential backoff (U5).
    /// Mirror of `restartMicPipeline` operating on the sys-audio state.
    func restartSystemPipeline(reason: String, errorCode: String) async {
        await beginRecovering(reason: reason)
        let entryTime = Date()
        sysRestartEntryTime = entryTime

        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil
        await sysRecognizerHandle?.stop()
        sysRecognizerHandle = nil
        await systemAudioSource?.stop()
        systemAudioSource = nil

        let outcome = sysBackoff.record(error: errorCode)
        switch outcome {
        case .exhausted:
            await emit(.recoveryExhausted(reason: reason))
            await setStatus(.error)
            sysRestartTask = nil
            sysRestartEntryTime = nil
            return
        case .delay(let duration):
            do {
                try await backoffSleep(duration)
            } catch {
                sysRestartTask = nil
                sysRestartEntryTime = nil
                return
            }
        }

        if isStopping || status == .stopping || status == .idle || Task.isCancelled {
            sysRestartTask = nil
            sysRestartEntryTime = nil
            return
        }

        let source = audioSourceFactory.makeSystemAudioSource()
        systemAudioSource = source

        do {
            let (buffers, format) = try await source.start()
            let sysBuffers = tappedStream(buffers, isMic: false)
            let recognizer = try await speechRecognizerFactory.makeRecognizer(
                locale: currentLocale,
                format: format,
                source: .systemAudio
            )
            sysRecognizerHandle = recognizer

            let results = recognizer.transcribe(buffers: sysBuffers)
            systemRecognizerTask = Task { [weak self] in
                do {
                    for try await result in results {
                        await self?.handleRecognizerResult(result)
                    }
                } catch {
                    await self?.handleRecognizerError(error, source: .systemAudio)
                }
            }

            let gap = Date().timeIntervalSince(entryTime)
            let gapSeconds = max(0, Int(gap.rounded()))
            pendingSysHealMarker = "after_gap:\(gapSeconds)s"
            pendingSysHealedGap = gap
            sysBackoff.recordRestart()
        } catch {
            await emit(.error(
                "System pipeline rebuild failed: \(error.localizedDescription)",
                isTransient: true
            ))
            let nested = sysBackoff.record(error: self.errorCode(for: error))
            if case .exhausted = nested {
                await emit(.recoveryExhausted(reason: "rebuild:\(error.localizedDescription)"))
                await setStatus(.error)
            }
            sysRestartTask = nil
            sysRestartEntryTime = nil
            return
        }

        sysRestartTask = nil
        sysRestartEntryTime = nil
        await maybeRestoreRecordingStatus()
    }

    /// Transition into the `.recovering` status (idempotent — multiple
    /// concurrent restarts only emit one transition because the second
    /// call sees status already at `.recovering`).
    private func beginRecovering(reason: String) async {
        await emit(.recovering(reason: reason))
        if status != .recovering && status != .error {
            await setStatus(.recovering)
        }
    }

    /// After a successful restart, restore status to `.recording`
    /// unless another pipeline is still mid-restart or the engine has
    /// surrendered to `.error`.
    private func maybeRestoreRecordingStatus() async {
        if status == .error { return }
        if micRestartTask != nil || sysRestartTask != nil { return }
        if isStopping || status == .stopping || status == .idle { return }
        await setStatus(.recording)
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
                    await self?.handleRecognizerError(error, source: .systemAudio)
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

    // MARK: - U6 Sleep/Wake Handlers

    /// Called on `kIOMessageSystemWillSleep` (wired via
    /// `PowerManagementObserver`). Drains pipelines, persists in-flight
    /// segments, releases the power assertion, and stamps
    /// `gapStartedAt`. The heal rule decision is deferred to wake.
    ///
    /// **Ordering invariant (load-bearing — see plan's "Power-assertion
    /// ordering (U6 test)" section):** the call sequence inside this
    /// method MUST be (1) stop pipelines and confirm stopped, (2) release
    /// the power assertion, (3) return to caller (which then invokes
    /// `IOAllowPowerChange`). This closes the race where a still-active
    /// mic pipeline could capture audio after the power assertion is
    /// released but before the system actually sleeps.
    ///
    /// Cleanup is unconditional — runs even from `.error` state.
    public func handleSystemWillSleep() async {
        // Stamp the gap moment before tearing anything down so the wake
        // handler can compute the elapsed time accurately.
        gapStartedAt = nowProvider()

        // Cancel any in-flight restart tasks. Their `Task.sleep(for:)`
        // raises CancellationError and the loop returns early without
        // re-arming a rebuild attempt during sleep.
        micRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask?.cancel()
        sysRestartTask = nil

        // (1) Stop pipelines and confirm stopped. Each `await` returns
        // only after the underlying handle / closure has finished its
        // teardown.
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

        // (2) Release the power assertion AFTER pipelines confirm
        // stopped. Releasing is idempotent — the .recording -> .recovering
        // transition below would also release it if we hadn't already.
        powerAssertion.release()

        // Transition to `.recovering` to reflect the sleep gap. We don't
        // close the session here — the heal rule decides on wake whether
        // to reuse or roll over.
        if status != .error && status != .idle && status != .stopping {
            await setStatus(.recovering)
        }

        // (3) Caller (PowerManagementObserver) calls IOAllowPowerChange
        // next.
    }

    /// Called on `kIOMessageSystemHasPoweredOn` (wired via
    /// `PowerManagementObserver`). Computes the gap, applies the heal
    /// rule, and brings up pipelines around either the surviving session
    /// (reuse) or a fresh one (rollover). Re-acquires the power
    /// assertion via the `.recording` status transition.
    public func handleSystemDidWake() async {
        // No-op safety: if we never entered `.recording` (e.g., engine
        // was idle before sleep, paused, or error-with-no-session), we
        // have nothing to bring back up. This guards the test scenario
        // where `handleSystemDidWake` is invoked on an idle engine.
        guard let gapStarted = gapStartedAt else {
            // Wake without a prior willSleep — nothing to do.
            return
        }
        gapStartedAt = nil

        guard let session = currentSession else {
            // Status was non-.recording at sleep-time (e.g. error). Stay
            // wherever we are; the engine-recovery path (plan "Engine-state
            // recovery from `error`") drives a re-attempt elsewhere.
            return
        }

        let gap = nowProvider().timeIntervalSince(gapStarted)
        let currentDeviceUID = deviceUIDProvider()
        let outcome = HealRule.decide(
            gap: gap,
            deviceUID: currentDeviceUID,
            lastDeviceUID: lastDeviceUID,
            thresholdSeconds: healThresholdSeconds
        )

        await emit(.recovering(reason: "wake:gap=\(Int(gap.rounded()))s"))

        switch outcome {
        case .reuseSession(let healMarker):
            // Stage the heal marker for the first segment of each
            // rebuilt pipeline so the post-wake transcription carries
            // the U2-schema `heal_marker` annotation.
            pendingMicHealMarker = healMarker
            pendingSysHealMarker = healMarker
            pendingMicHealedGap = gap
            pendingSysHealedGap = gap

            do {
                _ = try await bringUpPipelines(
                    session: session,
                    locale: currentLocale,
                    device: currentDevice,
                    systemAudio: isSystemAudioEnabled
                )
            } catch {
                // bringUpPipelines transitions to .error on failure and
                // emits a non-transient error event.
                await emit(.error(
                    "Wake (reuse) bring-up failed: \(error.localizedDescription)",
                    isTransient: false
                ))
            }

        case .rollover:
            // Close current session as `interrupted`. Use the same
            // path orphan-sweep uses (sweepActiveOrphans then
            // openFreshSession) since the active session is effectively
            // an "orphan" of the pre-sleep capture.
            do {
                try await repository.sweepActiveOrphans()
                let fresh = try await repository.openFreshSession(locale: currentLocale)
                _ = try await bringUpPipelines(
                    session: fresh,
                    locale: currentLocale,
                    device: currentDevice,
                    systemAudio: isSystemAudioEnabled
                )
                // Emit a healed event reflecting the gap that triggered
                // the rollover so the TUI surfaces a visible recovery.
                await emit(.healed(gapSeconds: gap))
            } catch {
                await emit(.error(
                    "Wake (rollover) failed: \(error.localizedDescription)",
                    isTransient: false
                ))
                await setStatus(.error)
            }
        }
    }

    // MARK: - U7 Device-Change Handler

    /// Called by `AudioDeviceObserver` after a 250ms-debounced burst
    /// of `AVAudioEngine.configurationChangeNotification` events
    /// settles. Compares the post-debounce device UID and format
    /// against the cached values from the last successful pipeline
    /// bring-up and routes through the appropriate path:
    ///
    /// - **Same UID + same format** → cheap restart only. The
    ///   AVAudioEngine has internally torn down (per Apple's docs the
    ///   engine has already stopped by the time we receive the
    ///   notification), so we still rebuild via U5's
    ///   `restartMicPipeline`, but we do NOT invoke the heal rule.
    ///   The first segment after rebuild gets `heal_marker =
    ///   "after_gap:Ns"` per U5's machinery — that's the existing
    ///   transient-restart behavior, not a heal-rule outcome.
    ///
    /// - **Different UID OR different format** → restart + heal rule.
    ///   The heal rule's "device change → rollover" branch kicks in
    ///   on UID mismatch; on format-only mismatch with same UID, the
    ///   gap will be < 30s so the rule's `reuseSession` branch fires
    ///   and the next segment carries a heal marker. The restart
    ///   itself routes through U5's machinery.
    ///
    /// **Concurrency:** This runs on the actor, serialized against
    /// recognizer-error-driven restarts and sleep/wake handlers. A
    /// device-change arriving while a restart is already in flight
    /// is dropped (the in-flight restart will rebuild against the
    /// post-change device anyway). A device-change arriving while
    /// the engine is `.idle`, `.stopping`, or stopped is a no-op.
    public func handleAudioDeviceChange(deviceUID: String?, format: AVAudioFormat?) async {
        // No-op safety: device-change events arriving outside an
        // active recording are uninteresting (no pipeline to
        // rebuild). Same gating as recognizer-error.
        if isStopping || status == .stopping || status == .idle {
            return
        }
        // Drop duplicates while a mic restart is already running —
        // the in-flight restart will rebuild against whatever the
        // current default-input device is when it lands.
        if micRestartTask != nil { return }
        // No active session means there's no mic pipeline to rebuild.
        guard currentSession != nil else { return }

        // Decide the path. Per the plan's "Key Technical Decisions":
        // > Compare device UID before/after to distinguish "device
        // > changed" (full session-rollover candidate) from "format
        // > changed within same device" (cheaper re-tap path; still
        // > triggers heal rule because format affects the analyzer).
        let cachedUID = lastDeviceUID
        let cachedFormat = lastMicFormat

        let sameUID = (deviceUID == cachedUID)
        let sameFormat = formatsEqual(format, cachedFormat)
        let needsHealRule = !sameUID || !sameFormat

        // Stamp gap entry so the heal rule (if invoked below) sees a
        // realistic time-since-engine-stopped. The AVAudioEngine has
        // already stopped by the time the notification arrives, so we
        // approximate "engine stopped" with "now."
        let gapEntry = nowProvider()

        // Build a reason string the TUI surfaces via the
        // .recovering(reason:) event.
        let reason: String
        if !sameUID {
            reason = "device-change:uid:\(deviceUID ?? "nil")"
        } else if !sameFormat {
            reason = "device-change:format"
        } else {
            reason = "device-change:retap"
        }

        // Always go through U5's mic-restart machinery. The restart
        // path tears down the recognizer, runs the (zero-or-short)
        // backoff, and rebuilds via the audio source factory — which
        // owns the new MicrophoneAudioSource + fresh AVAudioEngine.
        await scheduleMicRestart(reason: reason, errorCode: "device_change")

        // Wait for the restart to land before evaluating the heal
        // rule. The restart task we just scheduled will clear
        // micRestartTask on success. We poll the actor's own state
        // (cheap — same actor) up to a short ceiling; if the restart
        // is still going past the ceiling, we punt and let the U5
        // exhaustion path own the outcome.
        let pollDeadline = Date().addingTimeInterval(5.0)
        while micRestartTask != nil && Date() < pollDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        guard needsHealRule else {
            // Cheap re-tap path — restart already ran via U5 (which
            // staged its own `after_gap:Ns` heal marker). No heal-rule
            // invocation, no session boundary change.
            return
        }

        // Engine surrendered? Heal rule has nothing to act on.
        if status == .error { return }

        let gap = nowProvider().timeIntervalSince(gapEntry)
        let outcome = HealRule.decide(
            gap: gap,
            deviceUID: deviceUID,
            lastDeviceUID: cachedUID,
            thresholdSeconds: healThresholdSeconds
        )

        switch outcome {
        case .reuseSession(let healMarker):
            // U5's restart machinery already staged a heal marker on
            // the rebuilt mic pipeline. Replace it with the heal-rule's
            // marker so the segment carries the rule's authoritative
            // value (typically the same `after_gap:Ns` string, but the
            // rule is the source of truth for the format).
            pendingMicHealMarker = healMarker
            pendingMicHealedGap = gap

        case .rollover:
            // UID changed → close current session as `interrupted`
            // and open a fresh active session. Mirrors the wake
            // rollover path: `sweepActiveOrphans()` marks any active
            // session (the current one) as `interrupted`, then
            // `openFreshSession` creates a new active row.
            guard currentSession != nil else { return }
            do {
                try await repository.sweepActiveOrphans()
                let fresh = try await repository.openFreshSession(locale: currentLocale)
                currentSession = fresh
                // Reset segment counter for the fresh session.
                currentSequenceNumber = 0
                segmentCount = 0
                // Clear any pending mic heal-marker — the new session
                // does not carry one (per HealRule contract).
                pendingMicHealMarker = nil
                pendingMicHealedGap = nil
                // Surface the rollover to the TUI.
                await emit(.healed(gapSeconds: gap))
            } catch {
                await emit(.error(
                    "Device-change rollover failed: \(error.localizedDescription)",
                    isTransient: false
                ))
            }
        }
    }

    /// Compare two `AVAudioFormat` values for the purposes of the
    /// device-change handler. Two `nil` formats compare equal (both
    /// "unknown"). Otherwise we compare sample rate, channel count,
    /// and common format — these are the dimensions the analyzer
    /// cares about for the pipeline rebuild decision.
    private nonisolated func formatsEqual(_ a: AVAudioFormat?, _ b: AVAudioFormat?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
    }

    // MARK: - Cleanup

    private func cleanup() async {
        micRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask?.cancel()
        sysRestartTask = nil
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
        micBackoff = BackoffPolicy()
        sysBackoff = BackoffPolicy()
        pendingMicHealMarker = nil
        pendingSysHealMarker = nil
        pendingMicHealedGap = nil
        pendingSysHealedGap = nil
        micRestartEntryTime = nil
        sysRestartEntryTime = nil
        gapStartedAt = nil
        lastMicFormat = nil
    }
}

// MARK: - PowerEventTarget conformance (U6)

/// `RecordingEngine` is the `PowerEventTarget` for
/// `PowerManagementObserver`. Both methods are `async`, satisfied
/// directly by the actor's isolated implementations.
extension RecordingEngine: PowerEventTarget {
    public nonisolated func systemWillSleep() async {
        await handleSystemWillSleep()
    }

    public nonisolated func systemDidWake() async {
        await handleSystemDidWake()
    }
}

// MARK: - AudioDeviceEventTarget conformance (U7)

/// `RecordingEngine` is the `AudioDeviceEventTarget` for
/// `AudioDeviceObserver`. The protocol method is `async`, satisfied
/// directly by the actor's isolated `handleAudioDeviceChange(...)`.
extension RecordingEngine: AudioDeviceEventTarget {
    public nonisolated func audioConfigurationChanged(deviceUID: String?, format: AVAudioFormat?) async {
        await handleAudioDeviceChange(deviceUID: deviceUID, format: format)
    }
}
