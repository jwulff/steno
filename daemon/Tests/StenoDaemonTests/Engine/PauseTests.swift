import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U10's `RecordingEngine.pause(autoResumeSeconds:)` /
/// `resume()` actor methods + the wall-clock auto-resume timer + the
/// daemon-restart pause-state recovery (R-F privacy invariant).
@Suite("Pause/Resume Tests (U10)")
struct PauseTests {

    // MARK: - Engine assembly helper

    @MainActor
    private func makeEngine(
        repository: MockTranscriptRepository? = nil,
        delegate: MockRecordingEngineDelegate? = nil,
        pauseTimer: PauseTimer? = nil
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        audioFactory: MockAudioSourceFactory,
        recognizerFactory: MockSpeechRecognizerFactory,
        delegate: MockRecordingEngineDelegate
    ) {
        let repo = repository ?? MockTranscriptRepository()
        let perms = MockPermissionService()
        let summarizer = MockSummarizationService()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let del = delegate ?? MockRecordingEngineDelegate()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )

        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del,
            backoffSleep: { _ in },
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0,
            pauseTimer: pauseTimer
        )
        return (engine, repo, af, rf, del)
    }

    // MARK: - Happy paths

    @Test("pause(autoResumeSeconds: 1800) → status .paused, current session closed, pauseExpiresAt persisted")
    func pauseTimedHappyPath() async throws {
        let (engine, repo, _, _, _) = await makeEngine()

        let started = try await engine.start()
        let initialId = started.id

        try await engine.pause(autoResumeSeconds: 1800)

        let status = await engine.status
        #expect(status == .paused)

        // The starting session was closed cleanly.
        let closed = try await repo.session(initialId)
        #expect(closed?.status == .completed)

        // Pause state persisted on the closed session.
        #expect(closed?.pausedIndefinitely == false)
        if let expiresAt = closed?.pauseExpiresAt {
            // Should be ~30 minutes from now.
            let drift = expiresAt.timeIntervalSinceNow
            #expect(drift > 1700 && drift < 1900)
        } else {
            Issue.record("pauseExpiresAt should be set on the closed session")
        }

        // Engine has no current session while paused.
        let currentSession = await engine.currentSession
        #expect(currentSession == nil)
    }

    @Test("pause(autoResumeSeconds: nil) → indefinite, pauseExpiresAt nil, paused_indefinitely=1")
    func pauseIndefiniteHappyPath() async throws {
        let (engine, repo, _, _, _) = await makeEngine()

        let started = try await engine.start()
        let id = started.id

        try await engine.pause(autoResumeSeconds: nil)

        let status = await engine.status
        #expect(status == .paused)

        let closed = try await repo.session(id)
        #expect(closed?.pausedIndefinitely == true)
        #expect(closed?.pauseExpiresAt == nil)
    }

    @Test("pauseStateChanged event emitted with correct fields on pause + resume")
    func pauseStateChangedEvents() async throws {
        let (engine, _, _, _, delegate) = await makeEngine()

        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: 600)
        try await engine.resume()

        // First pause-state event: paused=true, indefinite=false, expiresAt set.
        let events = await delegate.events
        let pauseEvents: [(Bool, Bool, Date?)] = events.compactMap {
            if case .pauseStateChanged(let p, let i, let e) = $0 { return (p, i, e) }
            return nil
        }
        #expect(pauseEvents.count >= 2)
        if pauseEvents.count >= 2 {
            #expect(pauseEvents[0].0 == true)
            #expect(pauseEvents[0].1 == false)
            #expect(pauseEvents[0].2 != nil)

            #expect(pauseEvents.last?.0 == false)
            #expect(pauseEvents.last?.2 == nil)
        }
    }

    @Test("resume after timed pause opens a fresh active session, status .recording")
    func resumeAfterTimedPauseOpensFreshSession() async throws {
        let (engine, repo, _, _, _) = await makeEngine()

        let started = try await engine.start()
        try await engine.pause(autoResumeSeconds: 600)

        try await engine.resume()

        let status = await engine.status
        #expect(status == .recording)

        let current = await engine.currentSession
        #expect(current != nil)
        #expect(current?.id != started.id)

        // Pause state was cleared on the prior anchor.
        let prior = try await repo.session(started.id)
        #expect(prior?.pausedIndefinitely == false)
        #expect(prior?.pauseExpiresAt == nil)
    }

    @Test("resume while indefinitely paused opens fresh active session")
    func resumeWhileIndefinitelyPaused() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: nil)

        try await engine.resume()

        let status = await engine.status
        #expect(status == .recording)
    }

    // MARK: - Edge cases

    @Test("pause while already paused → reject")
    func pauseWhilePausedRejects() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: 600)

        await #expect(throws: RecordingEngineError.self) {
            try await engine.pause(autoResumeSeconds: 600)
        }
    }

    @Test("resume while not paused → reject")
    func resumeWhileNotPausedRejects() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()

        await #expect(throws: RecordingEngineError.self) {
            try await engine.resume()
        }
    }

    @Test("pause from .idle → reject")
    func pauseFromIdleRejects() async throws {
        let (engine, _, _, _, _) = await makeEngine()

        await #expect(throws: RecordingEngineError.self) {
            try await engine.pause(autoResumeSeconds: 600)
        }
    }

    // MARK: - Auto-resume timer

    @Test("Auto-resume timer fires at deadline → engine transitions to recording")
    func autoResumeTimerFires() async throws {
        let (engine, _, _, _, delegate) = await makeEngine()

        _ = try await engine.start()
        // Use a tiny window to keep the test fast.
        try await engine.pause(autoResumeSeconds: 0.150)

        // Wait up to 2s for the auto-resume to drive engine back to .recording.
        let resumed = await waitFor(timeout: 2.0) {
            await engine.status == .recording
        }
        #expect(resumed)

        // A pauseStateChanged(false) event was emitted.
        let events = await delegate.events
        let resumedEvents = events.contains { evt in
            if case .pauseStateChanged(let p, _, _) = evt, p == false { return true }
            return false
        }
        #expect(resumedEvents)
    }

    // MARK: - Daemon-restart pause-state recovery (privacy-critical)

    @Test("Daemon restart with pause_expires_at in future → engine restores .paused, timer re-armed (U10 R-F)")
    func daemonRestartTimedPauseRestoresPausedState() async throws {
        let repo = MockTranscriptRepository()

        let pausedId = UUID()
        let originalPauseStart = Date().addingTimeInterval(-180)  // 3 min ago
        let expiresAt = originalPauseStart.addingTimeInterval(300)  // 5 min from then = 2 min from now
        await repo.seed(Session(
            id: pausedId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: originalPauseStart,
            title: nil,
            status: .completed,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: expiresAt,
            pausedIndefinitely: false
        ))

        let (engine, _, _, _, delegate) = await makeEngine(repository: repo)

        _ = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        let status = await engine.status
        #expect(status == .paused)

        // Pause-state snapshot reports the persisted expiresAt.
        let snapshot = await engine.pauseStateSnapshot()
        #expect(snapshot.paused == true)
        #expect(snapshot.indefinite == false)
        #expect(snapshot.expiresAt != nil)

        // pauseStateChanged emitted with the correct fields.
        let events = await delegate.events
        #expect(events.contains { evt in
            if case .pauseStateChanged(let p, let i, _) = evt {
                return p == true && i == false
            }
            return false
        })
    }

    @Test("Daemon restart with pause_expires_at in past + paused_indefinitely=0 → resumes immediately into fresh session")
    func daemonRestartPauseExpiredResumes() async throws {
        let repo = MockTranscriptRepository()

        let pausedId = UUID()
        await repo.seed(Session(
            id: pausedId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-1800),
            title: nil,
            status: .completed,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: Date().addingTimeInterval(-300),  // 5 min ago
            pausedIndefinitely: false
        ))

        let (engine, _, _, _, _) = await makeEngine(repository: repo)

        let fresh = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        #expect(fresh != nil)
        let status = await engine.status
        #expect(status == .recording)
    }

    @Test("Daemon restart with paused_indefinitely=1 → engine restores .paused, NOT recording, no timer (privacy-critical)")
    func daemonRestartIndefinitePauseStaysPaused() async throws {
        let repo = MockTranscriptRepository()

        let pausedId = UUID()
        await repo.seed(Session(
            id: pausedId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-1800),
            title: nil,
            status: .completed,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: nil,
            pausedIndefinitely: true
        ))

        let (engine, _, _, _, _) = await makeEngine(repository: repo)

        _ = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        let status = await engine.status
        #expect(status == .paused)
        let snapshot = await engine.pauseStateSnapshot()
        #expect(snapshot.indefinite == true)
        #expect(snapshot.expiresAt == nil)
    }

    // MARK: - Sleep/wake while paused

    @Test("handleSystemWillSleep while paused → no-op (no gap stamped, status stays .paused)")
    func willSleepWhilePausedNoOp() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: 600)

        await engine.handleSystemWillSleep()

        let status = await engine.status
        #expect(status == .paused)
    }

    @Test("handleSystemDidWake while paused → no-op (no pipelines brought up)")
    func didWakeWhilePausedNoOp() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: 600)

        await engine.handleSystemDidWake()

        let status = await engine.status
        #expect(status == .paused)
        let current = await engine.currentSession
        #expect(current == nil)
    }

    // MARK: - Persistence-failure path

    @Test("setPauseState persistence error surfaces non-transient pause_state_unverifiable warning")
    func setPauseStatePersistenceFailureSurfacesWarning() async throws {
        let repo = MockTranscriptRepository()
        let (engine, _, _, _, delegate) = await makeEngine(repository: repo)

        _ = try await engine.start()

        // Inject a persistence error on the pause-state write.
        await repo.setSetPauseStateError(
            MockTranscriptRepository.InjectedError("simulated DB write failure")
        )

        try await engine.pause(autoResumeSeconds: 600)

        // Engine still entered `.paused` in-memory, but a non-transient
        // pause_state_unverifiable warning was surfaced.
        let status = await engine.status
        #expect(status == .paused)

        let errors = await delegate.errors
        #expect(errors.contains(where: { $0.0.contains("pause_state_unverifiable") && $0.1 == false }))
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: TimeInterval,
        step: TimeInterval = 0.020,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(Int(step * 1000)))
        }
        return false
    }
}
