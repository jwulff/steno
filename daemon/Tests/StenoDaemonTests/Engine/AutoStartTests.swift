import Testing
import Foundation
import GRDB
@testable import StenoDaemon

/// Tests for U4's `RecordingEngine.recoverOrphansAndAutoStart()`.
///
/// Covers the daemon-start auto-start path: orphan sweep + fresh session +
/// pipeline bringup, plus the privacy-critical pause-state-restore guard.
@Suite("RecordingEngine Auto-Start Tests")
struct AutoStartTests {

    // MARK: - Engine assembly helper

    @MainActor
    private func makeEngine(
        repository: MockTranscriptRepository? = nil,
        permissionService: MockPermissionService? = nil,
        audioFactory: MockAudioSourceFactory? = nil,
        recognizerFactory: MockSpeechRecognizerFactory? = nil,
        delegate: MockRecordingEngineDelegate? = nil
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        permissions: MockPermissionService,
        audioFactory: MockAudioSourceFactory,
        recognizerFactory: MockSpeechRecognizerFactory,
        delegate: MockRecordingEngineDelegate
    ) {
        let repo = repository ?? MockTranscriptRepository()
        let perms = permissionService ?? MockPermissionService()
        let summarizer = MockSummarizationService()
        let af = audioFactory ?? MockAudioSourceFactory()
        let rf = recognizerFactory ?? MockSpeechRecognizerFactory()
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
            delegate: del
        )

