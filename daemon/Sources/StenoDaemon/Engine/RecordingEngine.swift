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
    private let dedupCoordinator: DedupCoordinator?
    private let dedupTriggerDebounce: Duration
    private let audioSourceFactory: AudioSourceFactory
    private let speechRecognizerFactory: SpeechRecognizerFactory
    private var delegate: (any RecordingEngineDelegate)?

    // MARK: - U12 prune + retention thresholds

    /// Min non-duplicate text length below which a just-closed session is
    /// pruned. Resolved from `StenoSettings.emptySessionMinChars`.
    private let emptySessionMinChars: Int

    /// Min wall-clock duration below which a just-closed session is pruned.
    /// Resolved from `StenoSettings.emptySessionMinDurationSeconds`.
    private let emptySessionMinDurationSeconds: Double

    /// Retention cap (days). Sessions older than this are cascade-deleted
    /// at daemon-start (top of `recoverOrphansAndAutoStart`). 0 disables.
    /// Resolved from `StenoSettings.retentionDays`.
    private let retentionDays: Int

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

    /// Peak linear-PCM amplitude observed on the mic across the *current
    /// in-flight segment*. Updated on every buffer (max), snapshotted +
    /// converted to dBFS at segment-finalize time, then reset on the next
    /// partial-text emission for that source. `0` represents silence /
    /// no-buffers-seen-yet — the converter floors the dBFS at -90 to
    /// avoid `log10(0) = -inf`.
    private var currentMicSegmentPeak: Float = 0

    // MARK: - U11 dedup-trigger debounce state

    /// Per-session trailing-edge debounce tasks. A fresh `saveSegment`
    /// trigger replaces the prior task with a new one that sleeps for the
    /// configured debounce window and then runs `dedupCoordinator.runPass`.
    /// Multiple segment writes within the window collapse to a single pass.
    private var pendingDedupTriggers: [UUID: Task<Void, Never>] = [:]

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

    // MARK: - U10 pause / demarcate state

    /// Wall-clock auto-resume timer. Armed during `pause(autoResumeSeconds:)`
    /// when a non-nil interval was supplied. Fires `resume()` at the
    /// absolute deadline; survives system sleep via `DispatchWallTime`.
    private let pauseTimer: PauseTimer

    /// The session row used as the pause anchor. `pause` writes
    /// `pause_expires_at` and `paused_indefinitely` onto this row before
    /// closing it; `resume` (manual or timer-fired) clears them on the
    /// same row. `nil` outside the paused state.
    private var pausedSessionId: UUID?

    /// Cached pause-state copy on the engine — readable by the dispatcher
    /// without round-tripping the DB. Mirrors what was last persisted via
    /// `setPauseState`. Cleared on resume.
    private var pauseExpiresAt: Date?
    private var isPauseIndefinite: Bool = false

    /// True while `pause()` / `resume()` is mid-flight, OR the engine has
    /// settled into `.paused`. The pause-resume gate uses this to reject
    /// concurrent pause-while-pausing and resume-while-resuming attempts;
    /// `status == .paused` is the canonical "currently paused" check.
    private var pauseInProgress: Bool = false

    /// Last device captured at the last successful pipeline bring-up,
    /// reused by `resume()` if the engine bring-up does not pass an
    /// explicit device.
    /// (Preserved when entering `.paused`; `cleanup()` does NOT clear this.)
    private var lastUsedDevice: String?

    /// Last system-audio flag captured at the last successful pipeline
    /// bring-up. Reused by `resume()` so the post-pause configuration
    /// matches the pre-pause configuration.
    private var lastUsedSystemAudio: Bool = false

    /// Demarcate timestamp routing. Set to the wall-clock instant of a
    /// `demarcate()` call; while non-nil, finalized segments whose
    /// `startedAt < demarcationTimestamp` are routed to the previous
    /// session id, segments at or after T are routed to the current
    /// session. Cleared after the first finalized segment with
    /// `startedAt >= T` lands on the new session, OR after a 10s
    /// grace window (`demarcationGraceSeconds`).
    private var demarcationTimestamp: Date?
    private var previousSessionId: UUID?
    private var demarcationClearTask: Task<Void, Never>?

    /// Queue a demarcate request that arrived during `.recovering`. The
    /// pending boundary is applied on the next return-to-`.recording`
    /// transition. The plan calls this out as the "queue" choice over
    /// "reject" because the user expectation is that a spacebar tap
    /// during a transient blip should still split the session.
    private var pendingDemarcate: Bool = false

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
        now: @Sendable @escaping () -> Date = { Date() },
        dedupCoordinator: DedupCoordinator? = nil,
        dedupTriggerDebounce: Duration = .seconds(5),
        emptySessionMinChars: Int = 20,
        emptySessionMinDurationSeconds: Double = 3.0,
        retentionDays: Int = 90,
        pauseTimer: PauseTimer? = nil
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
        self.dedupCoordinator = dedupCoordinator
        self.dedupTriggerDebounce = dedupTriggerDebounce
        self.emptySessionMinChars = emptySessionMinChars
        self.emptySessionMinDurationSeconds = emptySessionMinDurationSeconds
        self.retentionDays = retentionDays
        self.pauseTimer = pauseTimer ?? PauseTimer()
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

        // Reset backoff state on every entry into `.starting`. This is
        // a no-op when we came from `.idle` (a fresh `BackoffPolicy` is
        // already there), but it is load-bearing when we came from
        // `.error`: a prior surrender leaves `isExhausted == true`, and
        // the next transient failure would otherwise short-circuit
        // straight back to `recoveryExhausted` without retrying. See
        // PR #35 review (issue 2).
        micBackoff = BackoffPolicy()
        sysBackoff = BackoffPolicy()

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
        // Rehydrate the segment counter from the repository every time
        // we bring up pipelines. For a brand-new session the MAX query
        // returns 0 (so the first segment lands at sequenceNumber=1, as
        // before). For a *resumed* session — wake/reuse, device-change
        // reuse — we pick up where the pre-sleep segments left off,
        // avoiding collisions under the `UNIQUE(sessionId,
        // sequenceNumber)` schema constraint that previously caused
        // post-wake segment writes to fail silently until the counter
        // naturally passed the old max. See PR #35 review (issue 1).
        let resumeFrom = (try? await repository.maxSegmentSequence(for: session.id)) ?? 0
        currentSequenceNumber = resumeFrom
        segmentCount = resumeFrom
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

        // U10: remember the device + system-audio configuration so a
        // post-pause `resume()` re-builds against the same selection.
        // Placed AFTER the setStatus to keep the U10 state writes off
        // any error paths.
        lastUsedDevice = device
        lastUsedSystemAudio = systemAudio

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

        // Reset backoff state when coming out of `.error`. A prior
        // surrender leaves `isExhausted == true`; without this reset,
        // the next transient failure after the auto-start completes
        // would short-circuit back to `recoveryExhausted` instead of
        // honouring the curve. From `.idle` this is a no-op. See
        // PR #35 review (issue 2).
        micBackoff = BackoffPolicy()
        sysBackoff = BackoffPolicy()

        // Step 0: U12 retention guard. Cascade-delete sessions whose
        // `endedAt` is older than the retention cap. Runs BEFORE the
        // orphan sweep so old data is cleaned up first, leaving the
        // sweep + prune to act only on recent rows. Best-effort: a
        // failure here is logged transiently and we proceed — the
        // sweep is more important to the daemon's health than the
        // retention policy.
        if retentionDays > 0 {
            do {
                let deleted = try await repository.applyRetentionPolicy(
                    retentionDays: retentionDays
                )
                if deleted > 0 {
                    await emit(.recovering(
                        reason: "retention:purged=\(deleted) sessions older than \(retentionDays)d"
                    ))
                }
            } catch {
                await emit(.error(
                    "Daemon-start: retention sweep failed: \(error.localizedDescription)",
                    isTransient: true
                ))
            }
        }

        // Step 1: orphan sweep first (independent of pause-state and
        // permissions). R9 — stranded `active` rows must be closed on
        // every daemon start. Failure here surfaces non-transiently and
        // ends the call without crashing or opening a fresh session.
        let sweptOrphanIds: [UUID]
        do {
            sweptOrphanIds = try await repository.sweepActiveOrphans()
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

        // U12: prune swept orphans that meet any empty-criterion. The
        // repository check is conservative — orphans with real (post-dedup)
        // text or duration are KEPT (R9 says crashed sessions are valuable
        // even when interrupted). The pruner's behavior is identical to
        // the close-path call: dedup pass first, then maybeDeleteIfEmpty.
        for orphanId in sweptOrphanIds {
            await dedupAndMaybePrune(sessionId: orphanId)
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
                // U10: restore the paused engine state from the persisted
                // DB row. Re-arms the wall-clock timer for the remaining
                // window (timed pauses) or stays paused indefinitely. The
                // privacy invariant: we do NOT bring up pipelines.
                await emit(.error(
                    "Daemon-start: pause is still active (paused_indefinitely=\(mostRecent.pausedIndefinitely)" +
                    ", pause_expires_at=\(mostRecent.pauseExpiresAt.map { String($0.timeIntervalSince1970) } ?? "nil"))" +
                    " — restoring paused engine state",
                    isTransient: false
                ))
                // Pre-populate locale + last-known device so a future
                // resume bringup uses the same configuration.
                currentLocale = mostRecent.locale
                lastUsedDevice = device
                lastUsedSystemAudio = systemAudio
                await restorePausedState(
                    sessionId: mostRecent.id,
                    expiresAt: mostRecent.pauseExpiresAt,
                    indefinite: mostRecent.pausedIndefinitely
                )
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
            || status == .recovering
            || status == .paused else { return }

        // U10: if we were paused, cancel the auto-resume timer and clear
        // pause-state markers. The DB anchor is left as-is (the user can
        // restart manually and the next daemon-start sees the row state).
        if status == .paused {
            pauseTimer.cancel()
            pausedSessionId = nil
            pauseExpiresAt = nil
            isPauseIndefinite = false
            await setStatus(.idle)
            return
        }

        isStopping = true
        await setStatus(.stopping)

        // Cancel any in-flight restart tasks. Their `Task.sleep(for:)`
        // raises CancellationError and the loop returns early without
        // re-arming a rebuild attempt. Capture, cancel, then await to
        // guarantee the tasks have fully unwound before `stop()` returns —
        // otherwise their tail cleanup (which touches actor state) can
        // race against the test fixture's release of the engine, surfacing
        // as `freed pointer was not the last allocation` at process exit.
        let priorMicRestart = micRestartTask
        let priorSysRestart = sysRestartTask
        micRestartTask = nil
        sysRestartTask = nil
        priorMicRestart?.cancel()
        priorSysRestart?.cancel()
        await priorMicRestart?.value
        await priorSysRestart?.value

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

        // End session, then run dedup + empty-session prune (U12). The
        // prune runs unconditionally on close; sessions that don't meet
        // any empty-criterion remain. Future U10 pause/demarcate close
        // paths use the same `dedupAndMaybePrune(sessionId:)` helper.
        let closingSessionId = currentSession?.id
        if let id = closingSessionId {
            try? await repository.endSession(id)
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

        // U11: cancel any in-flight dedup-trigger debounce tasks. Their
        // sleeps will throw and the tasks return without invoking the
        // coordinator — a clean teardown.
        for (_, task) in pendingDedupTriggers { task.cancel() }
        pendingDedupTriggers.removeAll()
        currentMicSegmentPeak = 0

        // U10: clear demarcate routing on full stop. The pause timer
        // does not need explicit cancellation here — if a pause was
        // active we'd have hit the `.paused` early return above.
        pendingDemarcate = false
        clearDemarcationRouting()

        // U12: dedup + empty-session prune for the just-closed session.
        // Done AFTER the cancel-all above so the synchronous pass we run
        // here is the only one in-flight. The pruner is no-op on
        // sessions that meet none of the empty criteria.
        if let id = closingSessionId {
            await dedupAndMaybePrune(sessionId: id)
        }

        await setStatus(.idle)
        isStopping = false
    }

    /// List available audio devices.
    public func availableDevices() async -> [AudioDevice] {
        // Placeholder — real implementation queries Core Audio
        []
    }

    /// Current cached mic format from the last successful pipeline
    /// bring-up. Used by `AudioDeviceObserver`'s `formatProvider`
    /// closure so the trailing-edge fire compares against the engine's
    /// real current format instead of always-nil — without this, U7's
    /// "same UID + same format" cheap-restart optimization never fires
    /// (lastMicFormat is non-nil after start, the provider always
    /// returns nil → comparison always reports a format mismatch).
    /// See PR #35 review (issue 5).
    public func currentMicFormat() -> AVAudioFormat? {
        lastMicFormat
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

            // U10 demarcate timestamp routing: a finalized segment whose
            // audio-frame `startedAt` precedes the demarcate moment T is
            // attributed to the previously-closed session; segments at
            // or after T land on the new (current) session.
            //
            // **Assumption (load-bearing, U1 was skipped):** `result.timestamp`
            // is the audio-frame start instant. If real-world testing of
            // SpeechAnalyzer shows otherwise, the plan's fallback is to
            // plumb wall-clock timestamps through the audio path
            // independent of the recognizer.
            //
            // The first finalized segment with `startedAt >= T` clears the
            // demarcate state — segments arriving after that always land on
            // the current session. A 10s grace task also clears it if no
            // such segment ever arrives.
            let routingSessionId: UUID
            if let demarcateAt = demarcationTimestamp,
               let prevId = previousSessionId,
               result.timestamp < demarcateAt {
                routingSessionId = prevId
            } else {
                routingSessionId = session.id
                // First post-T segment clears the routing state.
                if demarcationTimestamp != nil {
                    clearDemarcationRouting()
                }
            }

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

            // U11: snapshot the per-segment mic peak (linear PCM) and
            // convert to dBFS for the dedup audio-level guard. Reset to
            // 0 so the next mic segment's metering starts fresh. Sys-side
            // segments don't carry this — `mic_peak_db` is mic-only.
            let micPeakDb: Double?
            if result.source == .microphone {
                micPeakDb = Self.linearPeakToDbFS(currentMicSegmentPeak)
                currentMicSegmentPeak = 0
            } else {
                micPeakDb = nil
            }

            // U10 demarcate routing: if attributing to the previous session,
            // we need a sequence number greater than that session's MAX (so
            // we don't violate UNIQUE(sessionId, sequenceNumber)). Cheap
            // single-indexed lookup; we only do it when actively routing.
            // Otherwise the bumped `currentSequenceNumber` is the right key.
            let segmentSequence: Int
            if routingSessionId != session.id {
                // Don't waste a slot on the current session for a routed
                // segment — back the counter off by 1 and use the previous
                // session's own next-slot.
                currentSequenceNumber -= 1
                segmentCount = currentSequenceNumber
                let prevMax = (try? await repository.maxSegmentSequence(for: routingSessionId)) ?? 0
                segmentSequence = prevMax + 1
            } else {
                segmentSequence = currentSequenceNumber
            }

            let segment = StoredSegment(
                sessionId: routingSessionId,
                text: result.text,
                startedAt: result.timestamp,
                endedAt: Date(),
                confidence: result.confidence,
                sequenceNumber: segmentSequence,
                source: result.source,
                healMarker: healMarker,
                micPeakDb: micPeakDb
            )

            // Persist
            do {
                try await repository.saveSegment(segment)
            } catch {
                await emit(.error("Failed to save segment: \(error)", isTransient: true))
                return
            }

            await emit(.segmentFinalized(segment))

            // U11: schedule a debounced dedup pass for the session this
            // segment landed on (routing-aware — a demarcate-routed
            // segment queues dedup against its previous-session anchor,
            // not the current session). The pass runs in a detached task
            // so the segment-save hot path is not blocked. Multiple
            // triggers within the debounce window collapse to a single
            // pass per session.
            scheduleDedupTrigger(sessionId: routingSessionId)

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

            // Trigger summary against the session the segment landed on.
            await emit(.modelProcessing(true))
            let summaryResult = await summaryCoordinator.onSegmentSaved(sessionId: routingSessionId)
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

        // U8: mic-side TCC revocation surface. AVAudioEngine permission
        // errors (typically `kAudioServicesNoSuchHardware`-class or
        // AVAudioSession permission-denied errors) are NON-RETRYABLE —
        // cycling through U5's backoff loop on TCC revocation produces
        // ambiguous orange-indicator flicker while silently failing.
        // The exact `MIC_OR_SCREEN_PERMISSION_REVOKED` token is
        // load-bearing: U9's TUI surface matches on it.
        if source == .microphone,
           MicrophonePermissionErrorDetector.isPermissionRevocation(error) {
            await handleMicrophonePermissionRevoked(message: message)
            return
        }

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

    /// Handle a microphone TCC-revocation surface. Tear down the mic
    /// pipeline (no rebuild), emit the load-bearing
    /// `MIC_OR_SCREEN_PERMISSION_REVOKED` `recoveryExhausted` event,
    /// transition to `.error`. Mirrors the SCStream `userDeclined`
    /// path (see `systemAudioPermissionRevoked()` below) so the TUI
    /// surfaces a single non-transient failure regardless of which
    /// pipeline tripped the revocation.
    private func handleMicrophonePermissionRevoked(message: String) async {
        // Cancel any in-flight mic restart loop — it would only
        // re-enter this path on the next attempt anyway.
        micRestartTask?.cancel()
        micRestartTask = nil

        // Tear down the mic pipeline so the engine is in a clean
        // state when the user re-grants permission and a future
        // command (or U6/U9 retry path) re-attempts bringup.
        recognizerTask?.cancel()
        recognizerTask = nil
        await micRecognizerHandle?.stop()
        micRecognizerHandle = nil
        await micStopClosure?()
        micStopClosure = nil

        await emit(.recoveryExhausted(reason: micOrScreenPermissionRevokedToken))
        await setStatus(.error)
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
            // Rebuild itself failed (e.g. `makeMicrophoneSource` or
            // `makeRecognizer` threw immediately). Without explicit
            // re-scheduling here, `handleRecognizerError` never fires
            // again — there is no recognizer consumer task left to
            // surface a failure — so the mic pipeline would stay stuck
            // until the next external stimulus (device-change,
            // sleep/wake). The original `record(error:)` call near the
            // top of this function already bumped the policy for this
            // attempt; the rebuild failure is the realization of that
            // same attempt. We re-enter the restart loop by enqueuing
            // a fresh task, which calls `record(error:)` again at its
            // top — counting as the next attempt. See PR #35 review
            // (issues 3 & 4).
            await emit(.error(
                "Mic pipeline rebuild failed: \(error.localizedDescription)",
                isTransient: true
            ))
            let nestedCode = self.errorCode(for: error)
            // Honour cancellation arriving during the rebuild — don't
            // schedule another attempt if the engine is being torn down.
            micRestartTask = nil
            micRestartEntryTime = nil
            if isStopping || status == .stopping || status == .idle || Task.isCancelled {
                return
            }
            // If the policy is already exhausted, surrender now. We
            // peek at the policy without bumping it again — the next
            // `restartMicPipeline` invocation would call `record` for
            // us, and we don't want to double-count this rebuild
            // failure.
            if micBackoff.isExhausted {
                await emit(.recoveryExhausted(reason: "rebuild:\(error.localizedDescription)"))
                await setStatus(.error)
                return
            }
            await scheduleMicRestart(
                reason: "rebuild:\(error.localizedDescription)",
                errorCode: nestedCode
            )
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
        // U8: re-wire the SCStream recovery delegate on the rebuilt source.
        if let recoverable = source as? SystemAudioSource {
            recoverable.recoveryDelegate = self
        }

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
            // Mirror of mic-side handling — see `restartMicPipeline`'s
            // catch block. Without an explicit reschedule, the system
            // pipeline stays stuck after a rebuild throw because there
            // is no recognizer consumer task left to re-trigger
            // `handleRecognizerError`. PR #35 review (issue 4).
            await emit(.error(
                "System pipeline rebuild failed: \(error.localizedDescription)",
                isTransient: true
            ))
            let nestedCode = self.errorCode(for: error)
            sysRestartTask = nil
            sysRestartEntryTime = nil
            if isStopping || status == .stopping || status == .idle || Task.isCancelled {
                return
            }
            if sysBackoff.isExhausted {
                await emit(.recoveryExhausted(reason: "rebuild:\(error.localizedDescription)"))
                await setStatus(.error)
                return
            }
            await scheduleSysRestart(
                reason: "rebuild:\(error.localizedDescription)",
                errorCode: nestedCode
            )
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

        // U10: if a `demarcate()` arrived while we were `.recovering`,
        // apply the boundary now that recovery completed. Failures here
        // are best-effort logged — the demarcate UX expects a successful
        // boundary, but a DB failure shouldn't take down the engine.
        if pendingDemarcate {
            pendingDemarcate = false
            do {
                _ = try await performDemarcate()
            } catch {
                await emit(.error(
                    "Queued demarcate failed: \(error.localizedDescription)",
                    isTransient: true
                ))
            }
        }
    }

    private func startSystemAudio(locale: Locale) async {
        let source = audioSourceFactory.makeSystemAudioSource()
        systemAudioSource = source
        // U8: wire the SCStream recovery delegate so error-code-aware
        // recovery flows back through the engine. Production source is
        // `SystemAudioSource`; mocks (e.g. `MockAudioSource`) are not
        // required to support recovery delegation — the SCStream
        // delegate path is exercised directly in
        // `SystemAudioSourceTests` against synthetic NSErrors.
        if let recoverable = source as? SystemAudioSource {
            recoverable.recoveryDelegate = self
        }

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
        // U11: track the peak across the *current in-flight mic segment*
        // for the dedup audio-level guard. Snapshotted + reset on segment
        // finalize.
        currentMicSegmentPeak = max(currentMicSegmentPeak, peak)
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

    /// Convert a linear-PCM peak (0.0–1.0) to dBFS for the U11 dedup
    /// audio-level guard. Floors at -90 dBFS for silence to avoid
    /// `log10(0) = -inf`. Anything at or above 1.0 (clipping) reports as
    /// 0 dBFS.
    static func linearPeakToDbFS(_ peak: Float) -> Double {
        let p = Double(peak)
        guard p > 0 else { return -90.0 }
        let db = 20.0 * log10(min(p, 1.0))
        return max(-90.0, db)
    }

    // MARK: - U11 Dedup-Trigger Debounce

    /// Schedule (or reset) the trailing-edge debounce timer for a session's
    /// dedup pass. A new trigger replaces any prior pending task — the new
    /// one sleeps for `dedupTriggerDebounce`, then runs the pass. If the
    /// engine has no `dedupCoordinator` (test default), this is a no-op.
    private func scheduleDedupTrigger(sessionId: UUID) {
        guard let coordinator = dedupCoordinator else { return }
        // Cancel the prior pending task — its sleep will throw and the
        // task returns without invoking the coordinator.
        pendingDedupTriggers[sessionId]?.cancel()
        let debounce = dedupTriggerDebounce
        let task: Task<Void, Never> = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self else { return }
            await self.clearPendingDedupTrigger(sessionId: sessionId)
            // The coordinator owns its own reentrance — multiple cross-session
            // passes can run in parallel; same-session collapse is the
            // coordinator's responsibility.
            await coordinator.runPass(sessionId: sessionId)
        }
        pendingDedupTriggers[sessionId] = task
    }

    /// Clear the entry for a session's pending trigger. Called by the
    /// debounce task itself after it fires (so a fresh trigger arriving
    /// AFTER the pass starts schedules a new task rather than racing).
    private func clearPendingDedupTrigger(sessionId: UUID) {
        pendingDedupTriggers[sessionId] = nil
    }

    // MARK: - U12 Empty-Session Prune

    /// Run a synchronous dedup pass for the just-closed session, then ask
    /// the repository to prune it if it meets any empty-session criterion.
    /// Sequencing matters: dedup-then-prune ensures the pruner's
    /// "non-duplicate text length" check sees the post-dedup truth (mic
    /// segments newly marked as duplicates of sys segments don't count
    /// toward the threshold). Failures in either step are logged via the
    /// `.error` event channel as transient — pruning is best-effort.
    ///
    /// Cancels any pending debounced dedup trigger for this session: that
    /// debounced pass would otherwise run AFTER the synchronous pass +
    /// prune, possibly against a deleted session. Cancelling here is the
    /// cleanest way to avoid that wasted pass and the matching FK-check
    /// inside the dedup repo calls.
    ///
    /// Called by every session-close path: `stop()`, sleep-rollover (U6),
    /// device-change-rollover (U7), the daemon-start orphan sweep
    /// (U4 → `recoverOrphansAndAutoStart`), and the future U10 pause /
    /// resume / demarcate paths (those callers wire it themselves).
    private func dedupAndMaybePrune(sessionId: UUID) async {
        // 1. Cancel any in-flight debounced trigger for this session.
        pendingDedupTriggers[sessionId]?.cancel()
        pendingDedupTriggers[sessionId] = nil

        // 2. Synchronous dedup pass first (so the pruner's non-dup-text
        //    check is meaningful). The coordinator owns its own
        //    reentrance — if a pass is already running it returns
        //    `.empty` and we move on. Borderline by design: a concurrent
        //    pass might still be writing duplicates as we read counts;
        //    the pruner's threshold is conservative enough that this
        //    doesn't change outcomes in practice.
        if let coordinator = dedupCoordinator {
            _ = await coordinator.runPass(sessionId: sessionId)
        }

        // Pruner is "disabled" sentinel: both thresholds at 0 means tests
        // (or a config that wants the pruner off) skip the delete entirely.
        // The "non_dup_count == 0" criterion would otherwise still trigger
        // even with `minChars: 0` because zero-segment sessions are always
        // empty by count.
        guard emptySessionMinChars > 0 || emptySessionMinDurationSeconds > 0 else {
            return
        }

        // 3. Pruner. Tolerates already-deleted sessions (returns false).
        do {
            _ = try await repository.maybeDeleteIfEmpty(
                sessionId: sessionId,
                minChars: emptySessionMinChars,
                minDurationSeconds: emptySessionMinDurationSeconds
            )
        } catch {
            await emit(.error(
                "Empty-session pruner failed for session \(sessionId): \(error.localizedDescription)",
                isTransient: true
            ))
        }
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
        // U10: while paused, no audio is being captured and no power
        // assertion is held. Nothing to drain. The pause timer keeps
        // running through sleep (DispatchWallTime-based).
        if status == .paused {
            return
        }

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

        // U10: while paused, wake is a no-op. The pause timer is wall-
        // clock based (DispatchWallTime) and continues to advance during
        // sleep, so it fires on its own when the deadline lands. We do
        // NOT bring up pipelines while paused — the privacy invariant.
        if status == .paused {
            return
        }

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
                let sweptIds = try await repository.sweepActiveOrphans()
                let fresh = try await repository.openFreshSession(locale: currentLocale)
                // U12: prune the just-closed session(s) if empty. Done
                // AFTER opening the fresh session so the new session is
                // already in place when the prune commits. The new
                // session is `active` and therefore not eligible for the
                // pruner's defensive guard.
                for sweptId in sweptIds {
                    await dedupAndMaybePrune(sessionId: sweptId)
                }
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
                let sweptIds = try await repository.sweepActiveOrphans()
                let fresh = try await repository.openFreshSession(locale: currentLocale)
                currentSession = fresh
                // Reset segment counter for the fresh session.
                currentSequenceNumber = 0
                segmentCount = 0
                // Clear any pending mic heal-marker — the new session
                // does not carry one (per HealRule contract).
                pendingMicHealMarker = nil
                pendingMicHealedGap = nil
                // U12: prune the just-closed session(s) if empty. Done
                // AFTER currentSession is replaced so a concurrent path
                // referencing currentSession sees the fresh row.
                for sweptId in sweptIds {
                    await dedupAndMaybePrune(sessionId: sweptId)
                }
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

    // MARK: - U10 Pause / Resume / Demarcate

    /// Hard pause. Closes the current session cleanly, tears down both
    /// pipelines, releases the power assertion, and persists pause state
    /// on the most-recent session row so daemon restart re-enters the
    /// paused state (R-F privacy invariant).
    ///
    /// While paused: NO audio capture, NO recognizer, NO power assertion.
    ///
    /// - Parameter autoResumeSeconds: If non-nil, arm a wall-clock timer
    ///   to fire `resume()` after this many seconds. The timer survives
    ///   sleep (`DispatchWallTime`). `nil` → indefinite pause, no timer.
    public func pause(autoResumeSeconds: TimeInterval?) async throws {
        // Allowed-from gate. From `.recording`, `.recovering`, or `.error`:
        // valid pause entry (R3 — pause is always available, even from a
        // surrendered engine). From `.paused`/`.starting`/`.stopping`/
        // `.idle`: reject — there's nothing to pause cleanly.
        guard status == .recording || status == .recovering || status == .error else {
            throw RecordingEngineError.notRecording
        }
        if pauseInProgress { throw RecordingEngineError.notRecording }
        pauseInProgress = true
        defer { pauseInProgress = false }

        // Cancel any in-flight backoff/restart tasks. Their cancellable
        // sleeps abort with CancellationError and the tasks return early.
        micRestartTask?.cancel()
        micRestartTask = nil
        sysRestartTask?.cancel()
        sysRestartTask = nil

        // Tear down pipelines. Stop the recognizer consumer FIRST so the
        // recognizer-error path doesn't trigger another restart while we
        // are mid-pause.
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

        // Release the power assertion now that no capture is in flight.
        // The `.recording → .paused` transition in `setStatus` would
        // also release it, but releasing here is idempotent and makes
        // the ordering explicit.
        powerAssertion.release()

        // Close the current session (if any) and run dedup + prune
        // exactly like the `stop()` close-path. The closing session
        // becomes our pause anchor.
        let closingSessionId = currentSession?.id
        if let id = closingSessionId {
            try? await repository.endSession(id)
        }
        currentSession = nil
        // Cancel any pending demarcate/dedup-trigger machinery — we are
        // ending this session cleanly.
        clearDemarcationRouting()
        for (_, task) in pendingDedupTriggers { task.cancel() }
        pendingDedupTriggers.removeAll()

        // Compute pause state from caller arguments.
        let now = nowProvider()
        let expiresAt: Date?
        let indefinite: Bool
        if let secs = autoResumeSeconds {
            expiresAt = now.addingTimeInterval(secs)
            indefinite = false
        } else {
            expiresAt = nil
            indefinite = true
        }

        // Persist pause state on the just-closed session (the canonical
        // anchor — `mostRecentlyModifiedSession()` will return this row
        // on daemon-start).
        if let id = closingSessionId {
            do {
                try await repository.setPauseState(
                    sessionId: id,
                    expiresAt: expiresAt,
                    indefinite: indefinite
                )
            } catch {
                // Persistence failed. Surface non-transient — the user's
                // pause intent could not be persisted, so a daemon restart
                // would silently resume into recording. Rather than
                // silently degrade, we still enter `.paused` in-memory but
                // emit a non-transient warning matching U4's
                // `pause_state_unverifiable` token so the TUI surfaces it.
                await emit(.error(
                    "pause_state_unverifiable: failed to persist pause state on session \(id) (\(error.localizedDescription))",
                    isTransient: false
                ))
            }
        }

        // Now run dedup + prune for the just-closed session (synchronous).
        if let id = closingSessionId {
            await dedupAndMaybePrune(sessionId: id)
        }

        // In-memory pause state.
        pausedSessionId = closingSessionId
        pauseExpiresAt = expiresAt
        isPauseIndefinite = indefinite

        // Arm the auto-resume timer if applicable. The closure trampolines
        // back onto the actor via `Task` and calls `resume()` — failures
        // there surface their own events.
        if let deadline = expiresAt {
            pauseTimer.arm(at: deadline) { [weak self] in
                Task { [weak self] in
                    try? await self?.resume()
                }
            }
        }

        await setStatus(.paused)
        await emit(.pauseStateChanged(
            paused: true,
            indefinite: indefinite,
            expiresAt: expiresAt
        ))
    }

    /// Resume from a paused state. Cancels the auto-resume timer (if any),
    /// clears persisted pause state on the anchor session row, opens a
    /// fresh active session, and brings up pipelines around it.
    public func resume() async throws {
        guard status == .paused else {
            throw RecordingEngineError.notRecording
        }
        if pauseInProgress { throw RecordingEngineError.notRecording }
        pauseInProgress = true
        defer { pauseInProgress = false }

        // Cancel the auto-resume timer in case `resume()` was called
        // manually before the timer fired.
        pauseTimer.cancel()

        // Clear pause state on the anchor session row.
        if let anchorId = pausedSessionId {
            do {
                try await repository.clearPauseState(sessionId: anchorId)
            } catch {
                // Best-effort — log transient. A failure here doesn't
                // prevent the resume; the columns may simply re-trigger
                // the pause-state-restore guard on the next daemon start
                // (depending on the row's actual state).
                await emit(.error(
                    "Failed to clear pause state on session \(anchorId): \(error.localizedDescription)",
                    isTransient: true
                ))
            }
        }

        // Reset U5 backoff state — we're entering a fresh recording session.
        micBackoff = BackoffPolicy()
        sysBackoff = BackoffPolicy()

        await setStatus(.starting)

        // Open a fresh active session. Permissions are NOT re-checked on
        // resume — the user's prior consent is still in force; if a TCC
        // revocation lands, U8's revocation-detector surfaces it on the
        // first failed bring-up.
        let session: Session
        do {
            session = try await repository.openFreshSession(locale: currentLocale)
        } catch {
            await setStatus(.error)
            await emit(.error(
                "Resume: failed to open fresh session: \(error.localizedDescription)",
                isTransient: false
            ))
            // Clear pause state in-memory so subsequent commands don't
            // think we're still paused.
            pausedSessionId = nil
            pauseExpiresAt = nil
            isPauseIndefinite = false
            await emit(.pauseStateChanged(paused: false, indefinite: false, expiresAt: nil))
            throw error
        }

        // Bring up pipelines around the fresh session, restoring the
        // pre-pause device + system-audio configuration.
        do {
            _ = try await bringUpPipelines(
                session: session,
                locale: currentLocale,
                device: lastUsedDevice,
                systemAudio: lastUsedSystemAudio
            )
        } catch {
            // bringUpPipelines already transitioned to `.error` and
            // emitted a non-transient event. Clear pause-state markers.
            pausedSessionId = nil
            pauseExpiresAt = nil
            isPauseIndefinite = false
            await emit(.pauseStateChanged(paused: false, indefinite: false, expiresAt: nil))
            throw error
        }

        // Pause-state cleanup.
        pausedSessionId = nil
        pauseExpiresAt = nil
        isPauseIndefinite = false

        await emit(.pauseStateChanged(paused: false, indefinite: false, expiresAt: nil))
    }

    /// Atomic session boundary at T = `nowProvider()`. Closes the current
    /// session at T (sets `endedAt`), opens a fresh active session at T,
    /// and seeds timestamp-based segment routing so in-flight partial
    /// transcriptions land on the correct side of the boundary.
    ///
    /// Pipelines continue uninterrupted — no audio teardown, no recognizer
    /// reset.
    ///
    /// - Returns: the newly opened active session.
    @discardableResult
    public func demarcate() async throws -> Session {
        switch status {
        case .recording:
            return try await performDemarcate()
        case .recovering:
            // Queue: the next return-to-`.recording` transition applies
            // the boundary. Better UX than reject — a spacebar tap during
            // a transient blip splits the session as the user expects.
            pendingDemarcate = true
            // Caller still wants a Session value back; the contract here
            // is "the boundary will fire when recovery completes." We
            // return the current session (effectively the closing one)
            // so the caller has a non-nil result; tests that need precise
            // semantics drive through `performDemarcate` directly.
            if let current = currentSession { return current }
            throw RecordingEngineError.notRecording
        case .paused:
            // Reject — paused has no current session to demarcate. The
            // user must explicitly resume first ("press p to resume").
            throw RecordingEngineError.notRecording
        case .idle, .starting, .stopping, .error:
            throw RecordingEngineError.notRecording
        }
    }

    /// The actual demarcate implementation, factored so the queued path
    /// (`pendingDemarcate` -> heal completion) can call it on the same
    /// terms.
    private func performDemarcate() async throws -> Session {
        guard let closing = currentSession else {
            throw RecordingEngineError.notRecording
        }

        let demarcateAt = nowProvider()

        // Close the current session at T. We set endedAt via the standard
        // `endSession` path (which uses `Date()` for endedAt) — the wall-
        // clock skew between T and the DB write is the natural latency of
        // the storage operation and well under our segment-routing
        // tolerance.
        try? await repository.endSession(closing.id)

        // Open a fresh active session at T.
        let fresh = try await repository.openFreshSession(locale: currentLocale)

        // Seed timestamp-based routing. In-flight finalized segments
        // arriving with `result.timestamp < demarcateAt` will be
        // attributed to `closing`; segments at/after T land on `fresh`.
        previousSessionId = closing.id
        demarcationTimestamp = demarcateAt

        // Reset segment counter for the fresh session — segments routed
        // to the previous session use a per-target MAX lookup so they
        // don't collide.
        currentSequenceNumber = 0
        segmentCount = 0

        // Cancel any pending heal-marker — a demarcate is a clean session
        // boundary, NOT a heal-in-place. The first segment of the new
        // session does NOT carry a heal marker.
        pendingMicHealMarker = nil
        pendingSysHealMarker = nil
        pendingMicHealedGap = nil
        pendingSysHealedGap = nil

        // Replace currentSession AFTER seeding routing so a concurrent
        // segment-finalize sees consistent state.
        currentSession = fresh

        // Schedule a 10s grace task to clear demarcation routing if no
        // post-T segment ever arrives (e.g., silence). Without this, a
        // long-running pre-T finalize could route to the previous
        // session forever.
        demarcationClearTask?.cancel()
        let grace: Double = 10.0
        demarcationClearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(grace))
            } catch {
                return
            }
            await self?.clearDemarcationRouting()
        }

        // Run dedup + prune on the just-closed session — same close-path
        // sequencing as `stop()`, `pause()`, sleep-rollover (U6), and
        // device-change-rollover (U7).
        await dedupAndMaybePrune(sessionId: closing.id)

        return fresh
    }

    /// Clear the demarcate routing state. Called on (a) the first finalized
    /// segment with `startedAt >= demarcationTimestamp`, (b) the 10s grace
    /// task firing, and (c) any session-close path so the next session
    /// starts with a clean slate.
    private func clearDemarcationRouting() {
        previousSessionId = nil
        demarcationTimestamp = nil
        demarcationClearTask?.cancel()
        demarcationClearTask = nil
    }

    /// Restore the engine into `.paused` from a persisted DB row. Used by
    /// the daemon-start path (U4 → `recoverOrphansAndAutoStart`) when the
    /// most-recent session row indicates a still-active pause that must
    /// outlive the daemon restart (R-F privacy invariant).
    ///
    /// Differs from `pause()` in that it doesn't close a session (the
    /// pause anchor is already closed), doesn't release a power assertion
    /// (none was held), and doesn't run dedup/prune (already done at the
    /// original pause time). It DOES re-arm the wall-clock timer for the
    /// remaining wall-clock interval.
    public func restorePausedState(
        sessionId: UUID,
        expiresAt: Date?,
        indefinite: Bool
    ) async {
        // Cache the pause anchor so a manual resume can clear the row.
        pausedSessionId = sessionId
        pauseExpiresAt = expiresAt
        isPauseIndefinite = indefinite

        // Re-arm timer if the pause is timed and not yet expired.
        if !indefinite, let deadline = expiresAt {
            // If the deadline is already in the past, fire immediately —
            // DispatchWallTime semantics handle this for us, but a sub-
            // second drift between the daemon-start check and the timer
            // arming is OK.
            pauseTimer.arm(at: deadline) { [weak self] in
                Task { [weak self] in
                    try? await self?.resume()
                }
            }
        }

        await setStatus(.paused)
        await emit(.pauseStateChanged(
            paused: true,
            indefinite: indefinite,
            expiresAt: expiresAt
        ))
    }

    /// Read-only snapshot of pause state for the dispatcher's `status`
    /// response. Returns `(paused, indefinite, expiresAt)`.
    public func pauseStateSnapshot() -> (paused: Bool, indefinite: Bool, expiresAt: Date?) {
        return (status == .paused, isPauseIndefinite, pauseExpiresAt)
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
        for (_, task) in pendingDedupTriggers { task.cancel() }
        pendingDedupTriggers.removeAll()
        currentMicSegmentPeak = 0
        // U10: cancel pause timer + clear demarcate routing on full cleanup.
        // Use `peek` to avoid lazily instantiating the timer here.
        pauseTimer.cancel()
        pausedSessionId = nil
        pauseExpiresAt = nil
        isPauseIndefinite = false
        pendingDemarcate = false
        clearDemarcationRouting()
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

// MARK: - SystemAudioRecoveryDelegate conformance (U8)

/// `RecordingEngine` is the `SystemAudioRecoveryDelegate` for
/// `SystemAudioSource`. The SCStream's delegate callback runs on its
/// own internal queue; both methods are `async` and trampoline back
/// onto the actor's isolation domain via the actor-isolated
/// `handleSystemAudio*` implementations.
extension RecordingEngine: SystemAudioRecoveryDelegate {

    /// Called by `SystemAudioSource.stream(_:didStopWithError:)` after
    /// classifying a transient SCStream error. Routes through U5's
    /// `restartSystemPipeline(reason:errorCode:)` so the bounded
    /// backoff handles wait + rebuild + surrender semantics. The
    /// `errorCode` is the `domain#code` backoff key that
    /// `BackoffPolicy` uses for "same-error" tracking.
    public nonisolated func systemAudioRequestsRetry(errorCode: String, reason: String) async {
        await handleSystemAudioRetry(errorCode: errorCode, reason: reason)
    }

    /// Called by `SystemAudioSource.stream(_:didStopWithError:)` after
    /// classifying `userDeclined` (Screen Recording TCC revocation).
    /// Emits a non-transient `recoveryExhausted` event with the
    /// load-bearing `MIC_OR_SCREEN_PERMISSION_REVOKED` token,
    /// transitions to `.error`, does NOT retry.
    public nonisolated func systemAudioPermissionRevoked() async {
        await handleSystemAudioPermissionRevoked()
    }
}

extension RecordingEngine {

    /// Actor-isolated handler for SCStream-driven retry requests. Drops
    /// the request if a sys restart is already in flight (the in-flight
    /// restart will rebuild against the freshly-classified failure
    /// state) or if the engine is mid-teardown.
    func handleSystemAudioRetry(errorCode: String, reason: String) async {
        if isStopping || status == .stopping || status == .idle { return }
        if sysRestartTask != nil { return }
        await scheduleSysRestart(reason: reason, errorCode: errorCode)
    }

    /// Actor-isolated handler for SCStream `userDeclined` (TCC
    /// revocation). Mirrors `handleMicrophonePermissionRevoked` in
    /// shape: tear down the sys pipeline, emit the load-bearing
    /// recoveryExhausted event, transition to `.error`. Mic
    /// pipeline is unaffected — engine isolation between mic and sys
    /// is preserved.
    func handleSystemAudioPermissionRevoked() async {
        // Cancel any in-flight sys restart.
        sysRestartTask?.cancel()
        sysRestartTask = nil

        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil
        await sysRecognizerHandle?.stop()
        sysRecognizerHandle = nil
        await systemAudioSource?.stop()
        systemAudioSource = nil

        await emit(.recoveryExhausted(reason: micOrScreenPermissionRevokedToken))
        await setStatus(.error)
    }
}
