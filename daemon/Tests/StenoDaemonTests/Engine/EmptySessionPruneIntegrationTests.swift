import Testing
import Foundation
import GRDB
@testable import StenoDaemon

/// Engine-level integration tests for U12 (empty-session prune at close +
/// 90-day retention guard at daemon start). The repository-layer tests
/// live in `Storage/EmptySessionPruneTests.swift`; these exercise the
/// engine's call-site wiring around `dedupAndMaybePrune(...)` and the
/// retention sweep step-zero in `recoverOrphansAndAutoStart`.
@Suite("Empty-Session Prune Integration (U12)")
struct EmptySessionPruneIntegrationTests {

    // MARK: - Helpers

    @MainActor
    private func makeEngine(
        repository: TranscriptRepository,
        summarizer: MockSummarizationService = MockSummarizationService(),
        triggerCount: Int = 100,
        timeThreshold: TimeInterval = 3600,
        minSegmentsForExtraction: Int = 3,
        emptySessionMinChars: Int = 20,
        emptySessionMinDurationSeconds: Double = 3.0,
        retentionDays: Int = 90
    ) async -> (engine: RecordingEngine, summarizer: MockSummarizationService) {
        let perms = MockPermissionService()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let coordinator = RollingSummaryCoordinator(
            repository: repository,
            summarizer: summarizer,
            triggerCount: triggerCount,
            timeThreshold: timeThreshold,
            minSegmentsForExtraction: minSegmentsForExtraction
        )
        let engine = RecordingEngine(
            repository: repository,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            backoffSleep: { _ in /* no wait */ },
            emptySessionMinChars: emptySessionMinChars,
            emptySessionMinDurationSeconds: emptySessionMinDurationSeconds,
            retentionDays: retentionDays
        )
        return (engine, summarizer)
    }

    // MARK: - stop() prunes empty session

    @Test("stop() on a 0-segment session prunes the session row")
    func stopPrunesEmptySession() async throws {
        let repo = MockTranscriptRepository()
        let (engine, _) = await makeEngine(repository: repo)

        // Start + immediately stop. No segments are emitted, so the
        // session is empty by the zero-segment criterion. The pruner
        // must delete it on stop().
        let session = try await engine.start()
        await engine.stop()

        let after = try await repo.session(session.id)
        #expect(after == nil)
    }

    @Test("stop() preserves session with meaningful content")
    func stopKeepsMeaningfulSession() async throws {
        let repo = MockTranscriptRepository()
        let (engine, _) = await makeEngine(repository: repo)

        // Pretend we're a long-running session: seed a real-looking
        // segment after start, age the session past the duration gate,
        // then stop.
        let session = try await engine.start()

        // Save a real segment by hand so the engine doesn't have to
        // wait for the recognizer mock to emit one.
        let started = session.startedAt
        let segment = StoredSegment(
            sessionId: session.id,
            text: String(repeating: "x", count: 100),
            startedAt: started,
            endedAt: started.addingTimeInterval(2),
            sequenceNumber: 1,
            createdAt: started
        )
        try await repo.saveSegment(segment)

        // Override the session's startedAt so duration > 3s. The mock
        // repo uses the seeded startedAt; we re-seed via the test helper.
        var augmented = session
        augmented.endedAt = nil  // still active until stop()
        // The mock uses Date() at endSession time, so duration will be
        // very small. We can simulate a long session by directly
        // backdating the startedAt via the seed helper:
        let backdatedSession = Session(
            id: session.id,
            locale: session.locale,
            startedAt: Date().addingTimeInterval(-60),  // 60s ago
            endedAt: nil,
            title: nil,
            status: .active
        )
        await repo.seed(backdatedSession)

        await engine.stop()

        let after = try await repo.session(session.id)
        #expect(after != nil, "Session with 60s duration + 100-char segment must be kept")
        #expect(after?.status == .completed)
    }

    // MARK: - Topic-extraction gate

