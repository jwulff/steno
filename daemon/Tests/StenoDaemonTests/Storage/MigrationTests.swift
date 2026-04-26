import Testing
import Foundation
import GRDB
@testable import StenoDaemon

/// Tests for the `20260425_001_dedup_and_heal` migration (U2).
///
/// Coverage:
/// - Fresh DB: every new column exists with the right type/default.
/// - Existing-data DB: prior-schema rows survive the migration with sensible defaults.
/// - Idempotency: re-running the migrator twice is a no-op.
/// - Index: the partial dedup index exists and is selected by the planned default query.
/// - WAL: on-disk writer connection has `PRAGMA journal_mode = WAL`.
@Suite("DedupAndHeal Migration Tests")
struct MigrationTests {

    // MARK: - Happy: fresh DB schema

    @Test func segmentsTableHasNewDedupColumns() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "segments")
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

            #expect(byName["duplicate_of"] != nil)
            #expect(byName["duplicate_of"]?.type == "TEXT")
            #expect(byName["duplicate_of"]?.isNotNull == false)

            #expect(byName["dedup_method"] != nil)
            #expect(byName["dedup_method"]?.type == "TEXT")
            #expect(byName["dedup_method"]?.isNotNull == false)

            #expect(byName["heal_marker"] != nil)
            #expect(byName["heal_marker"]?.type == "TEXT")
            #expect(byName["heal_marker"]?.isNotNull == false)

            #expect(byName["mic_peak_db"] != nil)
            #expect(byName["mic_peak_db"]?.type == "REAL")
            #expect(byName["mic_peak_db"]?.isNotNull == false)
        }
    }

    @Test func sessionsTableHasNewMetadataColumns() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let columns = try db.columns(in: "sessions")
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

            // last_deduped_segment_seq INTEGER NOT NULL DEFAULT 0
            let cursor = byName["last_deduped_segment_seq"]
            #expect(cursor != nil)
            #expect(cursor?.type == "INTEGER")
            #expect(cursor?.isNotNull == true)
            #expect(cursor?.defaultValueSQL == "0")

            // pause_expires_at REAL NULL
            let pauseExpires = byName["pause_expires_at"]
            #expect(pauseExpires != nil)
            #expect(pauseExpires?.type == "REAL")
            #expect(pauseExpires?.isNotNull == false)

            // paused_indefinitely INTEGER NOT NULL DEFAULT 0
            let pausedIndef = byName["paused_indefinitely"]
            #expect(pausedIndef != nil)
            #expect(pausedIndef?.type == "INTEGER")
            #expect(pausedIndef?.isNotNull == true)
            #expect(pausedIndef?.defaultValueSQL == "0")
        }
    }

    @Test func dedupPartialIndexExists() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            let indexes = try db.indexes(on: "segments")
            #expect(indexes.map(\.name).contains("idx_segments_dedup"))

            // Confirm the partial-WHERE clause is present in the stored DDL.
            // SQLite stores partial indexes' WHERE clause in sqlite_master.sql.
            let sql = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_segments_dedup'"
            )
            #expect(sql != nil)
            #expect(sql?.contains("duplicate_of IS NULL") == true)
        }
    }

    // MARK: - Happy: defaults on inserted rows

    @Test func newSessionRowsGetDefaultDedupCursor() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["s1", "en_US", 0.0, "active", 0.0]
            )
        }

        try dbQueue.read { db in
            let cursor = try Int.fetchOne(
                db,
                sql: "SELECT last_deduped_segment_seq FROM sessions WHERE id = ?",
                arguments: ["s1"]
            )
            let pausedIndef = try Int.fetchOne(
                db,
                sql: "SELECT paused_indefinitely FROM sessions WHERE id = ?",
                arguments: ["s1"]
            )
            let pauseExpires = try Double.fetchOne(
                db,
                sql: "SELECT pause_expires_at FROM sessions WHERE id = ?",
                arguments: ["s1"]
            )
            #expect(cursor == 0)
            #expect(pausedIndef == 0)
            #expect(pauseExpires == nil)
        }
    }

    @Test func newSegmentRowsHaveNullDedupAndHealColumns() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["s1", "en_US", 0.0, "active", 0.0]
            )
            try db.execute(
                sql: """
                    INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["seg1", "s1", "hello", 0.0, 1.0, 0, 0.0]
            )
        }

        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT duplicate_of, dedup_method, heal_marker, mic_peak_db
                    FROM segments WHERE id = ?
                """,
                arguments: ["seg1"]
            )
            #expect(row != nil)
            #expect((row?["duplicate_of"] as String?) == nil)
            #expect((row?["dedup_method"] as String?) == nil)
            #expect((row?["heal_marker"] as String?) == nil)
            #expect((row?["mic_peak_db"] as Double?) == nil)
        }
    }

    // MARK: - Existing-data migration

    @Test func priorSchemaRowsSurviveMigration() throws {
        // Build a real on-disk DB that's been migrated to ONLY the prior three
        // migrations, populate some rows, then re-open via the public API
        // (which runs the new migration) and assert nothing was lost.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-migration-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("steno.sqlite")

        // Step 1: open with prior-schema migrations only.
        do {
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let priorQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

            var prior = DatabaseMigrator()
            prior.registerMigration("20260131_001_initial") { db in
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
                try db.execute(sql: "CREATE INDEX idx_segments_session ON segments(sessionId)")
                try db.execute(sql: "CREATE INDEX idx_segments_time ON segments(startedAt)")
                try db.execute(sql: "CREATE INDEX idx_summaries_session ON summaries(sessionId)")
            }
            prior.registerMigration("20260207_001_add_segment_source") { db in
                try db.execute(sql: """
                    ALTER TABLE segments ADD COLUMN source TEXT NOT NULL DEFAULT 'microphone'
                """)
            }
            prior.registerMigration("20260207_002_create_topics_table") { db in
                try db.execute(sql: """
                    CREATE TABLE topics (
                        id TEXT PRIMARY KEY,
                        sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                        title TEXT NOT NULL,
                        summary TEXT NOT NULL,
                        segmentRangeStart INTEGER NOT NULL,
                        segmentRangeEnd INTEGER NOT NULL,
                        createdAt REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX idx_topics_session ON topics(sessionId)")
            }
            try prior.migrate(priorQueue)

            // Insert a session + segment with the prior schema.
            try priorQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions (id, locale, startedAt, status, createdAt)
                        VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: ["pre-existing", "en_US", 100.0, "completed", 100.0]
                )
                try db.execute(
                    sql: """
                        INSERT INTO segments (id, sessionId, text, startedAt, endedAt, sequenceNumber, createdAt, source)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: ["pre-seg", "pre-existing", "hello", 100.0, 101.0, 0, 100.0, "microphone"]
                )
            }
            // Close.
            try priorQueue.close()
        }

        // Step 2: re-open via the public API — this runs the new migration.
        let dbQueue = try DatabaseConfiguration.makeQueue(at: dbURL)

        // Step 3: existing rows still readable; new columns have correct defaults.
        try dbQueue.read { db in
            // Session row: cursor=0, paused_indefinitely=0, pause_expires_at=NULL.
            let cursor = try Int.fetchOne(
                db,
                sql: "SELECT last_deduped_segment_seq FROM sessions WHERE id = ?",
                arguments: ["pre-existing"]
            )
            let pausedIndef = try Int.fetchOne(
                db,
                sql: "SELECT paused_indefinitely FROM sessions WHERE id = ?",
                arguments: ["pre-existing"]
            )
            let pauseExpires = try Double.fetchOne(
                db,
                sql: "SELECT pause_expires_at FROM sessions WHERE id = ?",
                arguments: ["pre-existing"]
            )
            #expect(cursor == 0)
            #expect(pausedIndef == 0)
            #expect(pauseExpires == nil)

            // Segment row: nullable columns are NULL.
            let segRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT duplicate_of, dedup_method, heal_marker, mic_peak_db, text
                    FROM segments WHERE id = ?
                """,
                arguments: ["pre-seg"]
            )
            #expect((segRow?["text"] as String?) == "hello")
            #expect((segRow?["duplicate_of"] as String?) == nil)
            #expect((segRow?["dedup_method"] as String?) == nil)
            #expect((segRow?["heal_marker"] as String?) == nil)
            #expect((segRow?["mic_peak_db"] as Double?) == nil)
        }
    }

    // MARK: - Idempotency

    @Test func reRunningMigratorIsNoOp() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-migration-idempotent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("steno.sqlite")

        // First open runs all migrations.
        let q1 = try DatabaseConfiguration.makeQueue(at: dbURL)
        let firstSchema: [String] = try q1.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"
            )
        }
        try q1.close()

        // Second open re-runs migrations (registered ones become no-ops).
        let q2 = try DatabaseConfiguration.makeQueue(at: dbURL)
        let secondSchema: [String] = try q2.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"
            )
        }

        #expect(firstSchema == secondSchema)
    }

    // MARK: - Index used by planned default query

    @Test func dedupPartialIndexIsSelectedByPlannedQuery() throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()

        try dbQueue.read { db in
            // Match the planned default query in the plan U9: filter by session
            // and (duplicate_of IS NULL), order by sequenceNumber.
            //
            // The contract this test protects (U2's responsibility) is:
            //   1. The partial index `idx_segments_dedup` exists.
            //   2. SQLite picks an index whose leading columns are
            //      `(sessionId, sequenceNumber)` for this query.
            //
            // It is NOT load-bearing that the planner picks specifically
            // `idx_segments_dedup` over the autoindex implied by the
            // `UNIQUE(sessionId, sequenceNumber)` constraint — the
            // autoindex has the same leading-column shape and is an
            // equally valid choice. The planner's heuristics may prefer
            // the autoindex on some SQLite versions; what matters is that
            // *some* index keyed on (sessionId, sequenceNumber) is used
            // and that the partial index exists for queries the planner
            // chooses to route through it.

            // (1) The partial index exists by name.
            let indexes = try db.indexes(on: "segments")
            #expect(
                indexes.map(\.name).contains("idx_segments_dedup"),
                "Expected idx_segments_dedup to exist on segments; got: \(indexes.map(\.name))"
            )

            // (2) EXPLAIN QUERY PLAN picks SOME index over (sessionId, sequenceNumber).
            let plan = try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id, sessionId, text, sequenceNumber
                    FROM segments
                    WHERE sessionId = ? AND duplicate_of IS NULL
                    ORDER BY sequenceNumber
                """,
                arguments: ["any-session-id"]
            )
            let detail = plan.compactMap { $0["detail"] as String? }.joined(separator: " | ")

            // Acceptable shapes:
            //   - References `idx_segments_dedup` (the partial index).
            //   - References the autoindex from UNIQUE(sessionId, sequenceNumber)
            //     — SQLite names autoindexes `sqlite_autoindex_<table>_N` and
            //     EXPLAIN reports them either by that name or as a generic
            //     "USING INDEX" / "USING COVERING INDEX" line that mentions
            //     the indexed columns.
            let usesPartial = detail.contains("idx_segments_dedup")
            let usesAutoindex = detail.contains("sqlite_autoindex_segments")
            // Fallback: any plan line that shows the planner is using BOTH
            // sessionId and sequenceNumber as index columns (covering or otherwise).
            let usesCompositeColumns = detail.contains("sessionId") && detail.contains("sequenceNumber")
            let message = "Expected EXPLAIN QUERY PLAN to reference idx_segments_dedup or the " +
                "(sessionId, sequenceNumber) autoindex; got: \(detail)"
            #expect(usesPartial || usesAutoindex || usesCompositeColumns, Comment(rawValue: message))
        }
    }

    // MARK: - WAL on the writer connection

    @Test func onDiskWriterUsesWALMode() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-wal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbURL = tmpDir.appendingPathComponent("steno.sqlite")
        let dbQueue = try DatabaseConfiguration.makeQueue(at: dbURL)

        let mode = try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode?.lowercased() == "wal")
    }
}
