import Testing
import Foundation
@testable import StenoDaemon

@Suite("RollingSummaryCoordinator Tests")
struct RollingSummaryCoordinatorTests {

    @Test func triggersAtThreshold() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 5
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        for i in 1...5 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        let summaries = try await repo.summaries(for: session.id)
        let callCount = await summarizer.summarizeCallCount

        #expect(summaries.count == 1)
        #expect(callCount == 1)
    }

    @Test func doesNotTriggerBelowThreshold() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        // Use high time threshold to test count-based trigger only
        // Also use only 2 segments (below the min 3 for time-based trigger)
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 10,
            timeThreshold: 3600  // 1 hour - effectively disables time trigger
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        for i in 1...2 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        let summaries = try await repo.summaries(for: session.id)
        let callCount = await summarizer.summarizeCallCount

        #expect(summaries.isEmpty)
        #expect(callCount == 0)
    }

    @Test func skipsWhenModelUnavailable() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        await summarizer.setAvailable(false)

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let segment = StoredSegment(
            sessionId: session.id,
            text: "Test",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1),
            sequenceNumber: 1,
            createdAt: Date()
        )
        try await repo.saveSegment(segment)
        await coordinator.onSegmentSaved(sessionId: session.id)

        let summaries = try await repo.summaries(for: session.id)

        #expect(summaries.isEmpty)
    }

    @Test func triggersAgainAfterThreshold() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 3
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // First batch - should trigger first summary
        for i in 1...3 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // Second batch - should trigger second summary
        for i in 4...6 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        let summaries = try await repo.summaries(for: session.id)
        let callCount = await summarizer.summarizeCallCount

        #expect(summaries.count == 2)
        #expect(callCount == 2)
    }

    @Test func passesPreviousSummaryToSummarizer() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        await summarizer.setSummaryToReturn("First summary")

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 2,
            // Lower the U12 extraction gate so a 2-segment batch fires.
            minSegmentsForExtraction: 1
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // First batch
        for i in 1...2 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // Check first call had no previous summary
        let firstPreviousSummary = await summarizer.lastPreviousSummary
        #expect(firstPreviousSummary == nil)

        // Second batch
        await summarizer.setSummaryToReturn("Second summary")
        for i in 3...4 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // Check second call received first summary
        let secondPreviousSummary = await summarizer.lastPreviousSummary
        #expect(secondPreviousSummary == "First summary")
    }

    /// PR #36 review (Copilot, RollingSummaryCoordinator.swift:113):
    /// `minSegmentsForExtraction` is documented as a non-duplicate gate,
    /// but the prior implementation counted ALL segments via
    /// `segmentCount(for:)`. After U11's dedup pass, a Zoom-style call
    /// with 5 mic + 5 sys (mic marked `duplicate_of` sys) would have
    /// 10 total but only 5 canonical segments. A gate of 6 must NOT
    /// fire the LLM in that scenario.
    @Test func gateUsesNonDuplicateCount() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1,             // would fire on every save if not gated
            timeThreshold: 0,
            minSegmentsForExtraction: 6  // strictly above the non-dup count of 5
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Seed 5 sys segments (canonical) interleaved with 5 mic
        // segments, each mic segment immediately marked as a duplicate
        // of the matching sys segment. Sequence numbers run 1..10.
        var sysIds: [UUID] = []
        for i in 0..<5 {
            let sysId = UUID()
            let sys = StoredSegment(
                id: sysId,
                sessionId: session.id,
                text: "sys \(i)",
                startedAt: Date().addingTimeInterval(Double(i)),
                endedAt: Date().addingTimeInterval(Double(i) + 1),
                sequenceNumber: 2 * i + 1,
                createdAt: Date(),
                source: .systemAudio
            )
            try await repo.saveSegment(sys)
            sysIds.append(sysId)

            let micId = UUID()
            let mic = StoredSegment(
                id: micId,
                sessionId: session.id,
                text: "mic \(i)",
                startedAt: Date().addingTimeInterval(Double(i)),
                endedAt: Date().addingTimeInterval(Double(i) + 1),
                sequenceNumber: 2 * i + 2,
                createdAt: Date(),
                source: .microphone
            )
            try await repo.saveSegment(mic)
            // Mark the mic segment as a duplicate of the sys segment.
            try await repo.markDuplicate(
                micSegmentId: micId,
                sysSegmentId: sysId,
                method: .normalized
            )
        }

        // Sanity check: 10 segments total, 5 non-duplicate.
        let total = try await repo.segmentCount(for: session.id)
        let nonDup = try await repo.nonDuplicateSegmentCount(for: session.id)
        #expect(total == 10)
        #expect(nonDup == 5)

        // Fire the coordinator. With the bug (gate uses total count),
        // 10 >= 6 so the LLM fires. With the fix (gate uses non-dup
        // count), 5 < 6 so the LLM does NOT fire.
        await coordinator.onSegmentSaved(sessionId: session.id)

        let summarizeCalls = await summarizer.summarizeCallCount
        let topicCalls = await summarizer.extractTopicsCallCount
        #expect(summarizeCalls == 0, "Gate must skip the LLM when non-dup count < gate")
        #expect(topicCalls == 0, "Gate must skip topic extraction when non-dup count < gate")
    }

    @Test func triggersOnTimeThresholdWithMinSegments() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        // Set count threshold high but time threshold to 0 (immediate)
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,  // Won't reach this
            timeThreshold: 0    // Immediate time-based trigger
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Add 3 segments (minimum for time-based trigger)
        for i in 1...3 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: Date(),
                endedAt: Date().addingTimeInterval(1),
                sequenceNumber: i,
                createdAt: Date()
            )
            try await repo.saveSegment(segment)
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        let summaries = try await repo.summaries(for: session.id)
        let callCount = await summarizer.summarizeCallCount

        // Should trigger due to time threshold being met with 3+ segments
        #expect(summaries.count == 1)
        #expect(callCount == 1)
    }
}
