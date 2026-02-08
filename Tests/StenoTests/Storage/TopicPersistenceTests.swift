import Testing
import Foundation
import GRDB
@testable import Steno

@Suite("Topic Persistence Tests")
struct TopicPersistenceTests {

    @Test func saveAndFetchTopic() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let topic = Topic(
            sessionId: session.id,
            title: "Budget review",
            summary: "Q2 budget was approved.",
            segmentRange: 1...5
        )

        try await repo.saveTopic(topic)
        let topics = try await repo.topics(for: session.id)

        #expect(topics.count == 1)
        #expect(topics[0].title == "Budget review")
        #expect(topics[0].summary == "Q2 budget was approved.")
        #expect(topics[0].segmentRange == 1...5)
        #expect(topics[0].sessionId == session.id)
    }

    @Test func topicsOrderedBySegmentRangeStart() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        // Insert in reverse order
        let topic2 = Topic(sessionId: session.id, title: "Second", summary: "B.", segmentRange: 6...10)
        let topic1 = Topic(sessionId: session.id, title: "First", summary: "A.", segmentRange: 1...5)

        try await repo.saveTopic(topic2)
        try await repo.saveTopic(topic1)

        let topics = try await repo.topics(for: session.id)

        #expect(topics.count == 2)
        #expect(topics[0].title == "First")
        #expect(topics[1].title == "Second")
    }

    @Test func cascadeDeleteWithSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let topic = Topic(sessionId: session.id, title: "Test", summary: "Testing.", segmentRange: 1...3)
        try await repo.saveTopic(topic)

        try await repo.deleteSession(session.id)

        let topics = try await repo.topics(for: session.id)
        #expect(topics.isEmpty)
    }

    @Test func topicsIsolatedBetweenSessions() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session1 = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let session2 = try await repo.createSession(locale: Locale(identifier: "en_US"))

        try await repo.saveTopic(Topic(sessionId: session1.id, title: "S1 Topic", summary: "In session 1.", segmentRange: 1...3))
        try await repo.saveTopic(Topic(sessionId: session2.id, title: "S2 Topic", summary: "In session 2.", segmentRange: 1...2))

        let topics1 = try await repo.topics(for: session1.id)
        let topics2 = try await repo.topics(for: session2.id)

        #expect(topics1.count == 1)
        #expect(topics1[0].title == "S1 Topic")
        #expect(topics2.count == 1)
        #expect(topics2[0].title == "S2 Topic")
    }

    @Test func emptyTopicsForNewSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let topics = try await repo.topics(for: session.id)

        #expect(topics.isEmpty)
    }
}
