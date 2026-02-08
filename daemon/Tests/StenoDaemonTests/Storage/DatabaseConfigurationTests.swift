import Testing
import Foundation
import GRDB
@testable import StenoDaemon

@Suite("DatabaseConfiguration Tests")
struct DatabaseConfigurationTests {

    @Test func inMemoryDatabaseCreation() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        // Verify tables exist by querying them
        try dbQueue.read { db in
            let sessionCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions")
            #expect(sessionCount == 0)

            let segmentCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments")
            #expect(segmentCount == 0)

            let summaryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM summaries")
            #expect(summaryCount == 0)
        }
    }

    @Test func foreignKeysEnabled() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let fkEnabled = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
            #expect(fkEnabled == 1)
        }
    }

    @Test func sessionsTableSchema() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "sessions")
            let columnNames = columns.map(\.name)

            #expect(columnNames.contains("id"))
            #expect(columnNames.contains("locale"))
            #expect(columnNames.contains("startedAt"))
            #expect(columnNames.contains("endedAt"))
            #expect(columnNames.contains("title"))
            #expect(columnNames.contains("status"))
            #expect(columnNames.contains("createdAt"))
        }
    }

    @Test func segmentsTableSchema() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "segments")
            let columnNames = columns.map(\.name)

            #expect(columnNames.contains("id"))
            #expect(columnNames.contains("sessionId"))
            #expect(columnNames.contains("text"))
            #expect(columnNames.contains("startedAt"))
            #expect(columnNames.contains("endedAt"))
            #expect(columnNames.contains("confidence"))
            #expect(columnNames.contains("sequenceNumber"))
            #expect(columnNames.contains("createdAt"))
        }
    }

    @Test func summariesTableSchema() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "summaries")
            let columnNames = columns.map(\.name)

            #expect(columnNames.contains("id"))
            #expect(columnNames.contains("sessionId"))
            #expect(columnNames.contains("content"))
            #expect(columnNames.contains("summaryType"))
            #expect(columnNames.contains("segmentRangeStart"))
            #expect(columnNames.contains("segmentRangeEnd"))
            #expect(columnNames.contains("modelId"))
            #expect(columnNames.contains("createdAt"))
        }
    }

    @Test func segmentsIndexExists() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let indexes = try db.indexes(on: "segments")
            let indexNames = indexes.map(\.name)

            #expect(indexNames.contains("idx_segments_session"))
            #expect(indexNames.contains("idx_segments_time"))
        }
    }

    @Test func summariesIndexExists() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let indexes = try db.indexes(on: "summaries")
            let indexNames = indexes.map(\.name)

            #expect(indexNames.contains("idx_summaries_session"))
        }
    }

    @Test func defaultURLInApplicationSupport() {
        let url = DatabaseConfiguration.defaultURL

        #expect(url.pathComponents.contains("Application Support"))
        #expect(url.pathComponents.contains("Steno"))
        #expect(url.lastPathComponent == "steno.sqlite")
    }

    @Test func cascadeDeleteSegments() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        // Insert a session
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["test-session", "en_US", Date().timeIntervalSince1970, "active", Date().timeIntervalSince1970]
            )
        }

        // Insert a segment referencing that session
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["test-segment", "test-session", "hello", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 0, Date().timeIntervalSince1970]
            )
        }

        // Delete the session
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: ["test-session"])
        }

        // Verify segment was cascade deleted
        try dbQueue.read { db in
            let segmentCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments WHERE id = ?", arguments: ["test-segment"])
            #expect(segmentCount == 0)
        }
    }

    @Test func uniqueSessionSequenceConstraint() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        // Insert a session
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["test-session", "en_US", Date().timeIntervalSince1970, "active", Date().timeIntervalSince1970]
            )
        }

        // Insert first segment
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["segment-1", "test-session", "hello", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 0, Date().timeIntervalSince1970]
            )
        }

        // Try to insert duplicate sequence number - should fail
        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["segment-2", "test-session", "world", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 0, Date().timeIntervalSince1970]
                )
            }
        }
    }

    @Test func textLengthConstraint() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        // Insert a session
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["test-session", "en_US", Date().timeIntervalSince1970, "active", Date().timeIntervalSince1970]
            )
        }

        // Empty text should fail
        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["segment-1", "test-session", "", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 0, Date().timeIntervalSince1970]
                )
            }
        }
    }

    @Test func segmentsTableHasSourceColumn() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "segments")
            let columnNames = columns.map(\.name)

            #expect(columnNames.contains("source"))
        }
    }

    @Test func sourceDefaultsToMicrophone() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        // Insert a session
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["test-session", "en_US", Date().timeIntervalSince1970, "active", Date().timeIntervalSince1970]
            )
        }

        // Insert a segment WITHOUT specifying source
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["test-segment", "test-session", "hello", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 0, Date().timeIntervalSince1970]
            )
        }

        // Verify source defaults to 'microphone'
        try dbQueue.read { db in
            let source = try String.fetchOne(db, sql: "SELECT source FROM segments WHERE id = ?", arguments: ["test-segment"])
            #expect(source == "microphone")
        }
    }

    @Test func sourceAcceptsSystemAudio() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["test-session", "en_US", Date().timeIntervalSince1970, "active", Date().timeIntervalSince1970]
            )
        }

        // Insert a segment with systemAudio source
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["test-segment", "test-session", "hello", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 0, Date().timeIntervalSince1970, "systemAudio"]
            )
        }

        try dbQueue.read { db in
            let source = try String.fetchOne(db, sql: "SELECT source FROM segments WHERE id = ?", arguments: ["test-segment"])
            #expect(source == "systemAudio")
        }
    }

    @Test func confidenceRangeConstraint() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        // Insert a session
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["test-session", "en_US", Date().timeIntervalSince1970, "active", Date().timeIntervalSince1970]
            )
        }

        // Confidence > 1 should fail
        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO segments (id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["segment-1", "test-session", "hello", Date().timeIntervalSince1970, Date().timeIntervalSince1970, 1.5, 0, Date().timeIntervalSince1970]
                )
            }
        }

        // Confidence < 0 should fail
        #expect(throws: (any Error).self) {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO segments (id, sessionId, text, startedAt, endedAt, confidence, sequenceNumber, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["segment-2", "test-session", "world", Date().timeIntervalSince1970, Date().timeIntervalSince1970, -0.1, 1, Date().timeIntervalSince1970]
                )
            }
        }
    }
}