        return (engine, repo, perms, af, rf, del)
    }

    // MARK: - Happy path

    @Test("Auto-start opens fresh active session and reaches recording")
    func autoStartFreshDatabase() async throws {
        let (engine, repo, _, _, _, delegate) = await makeEngine()

        let session = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        #expect(session != nil)
        let status = await engine.status
        #expect(status == .recording)

        // The TUI-equivalent observation: status is `recording` and
        // currentSession is the freshly opened session, not nil.
        let currentSession = await engine.currentSession
        #expect(currentSession?.id == session?.id)

        // Session is active and persisted.
        if let id = session?.id {
            let fetched = try await repo.session(id)
            #expect(fetched?.status == .active)
        }

        let statuses = await delegate.statusChanges
        #expect(statuses.contains(.starting))
        #expect(statuses.contains(.recording))

        await engine.stop()
    }

    @Test("Auto-start sweeps stranded active sessions before bringing up pipelines")
    func autoStartSweepsOrphan() async throws {
        let repo = MockTranscriptRepository()

        // Seed an orphan active session.
        let orphanId = UUID()
        let orphanStartedAt = Date().addingTimeInterval(-3600)
        let orphan = Session(
            id: orphanId,
            locale: Locale(identifier: "en_US"),
            startedAt: orphanStartedAt,
            endedAt: nil,
            title: nil,
            status: .active
        )
        await repo.seed(orphan)

        let (engine, _, _, _, _, _) = await makeEngine(repository: repo)

        let fresh = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        // Orphan is closed.
        let orphanAfter = try await repo.session(orphanId)
        #expect(orphanAfter?.status == .interrupted)
        // Fresh session is active and distinct.
        #expect(fresh?.id != orphanId)
        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    // MARK: - Error path

    @Test("Auto-start failure (permission denied) leaves engine in error state with non-transient event")
    func autoStartPermissionDenied() async throws {
        let perms = await MainActor.run { MockPermissionService() }
        await MainActor.run { perms.denyAll() }

        let (engine, _, _, _, _, delegate) = await makeEngine(permissionService: perms)

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.recoverOrphansAndAutoStart(
                locale: Locale(identifier: "en_US"),
                systemAudio: false
            )
        }

        let status = await engine.status
        #expect(status == .error)

        let errors = await delegate.errors
        #expect(!errors.isEmpty)
        // First error should be non-transient.
        #expect(errors.contains(where: { $0.1 == false }))
    }

    @Test("Auto-start orphan sweep still ran successfully even when bringup fails")
    func autoStartSweepSurvivesBringupFailure() async throws {
        let repo = MockTranscriptRepository()

        // Seed an orphan active session.
        let orphanId = UUID()
        await repo.seed(Session(
            id: orphanId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: nil,
            title: nil,
            status: .active
        ))

        // Force the audio source to throw, simulating a mic-bringup failure.
        let af = MockAudioSourceFactory()
        af.micError = RecordingEngineError.audioSourceFailed("mic unavailable")

        let (engine, _, _, _, _, _) = await makeEngine(repository: repo, audioFactory: af)

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.recoverOrphansAndAutoStart(
                locale: Locale(identifier: "en_US"),
                systemAudio: false
            )
        }

        // Critical invariant: the orphan sweep completed BEFORE the
        // bringup attempt, so the orphan must be `interrupted` even
        // though the engine is now in `.error`.
        let orphanAfter = try await repo.session(orphanId)
        #expect(orphanAfter?.status == .interrupted)

        let status = await engine.status
        #expect(status == .error)
    }

    // MARK: - Idle/error guard

    @Test("Auto-start while already recording throws alreadyRecording")
    func autoStartWhileRecordingThrows() async throws {
        let (engine, _, _, _, _, _) = await makeEngine()

        _ = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.recoverOrphansAndAutoStart(
                locale: Locale(identifier: "en_US"),
                systemAudio: false
            )
        }

        await engine.stop()
    }

    // MARK: - Pause-state restore (privacy-critical)

    @Test("Pause-state-restore: paused_indefinitely=1 prevents auto-start, sweeps orphans, engine stays idle")
    func pausedIndefinitelyPreventsAutoStart() async throws {
        let repo = MockTranscriptRepository()

        // Seed an orphan + a paused-indefinitely session as the most-recent.
        let orphanId = UUID()
        await repo.seed(Session(
            id: orphanId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-7200),
            endedAt: nil,
            title: nil,
            status: .active
        ))

        let pausedId = UUID()
        await repo.seed(Session(
            id: pausedId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: Date().addingTimeInterval(-1800),
            title: nil,
            status: .completed,  // closed at pause-time
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: nil,
            pausedIndefinitely: true
        ))

        let (engine, _, _, _, _, delegate) = await makeEngine(repository: repo)

        let result = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        // No fresh active session opened.
        #expect(result == nil)

        // Engine remains idle (privacy-critical: not `.recording`).
        let status = await engine.status
        #expect(status == .idle)

        // Orphan is still closed (sweep ran).
        let orphanAfter = try await repo.session(orphanId)
        #expect(orphanAfter?.status == .interrupted)

        // No fresh active session in the DB.
        let all = try await repo.allSessions()
        let activeCount = all.filter { $0.status == .active }.count
        #expect(activeCount == 0)

        // A non-transient error/log event was emitted explaining the skip.
        let errors = await delegate.errors
        #expect(errors.contains(where: { $0.0.contains("pause is still active") && $0.1 == false }))
    }

    @Test("Pause-state-restore: pause_expires_at in the future prevents auto-start")
    func pauseExpiresAtFuturePreventsAutoStart() async throws {
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
            pauseExpiresAt: Date().addingTimeInterval(300),  // 5 min in the future
            pausedIndefinitely: false
        ))

        let (engine, _, _, _, _, _) = await makeEngine(repository: repo)

        let result = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        #expect(result == nil)
        let status = await engine.status
        #expect(status == .idle)
    }

    @Test("Pause-state-restore: pause_expires_at in the past allows auto-start to proceed")
    func pauseExpiresAtPastAllowsAutoStart() async throws {
        let repo = MockTranscriptRepository()

        let pausedId = UUID()
        await repo.seed(Session(
            id: pausedId,
            locale: Locale(identifier: "en_US"),
            startedAt: Date().addingTimeInterval(-7200),
            endedAt: Date().addingTimeInterval(-3600),
            title: nil,
            status: .completed,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: Date().addingTimeInterval(-300),  // expired 5 min ago
            pausedIndefinitely: false
        ))

        let (engine, _, _, _, _, _) = await makeEngine(repository: repo)

        let fresh = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        #expect(fresh != nil)
        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    // MARK: - Integration: TUI sees recording state

    @Test("Integration: after auto-start, currentSession reflects fresh session, status is recording")
    func tuiObservesRecordingAndSessionId() async throws {
        let (engine, _, _, _, _, _) = await makeEngine()

        let session = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        // Simulating the TUI's status query.
        let observedStatus = await engine.status
        let observedSession = await engine.currentSession

        #expect(observedStatus == .recording)
        #expect(observedStatus != .idle)
        #expect(observedSession != nil)
        #expect(observedSession?.id == session?.id)
        #expect(observedSession?.status == .active)

        await engine.stop()
    }
}
