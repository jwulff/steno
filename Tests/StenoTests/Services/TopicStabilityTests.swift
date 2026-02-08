import Testing
import Foundation
@testable import Steno

@Suite("Topic Stability Tests")
struct TopicStabilityTests {

    /// Helper to create a segment for a session.
    private func makeSegment(sessionId: UUID, sequenceNumber: Int, text: String = "Test") -> StoredSegment {
        StoredSegment(
            sessionId: sessionId,
            text: text,
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1),
            sequenceNumber: sequenceNumber,
            createdAt: Date()
        )
    }

    @Test func existingTopicsNotReExtracted() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 5,
            timeThreshold: 3600
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Pre-populate an existing topic covering segments 1-5
        let existingTopic = Topic(
            sessionId: session.id,
            title: "Existing topic",
            summary: "Already extracted.",
            segmentRange: 1...5
        )
        try await repo.saveTopic(existingTopic)

        // Set up mock to return a new topic
        let newTopic = Topic(
            sessionId: session.id,
            title: "New topic",
            summary: "Freshly extracted.",
            segmentRange: 6...10
        )
        await summarizer.setTopicsToReturn([newTopic])

        // Save all 10 segments first, then trigger once via onSegmentSaved.
        // This avoids the time-based trigger (lastTime == nil fires at 3 segments)
        // from firing before uncovered segments exist.
        for i in 1...10 {
            try await repo.saveSegment(makeSegment(sessionId: session.id, sequenceNumber: i))
        }
        let result = await coordinator.onSegmentSaved(sessionId: session.id)
        #expect(result != nil)

        // Verify only uncovered segments (6-10) were sent to extractTopics
        let extractedSegments = await summarizer.lastExtractTopicsSegments
        #expect(extractedSegments != nil)
        #expect(extractedSegments?.allSatisfy { $0.sequenceNumber > 5 } == true)
        #expect(extractedSegments?.count == 5)
    }

    @Test func newTopicsAppendedToExisting() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 5,
            timeThreshold: 3600
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Pre-populate existing topic
        let existingTopic = Topic(
            sessionId: session.id,
            title: "First topic",
            summary: "The first discussion.",
            segmentRange: 1...3
        )
        try await repo.saveTopic(existingTopic)

        // Mock returns a new topic
        let newTopic = Topic(
            sessionId: session.id,
            title: "Second topic",
            summary: "A new discussion.",
            segmentRange: 4...8
        )
        await summarizer.setTopicsToReturn([newTopic])

        // Add enough segments to trigger
        for i in 1...8 {
            try await repo.saveSegment(makeSegment(sessionId: session.id, sequenceNumber: i))
        }

        let result = await coordinator.onSegmentSaved(sessionId: session.id)

        // Result should contain both existing and new topics
        #expect(result != nil)
        #expect(result?.topics.count == 2)
        #expect(result?.topics[0].title == "First topic")
        #expect(result?.topics[1].title == "Second topic")
    }

    @Test func newTopicsPersistedViaRepository() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 5,
            timeThreshold: 3600
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let newTopic = Topic(
            sessionId: session.id,
            title: "Persisted topic",
            summary: "Should be saved.",
            segmentRange: 1...5
        )
        await summarizer.setTopicsToReturn([newTopic])

        for i in 1...5 {
            try await repo.saveSegment(makeSegment(sessionId: session.id, sequenceNumber: i))
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // Verify topic was persisted
        let savedTopics = try await repo.topics(for: session.id)
        #expect(savedTopics.count == 1)
        #expect(savedTopics[0].title == "Persisted topic")
    }

    @Test func noUncoveredSegmentsSkipsExtraction() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        // Use high thresholds; we manually trigger at the end
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 5,
            timeThreshold: 3600
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Existing topic covers all segments (1-10)
        let existingTopic = Topic(
            sessionId: session.id,
            title: "Covers all",
            summary: "Covers everything.",
            segmentRange: 1...10
        )
        try await repo.saveTopic(existingTopic)

        // Add 10 segments (all covered)
        for i in 1...10 {
            try await repo.saveSegment(makeSegment(sessionId: session.id, sequenceNumber: i))
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // extractTopics should NOT have been called
        let callCount = await summarizer.extractTopicsCallCount
        #expect(callCount == 0)
    }

    @Test func extractionFailurePreservesExistingTopics() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        // Use high time threshold to prevent time-based triggers
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 8,
            timeThreshold: 3600
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Pre-populate existing topic
        let existingTopic = Topic(
            sessionId: session.id,
            title: "Preserved topic",
            summary: "Should survive extraction failure.",
            segmentRange: 1...3
        )
        try await repo.saveTopic(existingTopic)

        // Make only extractTopics throw (not summarize/meetingNotes)
        await summarizer.setExtractTopicsShouldThrow(.generationFailed("test error"))

        // Add enough segments to trigger (some uncovered)
        for i in 1...8 {
            try await repo.saveSegment(makeSegment(sessionId: session.id, sequenceNumber: i))
        }

        let result = await coordinator.onSegmentSaved(sessionId: session.id)

        // Result should still contain the existing topic
        #expect(result != nil)
        #expect(result?.topics.count == 1)
        #expect(result?.topics[0].title == "Preserved topic")
    }

    @Test func existingTopicsPassedAsPreviousTopics() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 5,
            timeThreshold: 3600
        )

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Pre-populate existing topic
        let existingTopic = Topic(
            sessionId: session.id,
            title: "Context topic",
            summary: "Passed for context.",
            segmentRange: 1...3
        )
        try await repo.saveTopic(existingTopic)

        await summarizer.setTopicsToReturn([])

        for i in 1...8 {
            try await repo.saveSegment(makeSegment(sessionId: session.id, sequenceNumber: i))
            await coordinator.onSegmentSaved(sessionId: session.id)
        }

        // Verify existing topics were passed as previousTopics
        let previousTopics = await summarizer.lastExtractTopicsPreviousTopics
        #expect(previousTopics != nil)
        #expect(previousTopics?.count == 1)
        #expect(previousTopics?.first?.title == "Context topic")
    }
}
