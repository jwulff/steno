import Testing
import Foundation
@testable import StenoDaemon

@Suite("MarkdownExport Tests")
struct MarkdownExportTests {

    @Test func exportsBasicTranscript() {
        let session = Session(
            id: UUID(),
            locale: Locale(identifier: "en_US"),
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 120),
            title: "Test Session",
            status: .completed
        )

        let segments = [
            StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "Hello world",
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 2),
                confidence: nil,
                sequenceNumber: 1,
                createdAt: Date()
            ),
            StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "Goodbye world",
                startedAt: Date(timeIntervalSince1970: 60),
                endedAt: Date(timeIntervalSince1970: 62),
                confidence: nil,
                sequenceNumber: 2,
                createdAt: Date()
            )
        ]

        let markdown = MarkdownExport.export(
            session: session,
            segments: segments,
            summaries: []
        )

        #expect(markdown.contains("# Test Session"))
        #expect(markdown.contains("**[00:00]** Hello world"))
        #expect(markdown.contains("**[01:00]** Goodbye world"))
        #expect(markdown.contains("**Duration:** 2:00"))
    }

    @Test func includesSummaryWhenPresent() {
        let session = Session(
            id: UUID(),
            locale: Locale(identifier: "en_US"),
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active
        )

        let summary = Summary(
            id: UUID(),
            sessionId: session.id,
            content: "This is a summary",
            summaryType: .rolling,
            segmentRangeStart: 1,
            segmentRangeEnd: 10,
            modelId: "test",
            createdAt: Date()
        )

        let markdown = MarkdownExport.export(
            session: session,
            segments: [],
            summaries: [summary]
        )

        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("This is a summary"))
    }

    @Test func usesDefaultTitleWhenNone() {
        let session = Session(
            id: UUID(),
            locale: Locale(identifier: "en_US"),
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active
        )

        let markdown = MarkdownExport.export(
            session: session,
            segments: [],
            summaries: []
        )

        #expect(markdown.contains("# Transcript"))
    }

    @Test func omitsDurationWhenSessionNotEnded() {
        let session = Session(
            id: UUID(),
            locale: Locale(identifier: "en_US"),
            startedAt: Date(),
            endedAt: nil,
            title: "Ongoing",
            status: .active
        )

        let markdown = MarkdownExport.export(
            session: session,
            segments: [],
            summaries: []
        )

        #expect(!markdown.contains("**Duration:**"))
    }

    @Test func usesLatestSummaryOnly() {
        let session = Session(
            id: UUID(),
            locale: Locale(identifier: "en_US"),
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active
        )

        let summaries = [
            Summary(
                id: UUID(),
                sessionId: session.id,
                content: "First summary",
                summaryType: .rolling,
                segmentRangeStart: 1,
                segmentRangeEnd: 5,
                modelId: "test",
                createdAt: Date()
            ),
            Summary(
                id: UUID(),
                sessionId: session.id,
                content: "Second summary - the latest",
                summaryType: .rolling,
                segmentRangeStart: 6,
                segmentRangeEnd: 10,
                modelId: "test",
                createdAt: Date().addingTimeInterval(60)
            )
        ]

        let markdown = MarkdownExport.export(
            session: session,
            segments: [],
            summaries: summaries
        )

        #expect(markdown.contains("Second summary - the latest"))
        #expect(!markdown.contains("First summary"))
    }

    @Test func formatsTimestampsRelativeToSessionStart() {
        let sessionStart = Date(timeIntervalSince1970: 1000)
        let session = Session(
            id: UUID(),
            locale: Locale(identifier: "en_US"),
            startedAt: sessionStart,
            endedAt: nil,
            title: nil,
            status: .active
        )

        let segments = [
            StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "At start",
                startedAt: sessionStart,
                endedAt: sessionStart.addingTimeInterval(2),
                confidence: nil,
                sequenceNumber: 1,
                createdAt: Date()
            ),
            StoredSegment(
                id: UUID(),
                sessionId: session.id,
                text: "After 5 minutes",
                startedAt: sessionStart.addingTimeInterval(300),
                endedAt: sessionStart.addingTimeInterval(302),
                confidence: nil,
                sequenceNumber: 2,
                createdAt: Date()
            )
        ]

        let markdown = MarkdownExport.export(
            session: session,
            segments: segments,
            summaries: []
        )

        #expect(markdown.contains("**[00:00]** At start"))
        #expect(markdown.contains("**[05:00]** After 5 minutes"))
    }
}