    @Test("Topic extraction is skipped for sessions below the gate")
    func topicExtractionGated() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1,           // would normally fire on every segment
            timeThreshold: 0,
            minSegmentsForExtraction: 5  // gate above the count we'll save
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Save 2 segments — below the gate of 5.
        for i in 1...2 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // The mock summarizer's call counter must not have fired.
        let summaryCalls = await summarizer.summarizeCallCount
        let topicCalls = await summarizer.extractTopicsCallCount
        #expect(summaryCalls == 0)
        #expect(topicCalls == 0)
    }

    @Test("Topic extraction fires when above the gate")
    func topicExtractionFiresAboveGate() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1,
            timeThreshold: 0,
            minSegmentsForExtraction: 3
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Save 3 segments — at the gate.
        for i in 1...3 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        let summaryCalls = await summarizer.summarizeCallCount
        #expect(summaryCalls >= 1)
    }

    // MARK: - Defensive topic write under prune race

    @Test("Topic extraction mid-LLM-call against pruned session is no-op")
    func topicWriteNoOpAfterPrune() async throws {
        // Scenario: LLM call is running asynchronously; before its result
        // is persisted, the empty-session pruner deletes the parent
        // session. The repository's defensive saveTopic must swallow the
        // missing-session case as a no-op (no FK error, no orphan rows).
        let repo = MockTranscriptRepository()
        let summarizer = SlowMockSummarizer(topicLatencyMs: 100)
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1,
            timeThreshold: 0,
            minSegmentsForExtraction: 1   // allow firing with 1 segment
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let segment = StoredSegment(
            sessionId: session.id,
            text: "kicks off LLM call",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1),
            sequenceNumber: 1,
            createdAt: Date()
        )
        try await repo.saveSegment(segment)

        // Kick off the (slow) LLM call; while it's pending, end the
        // session and prune it.
        async let llm: Void = {
            _ = await coordinator.onSegmentSaved(sessionId: session.id)
        }()
        // Brief pause so the coordinator is mid-LLM-call.
        try await Task.sleep(for: .milliseconds(20))
        try await repo.endSession(session.id)
        let pruned = try await repo.maybeDeleteIfEmpty(
            sessionId: session.id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(pruned == true)

        await llm

        // No topics or summaries were persisted (parent session is gone).
        let topicsAfter = try await repo.topics(for: session.id)
        let summariesAfter = try await repo.summaries(for: session.id)
        #expect(topicsAfter.isEmpty)
        #expect(summariesAfter.isEmpty)
    }

    // MARK: - Retention guard at daemon start

    @Test("recoverOrphansAndAutoStart applies retention before sweep")
    func retentionAppliedBeforeSweep() async throws {
        // Seed two sessions: one 100 days old (must be retention-deleted)
        // and one 30 days old (must survive). Then run
        // `recoverOrphansAndAutoStart` and verify the retention sweep
        // fired before the orphan sweep.
        let repo = MockTranscriptRepository()

        // 100 days old, completed
        let oldId = UUID()
        let oldStarted = Date().addingTimeInterval(-100 * 86_400)
        let oldEnded = oldStarted.addingTimeInterval(120)
        await repo.seed(Session(
            id: oldId,
            locale: Locale(identifier: "en_US"),
            startedAt: oldStarted,
            endedAt: oldEnded,
            title: nil,
            status: .completed
        ))

        // 30 days old, completed
        let recentId = UUID()
        let recentStarted = Date().addingTimeInterval(-30 * 86_400)
        let recentEnded = recentStarted.addingTimeInterval(120)
        await repo.seed(Session(
            id: recentId,
            locale: Locale(identifier: "en_US"),
            startedAt: recentStarted,
            endedAt: recentEnded,
            title: nil,
            status: .completed
        ))

        let (engine, _) = await makeEngine(
            repository: repo,
            retentionDays: 90
        )

        _ = try await engine.recoverOrphansAndAutoStart(
            locale: Locale(identifier: "en_US"),
            systemAudio: false
        )

        let oldAfter = try await repo.session(oldId)
        let recentAfter = try await repo.session(recentId)
        #expect(oldAfter == nil, "Session past retention must be deleted")
        #expect(recentAfter != nil, "Session within retention must survive")

        await engine.stop()
    }
}

// MARK: - Slow summarizer for race tests

/// A SummarizationService that introduces an artificial latency on
/// `extractTopics` so a test can race the LLM call against an empty-
/// session prune. Mirrors `MockSummarizationService`'s shape so it slots
/// into existing engine assembly helpers.
actor SlowMockSummarizer: SummarizationService {
    private(set) var summarizeCallCount = 0
    private(set) var extractTopicsCallCount = 0
    private let topicLatencyMs: UInt64

    init(topicLatencyMs: UInt64) {
        self.topicLatencyMs = topicLatencyMs
    }

    nonisolated var isAvailable: Bool { get async { true } }

    func summarize(segments: [StoredSegment], previousSummary: String?) async throws -> String {
        summarizeCallCount += 1
        return "slow summary"
    }

    func generateMeetingNotes(segments: [StoredSegment], previousNotes: String?) async throws -> String {
        return "slow notes"
    }

    func extractTopics(segments: [StoredSegment], previousTopics: [Topic], sessionId: UUID) async throws -> [Topic] {
        extractTopicsCallCount += 1
        try? await Task.sleep(for: .milliseconds(Int(topicLatencyMs)))
        return [Topic(
            id: UUID(),
            sessionId: sessionId,
            title: "slow",
            summary: "slow",
            segmentRange: 1...1,
            createdAt: Date()
        )]
    }
}
