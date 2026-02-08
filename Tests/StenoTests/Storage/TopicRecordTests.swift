import Testing
import Foundation
import GRDB
@testable import Steno

@Suite("TopicRecord Tests")
struct TopicRecordTests {

    private let testSessionId = UUID()

    @Test func toDomainRoundTrip() {
        let topic = Topic(
            sessionId: testSessionId,
            title: "Budget review",
            summary: "Q2 budget was approved by all stakeholders.",
            segmentRange: 3...7,
            createdAt: Date()
        )

        let record = TopicRecord.from(topic)
        let roundTripped = record.toDomain()

        #expect(roundTripped != nil)
        #expect(roundTripped?.id == topic.id)
        #expect(roundTripped?.sessionId == topic.sessionId)
        #expect(roundTripped?.title == topic.title)
        #expect(roundTripped?.summary == topic.summary)
        #expect(roundTripped?.segmentRange == topic.segmentRange)
    }

    @Test func fromDomainSetsAllFields() {
        let id = UUID()
        let now = Date()
        let topic = Topic(
            id: id,
            sessionId: testSessionId,
            title: "Hiring plan",
            summary: "Need 2 senior engineers by Q3.",
            segmentRange: 1...5,
            createdAt: now
        )

        let record = TopicRecord.from(topic)

        #expect(record.id == id.uuidString)
        #expect(record.sessionId == testSessionId.uuidString)
        #expect(record.title == "Hiring plan")
        #expect(record.summary == "Need 2 senior engineers by Q3.")
        #expect(record.segmentRangeStart == 1)
        #expect(record.segmentRangeEnd == 5)
        #expect(record.createdAt == now.timeIntervalSince1970)
    }

    @Test func toDomainReturnsNilForInvalidUUID() {
        let record = TopicRecord(
            id: "not-a-uuid",
            sessionId: testSessionId.uuidString,
            title: "Test",
            summary: "Test",
            segmentRangeStart: 1,
            segmentRangeEnd: 2,
            createdAt: Date().timeIntervalSince1970
        )

        #expect(record.toDomain() == nil)
    }

    @Test func toDomainReturnsNilForInvalidSessionUUID() {
        let record = TopicRecord(
            id: UUID().uuidString,
            sessionId: "not-a-uuid",
            title: "Test",
            summary: "Test",
            segmentRangeStart: 1,
            segmentRangeEnd: 2,
            createdAt: Date().timeIntervalSince1970
        )

        #expect(record.toDomain() == nil)
    }

    @Test func migrationCreatesTopicsTable() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "topics")
            let columnNames = columns.map(\.name)

            #expect(columnNames.contains("id"))
            #expect(columnNames.contains("sessionId"))
            #expect(columnNames.contains("title"))
            #expect(columnNames.contains("summary"))
            #expect(columnNames.contains("segmentRangeStart"))
            #expect(columnNames.contains("segmentRangeEnd"))
            #expect(columnNames.contains("createdAt"))
        }
    }

    @Test func topicsIndexExists() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let indexes = try db.indexes(on: "topics")
            let indexNames = indexes.map(\.name)

            #expect(indexNames.contains("idx_topics_session"))
        }
    }
}
