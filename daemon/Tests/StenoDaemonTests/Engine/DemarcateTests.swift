import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U10's `RecordingEngine.demarcate()` actor method — atomic
/// session boundary with timestamp-based segment routing.
@Suite("Demarcate Tests (U10)")
struct DemarcateTests {

    // MARK: - Engine assembly helper

    @MainActor
    private func makeEngine(
        repository: MockTranscriptRepository? = nil,
        delegate: MockRecordingEngineDelegate? = nil
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
            retentionDays: 0
        )
        return (engine, repo, af, rf, del)
    }

    // MARK: - Happy path

    @Test("demarcate during recording → current session ends, fresh session active, audio pipelines NOT torn down")
    func demarcateClosesAndOpensFreshSession() async throws {
        let (engine, repo, _, recognizerFactory, _) = await makeEngine()

        let started = try await engine.start()
        let initialId = started.id

        let fresh = try await engine.demarcate()
        #expect(fresh.id != initialId)

        // Status remains .recording — no audio teardown.
        let status = await engine.status
        #expect(status == .recording)

        // Closing session is now `completed` with endedAt set.
        let closed = try await repo.session(initialId)
        #expect(closed?.status == .completed)
        #expect(closed?.endedAt != nil)

        // Fresh session is active.
        let active = try await repo.session(fresh.id)
        #expect(active?.status == .active)

        // The mic recognizer was NOT stopped — pipelines continue.
        #expect(recognizerFactory.micHandle.stopCalled == false)
    }

    @Test("demarcate returns the new session and engine.currentSession matches")
    func demarcateReturnsAndUpdatesCurrentSession() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()

        let fresh = try await engine.demarcate()
        let current = await engine.currentSession
        #expect(current?.id == fresh.id)
    }

    // MARK: - Edge cases

    @Test("demarcate while paused → reject")
    func demarcateWhilePausedRejects() async throws {
        let (engine, _, _, _, _) = await makeEngine()
        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: 600)

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.demarcate()
        }
    }

    @Test("demarcate from .idle → reject")
    func demarcateFromIdleRejects() async throws {
        let (engine, _, _, _, _) = await makeEngine()

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.demarcate()
        }
    }

    // MARK: - Timestamp routing (the load-bearing scenario)

    @Test("Pre-T finalized segment routes to previous session; post-T routes to fresh session")
    func segmentTimestampRouting() async throws {
        let (engine, repo, _, recognizerFactory, _) = await makeEngine()

        let started = try await engine.start()
        let preDemarcateId = started.id

        // Allow pipelines to settle.
        try await Task.sleep(for: .milliseconds(20))

        let beforeT = Date()
        // Drive demarcate. T = nowProvider() inside the call, which is
        // ~now. We then emit two finalized segments: one with a startedAt
        // strictly BEFORE T, one strictly AFTER T.
        let fresh = try await engine.demarcate()

        // Pre-T segment — startedAt is well before the demarcate moment.
        let preFinal = RecognizerResult(
            text: "spoke before demarcate",
            isFinal: true,
            confidence: 0.9,
            timestamp: beforeT.addingTimeInterval(-1.0),
            source: .microphone
        )
        recognizerFactory.micHandle.emit(preFinal)

        // Wait for that segment to land.
        try await Task.sleep(for: .milliseconds(100))

        // Pre-T segment landed on the previous session.
        let prevSegments = try await repo.segments(for: preDemarcateId)
        #expect(prevSegments.contains(where: { $0.text == "spoke before demarcate" }))

        // Now emit a post-T segment with a timestamp clearly after the
        // demarcate moment.
        let postFinal = RecognizerResult(
            text: "spoke after demarcate",
            isFinal: true,
            confidence: 0.9,
            timestamp: Date().addingTimeInterval(1.0),
            source: .microphone
        )
        recognizerFactory.micHandle.emit(postFinal)

        try await Task.sleep(for: .milliseconds(100))

        let freshSegments = try await repo.segments(for: fresh.id)
        #expect(freshSegments.contains(where: { $0.text == "spoke after demarcate" }))

        // Pre-T text should NOT appear on the fresh session.
        #expect(!freshSegments.contains(where: { $0.text == "spoke before demarcate" }))
        // Post-T text should NOT appear on the previous session.
        let prevSegmentsAfter = try await repo.segments(for: preDemarcateId)
        #expect(!prevSegmentsAfter.contains(where: { $0.text == "spoke after demarcate" }))
    }
}
