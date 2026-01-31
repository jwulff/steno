import Testing
import Foundation
@testable import Steno

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

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 10
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
            triggerCount: 2
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
}
