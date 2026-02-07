import Testing
import Foundation
import GRDB
@testable import Steno

@Suite("SQLiteTranscriptRepository Tests")
struct SQLiteTranscriptRepositoryTests {

    // MARK: - Session Tests

    @Test func createSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        #expect(session.locale.identifier == "en_US")
        #expect(session.status == .active)
        #expect(session.endedAt == nil)
        #expect(session.title == nil)
    }

    @Test func fetchCreatedSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let created = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let fetched = try await repo.session(created.id)

        #expect(fetched != nil)
        #expect(fetched?.id == created.id)
        #expect(fetched?.locale.identifier == "en_US")
    }

    @Test func sessionNotFound() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.session(UUID())

        #expect(session == nil)
    }

    @Test func endSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        try await repo.endSession(session.id)

        let ended = try await repo.session(session.id)

        #expect(ended?.status == .completed)
        #expect(ended?.endedAt != nil)
    }

    @Test func allSessionsOrderedByMostRecent() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session1 = try await repo.createSession(locale: Locale(identifier: "en_US"))
        // Small delay to ensure different timestamps
        try await Task.sleep(for: .milliseconds(10))
        let session2 = try await repo.createSession(locale: Locale(identifier: "fr_FR"))

        let all = try await repo.allSessions()

        #expect(all.count == 2)
        // Most recent first
        #expect(all[0].id == session2.id)
        #expect(all[1].id == session1.id)
    }

    @Test func deleteSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        try await repo.deleteSession(session.id)

        let deleted = try await repo.session(session.id)

        #expect(deleted == nil)
    }

    // MARK: - Segment Tests

    @Test func saveAndFetchSegment() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let segment = StoredSegment(
            id: UUID(),
            sessionId: session.id,
            text: "Hello world",
            startedAt: Date(),
            endedAt: Date(),
            confidence: 0.95,
            sequenceNumber: 0,
            createdAt: Date()
        )

        try await repo.saveSegment(segment)
        let segments = try await repo.segments(for: session.id)

        #expect(segments.count == 1)
        #expect(segments[0].text == "Hello world")
        #expect(segments[0].confidence == 0.95)
    }

    @Test func segmentsOrderedBySequenceNumber() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let now = Date()

        // Insert in reverse order
        for i in (0..<3).reversed() {
            let segment = StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: now,
                endedAt: now,
                confidence: nil,
                sequenceNumber: i,
                createdAt: now
            )
            try await repo.saveSegment(segment)
        }

        let segments = try await repo.segments(for: session.id)

        #expect(segments.count == 3)
        #expect(segments[0].sequenceNumber == 0)
        #expect(segments[1].sequenceNumber == 1)
        #expect(segments[2].sequenceNumber == 2)
    }

    @Test func segmentsByTimeRange() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let baseTime = Date()
        let times = [
            baseTime.addingTimeInterval(-3600), // 1 hour ago
            baseTime.addingTimeInterval(-1800), // 30 min ago
            baseTime,                            // now
        ]

        for (i, time) in times.enumerated() {
            let segment = StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: time,
                endedAt: time,
                confidence: nil,
                sequenceNumber: i,
                createdAt: baseTime
            )
            try await repo.saveSegment(segment)
        }

        // Query for segments in last 45 minutes
        let from = baseTime.addingTimeInterval(-2700)
        let to = baseTime.addingTimeInterval(60)
        let segments = try await repo.segments(from: from, to: to)

        #expect(segments.count == 2)
    }

    @Test func segmentCount() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let now = Date()

        for i in 0..<5 {
            let segment = StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "Segment \(i)",
                startedAt: now,
                endedAt: now,
                confidence: nil,
                sequenceNumber: i,
                createdAt: now
            )
            try await repo.saveSegment(segment)
        }

        let count = try await repo.segmentCount(for: session.id)

        #expect(count == 5)
    }

    @Test func deleteSessionCascadesToSegments() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let now = Date()

        let segment = StoredSegment(
            id: UUID(),
            sessionId: session.id,
            text: "Hello",
            startedAt: now,
            endedAt: now,
            confidence: nil,
            sequenceNumber: 0,
            createdAt: now
        )
        try await repo.saveSegment(segment)

        try await repo.deleteSession(session.id)

        let count = try await repo.segmentCount(for: session.id)
        #expect(count == 0)
    }

    @Test func saveAndFetchSegmentWithSource() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let segment = StoredSegment(
            id: UUID(),
            sessionId: session.id,
            text: "Hello from system",
            startedAt: Date(),
            endedAt: Date(),
            confidence: 0.90,
            sequenceNumber: 0,
            createdAt: Date(),
            source: .systemAudio
        )

        try await repo.saveSegment(segment)
        let segments = try await repo.segments(for: session.id)

        #expect(segments.count == 1)
        #expect(segments[0].source == .systemAudio)
    }

    @Test func segmentSourceDefaultsToMicrophone() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let segment = StoredSegment(
            id: UUID(),
            sessionId: session.id,
            text: "Hello",
            startedAt: Date(),
            endedAt: Date(),
            confidence: nil,
            sequenceNumber: 0,
            createdAt: Date()
        )

        try await repo.saveSegment(segment)
        let segments = try await repo.segments(for: session.id)

        #expect(segments.count == 1)
        #expect(segments[0].source == .microphone)
    }

    // MARK: - Summary Tests

    @Test func saveAndFetchSummary() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let summary = Summary(
            id: UUID(),
            sessionId: session.id,
            content: "This is a summary",
            summaryType: .rolling,
            segmentRangeStart: 0,
            segmentRangeEnd: 10,
            modelId: "com.apple.foundationmodels",
            createdAt: Date()
        )

        try await repo.saveSummary(summary)
        let summaries = try await repo.summaries(for: session.id)

        #expect(summaries.count == 1)
        #expect(summaries[0].content == "This is a summary")
        #expect(summaries[0].summaryType == .rolling)
    }

    @Test func summariesOrderedByCreationTime() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let baseTime = Date()

        for i in 0..<3 {
            let summary = Summary(
                id: UUID(),
                sessionId: session.id,
                content: "Summary \(i)",
                summaryType: .rolling,
                segmentRangeStart: i * 10,
                segmentRangeEnd: (i + 1) * 10,
                modelId: "test",
                createdAt: baseTime.addingTimeInterval(Double(i) * 60)
            )
            try await repo.saveSummary(summary)
        }

        let summaries = try await repo.summaries(for: session.id)

        #expect(summaries.count == 3)
        #expect(summaries[0].content == "Summary 0")
        #expect(summaries[2].content == "Summary 2")
    }

    @Test func latestSummary() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let baseTime = Date()

        for i in 0..<3 {
            let summary = Summary(
                id: UUID(),
                sessionId: session.id,
                content: "Summary \(i)",
                summaryType: .rolling,
                segmentRangeStart: i * 10,
                segmentRangeEnd: (i + 1) * 10,
                modelId: "test",
                createdAt: baseTime.addingTimeInterval(Double(i) * 60)
            )
            try await repo.saveSummary(summary)
        }

        let latest = try await repo.latestSummary(for: session.id)

        #expect(latest != nil)
        #expect(latest?.content == "Summary 2")
    }

    @Test func latestSummaryWhenNoneExist() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let latest = try await repo.latestSummary(for: session.id)

        #expect(latest == nil)
    }

    @Test func deleteSessionCascadesToSummaries() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))

        let summary = Summary(
            id: UUID(),
            sessionId: session.id,
            content: "Summary",
            summaryType: .final,
            segmentRangeStart: 0,
            segmentRangeEnd: 10,
            modelId: "test",
            createdAt: Date()
        )
        try await repo.saveSummary(summary)

        try await repo.deleteSession(session.id)

        let summaries = try await repo.summaries(for: session.id)
        #expect(summaries.isEmpty)
    }
}
