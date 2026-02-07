import Foundation
import GRDB

/// Configuration and migration management for the Steno database.
public enum DatabaseConfiguration {
    /// Create a configured DatabaseQueue for Steno at the specified URL.
    ///
    /// - Parameter url: The file URL for the database.
    /// - Returns: A configured and migrated DatabaseQueue.
    /// - Throws: If directory creation, database opening, or migration fails.
    public static func makeQueue(at url: URL) throws -> DatabaseQueue {
        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    /// Create an in-memory database for testing.
    ///
    /// - Returns: A configured and migrated in-memory DatabaseQueue.
    /// - Throws: If database opening or migration fails.
    public static func makeInMemoryQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let dbQueue = try DatabaseQueue(configuration: config)
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    /// Default database URL in Application Support directory.
    public static var defaultURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Steno", isDirectory: true)
            .appendingPathComponent("steno.sqlite")
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // SAFETY: Never use eraseDatabaseOnSchemaChange - it destroys data silently

        migrator.registerMigration("20260131_001_initial") { db in
            // sessions table
            try db.execute(sql: """
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    locale TEXT NOT NULL,
                    startedAt REAL NOT NULL,
                    endedAt REAL,
                    title TEXT,
                    status TEXT NOT NULL DEFAULT 'active',
                    createdAt REAL NOT NULL
                )
            """)

            // segments table with constraints
            try db.execute(sql: """
                CREATE TABLE segments (
                    id TEXT PRIMARY KEY,
                    sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    text TEXT NOT NULL CHECK(length(text) > 0 AND length(text) <= 10000),
                    startedAt REAL NOT NULL,
                    endedAt REAL NOT NULL,
                    confidence REAL CHECK(confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
                    sequenceNumber INTEGER NOT NULL,
                    createdAt REAL NOT NULL,
                    UNIQUE(sessionId, sequenceNumber)
                )
            """)

            // summaries table
            try db.execute(sql: """
                CREATE TABLE summaries (
                    id TEXT PRIMARY KEY,
                    sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                    content TEXT NOT NULL,
                    summaryType TEXT NOT NULL DEFAULT 'rolling',
                    segmentRangeStart INTEGER NOT NULL,
                    segmentRangeEnd INTEGER NOT NULL,
                    modelId TEXT NOT NULL,
                    createdAt REAL NOT NULL
                )
            """)

            // Indexes for common queries
            try db.execute(sql: "CREATE INDEX idx_segments_session ON segments(sessionId)")
            try db.execute(sql: "CREATE INDEX idx_segments_time ON segments(startedAt)")
            try db.execute(sql: "CREATE INDEX idx_summaries_session ON summaries(sessionId)")
        }

        migrator.registerMigration("20260207_001_add_segment_source") { db in
            try db.execute(sql: """
                ALTER TABLE segments ADD COLUMN source TEXT NOT NULL DEFAULT 'microphone'
            """)
        }

        return migrator
    }
}
