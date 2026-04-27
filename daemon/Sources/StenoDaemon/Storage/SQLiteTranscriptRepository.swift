import Foundation
import GRDB

/// SQLite-backed implementation of TranscriptRepository using GRDB.
///
/// This actor provides thread-safe database operations for sessions,
/// segments, and summaries.
public actor SQLiteTranscriptRepository: TranscriptRepository {
    private let dbQueue: DatabaseQueue

    /// Create a repository with the specified database queue.
    ///
    /// - Parameter dbQueue: A configured and migrated DatabaseQueue.
    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Sessions

    public func createSession(locale: Locale) async throws -> Session {
        let session = Session(
            id: UUID(),
            locale: locale,
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active
        )

        try await dbQueue.write { db in
            try SessionRecord.from(session).insert(db)
        }

        return session
    }

    public func recoverOrphansAndOpenFresh(locale: Locale) async throws -> Session {
        // Atomic sweep + insert in a single GRDB write transaction.
        //
        // The UPDATE runs FIRST, BEFORE the INSERT. SQLite executes the
        // statements in this block in submission order, so the UPDATE
        // matches only the pre-existing 'active' rows; the new row
        // (inserted afterwards) is not visible to the WHERE clause.
        //
        // GRDB's `dbQueue.write` serializes against all other writers, so
        // no concurrent willSleep handler (or any other writer) can observe
        // the half-state where the orphans are interrupted but the new
        // session has not yet been inserted.
        let session = Session(
            id: UUID(),
            locale: locale,
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: nil,
            pausedIndefinitely: false
        )

        try await dbQueue.write { db in
            // Sweep: orphan close uses MAX(segments.endedAt) per the plan,
            // falling back to the orphan's startedAt for zero-segment rows.
            try db.execute(sql: """
                UPDATE sessions
                SET status = ?,
                    endedAt = COALESCE(
                        (SELECT MAX(endedAt) FROM segments WHERE sessionId = sessions.id),
                        startedAt
                    )
                WHERE status = ?
            """, arguments: [
                Session.Status.interrupted.rawValue,
                Session.Status.active.rawValue
            ])

            // Insert the new active session.
            try SessionRecord.from(session).insert(db)
        }

        return session
    }

    public func sweepActiveOrphans() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE sessions
                SET status = ?,
                    endedAt = COALESCE(
                        (SELECT MAX(endedAt) FROM segments WHERE sessionId = sessions.id),
                        startedAt
                    )
                WHERE status = ?
            """, arguments: [
                Session.Status.interrupted.rawValue,
                Session.Status.active.rawValue
            ])
        }
    }

    public func openFreshSession(locale: Locale) async throws -> Session {
        let session = Session(
            id: UUID(),
            locale: locale,
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: nil,
            pausedIndefinitely: false
        )
        try await dbQueue.write { db in
            try SessionRecord.from(session).insert(db)
        }
        return session
    }

    /// Read the most-recently-modified session (by `endedAt` if present,
    /// else `startedAt`). Used by U4's pause-state-restore check on
    /// daemon-start: a paused session may have been the last write before
    /// the daemon was killed, and we must not surprise-resume into recording.
    public func mostRecentlyModifiedSession() async throws -> Session? {
        try await dbQueue.read { db in
            try SessionRecord
                .fetchAll(
                    db,
                    sql: """
                        SELECT * FROM sessions
                        ORDER BY COALESCE(endedAt, startedAt) DESC
                        LIMIT 1
                    """
                )
                .first?
                .toDomain()
        }
    }

    public func endSession(_ sessionId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET endedAt = ?, status = ?
                    WHERE id = ?
                """,
                arguments: [
                    Date().timeIntervalSince1970,
                    Session.Status.completed.rawValue,
                    sessionId.uuidString
                ]
            )
        }
    }

    public func session(_ id: UUID) async throws -> Session? {
        try await dbQueue.read { db in
            try SessionRecord
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)?
                .toDomain()
        }
    }

    public func allSessions() async throws -> [Session] {
        try await dbQueue.read { db in
            try SessionRecord
                .order(Column("startedAt").desc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func deleteSession(_ id: UUID) async throws {
        _ = try await dbQueue.write { db in
            try SessionRecord
                .filter(Column("id") == id.uuidString)
                .deleteAll(db)
        }
    }

    // MARK: - Segments

    public func saveSegment(_ segment: StoredSegment) async throws {
        try await dbQueue.write { db in
            try SegmentRecord.from(segment).insert(db)
        }
    }

    public func segments(for sessionId: UUID) async throws -> [StoredSegment] {
        try await dbQueue.read { db in
            try SegmentRecord
                .filter(Column("sessionId") == sessionId.uuidString)
                .order(Column("startedAt").asc, Column("sequenceNumber").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func segments(from: Date, to: Date) async throws -> [StoredSegment] {
        try await dbQueue.read { db in
            try SegmentRecord
                .filter(Column("startedAt") >= from.timeIntervalSince1970)
                .filter(Column("startedAt") <= to.timeIntervalSince1970)
                .order(Column("startedAt").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func segmentCount(for sessionId: UUID) async throws -> Int {
        try await dbQueue.read { db in
            try SegmentRecord
                .filter(Column("sessionId") == sessionId.uuidString)
                .fetchCount(db)
        }
    }

    public func maxSegmentSequence(for sessionId: UUID) async throws -> Int {
        try await dbQueue.read { db in
            // SELECT MAX(sequenceNumber) returns NULL for an empty
            // segment set; coalesce to 0 so callers can use
            // `current = max + 1` without an empty-case branch.
            let value = try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(MAX(sequenceNumber), 0)
                    FROM segments
                    WHERE sessionId = ?
                """,
                arguments: [sessionId.uuidString]
            )
            return value ?? 0
        }
    }

    // MARK: - Dedup (U11)

    public func segmentsAfterDedupCursor(
        sessionId: UUID,
        source: AudioSourceType
    ) async throws -> [StoredSegment] {
        try await dbQueue.read { db in
            // Read the session's cursor inside the same read so a concurrent
            // `advanceDedupCursor` write can't race past us mid-iteration.
            let cursor = try Int.fetchOne(
                db,
                sql: "SELECT last_deduped_segment_seq FROM sessions WHERE id = ?",
                arguments: [sessionId.uuidString]
            ) ?? 0

            return try SegmentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM segments
                    WHERE sessionId = ?
                      AND source = ?
                      AND sequenceNumber > ?
                      AND duplicate_of IS NULL
                    ORDER BY sequenceNumber ASC
                """,
                arguments: [sessionId.uuidString, source.rawValue, cursor]
            ).compactMap { $0.toDomain() }
        }
    }

    public func overlappingSegments(
        sessionId: UUID,
        source: AudioSourceType,
        from: Date,
        to: Date
    ) async throws -> [StoredSegment] {
        try await dbQueue.read { db in
            try SegmentRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM segments
                    WHERE sessionId = ?
                      AND source = ?
                      AND startedAt >= ?
                      AND startedAt <= ?
                    ORDER BY startedAt ASC
                """,
                arguments: [
                    sessionId.uuidString,
                    source.rawValue,
                    from.timeIntervalSince1970,
                    to.timeIntervalSince1970
                ]
            ).compactMap { $0.toDomain() }
        }
    }

    public func markDuplicate(
        micSegmentId: UUID,
        sysSegmentId: UUID,
        method: DedupMethod
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE segments
                    SET duplicate_of = ?, dedup_method = ?
                    WHERE id = ?
                """,
                arguments: [
                    sysSegmentId.uuidString,
                    method.rawValue,
                    micSegmentId.uuidString
                ]
            )
        }
    }

    public func advanceDedupCursor(sessionId: UUID, toSequence: Int) async throws {
        try await dbQueue.write { db in
            // GREATEST-style guard: never let the cursor move backwards.
            // SQLite's `MAX(a, b)` scalar function gives us this in-line so
            // a concurrent pass that already advanced past `toSequence`
            // doesn't get rolled back.
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET last_deduped_segment_seq = MAX(last_deduped_segment_seq, ?)
                    WHERE id = ?
                """,
                arguments: [toSequence, sessionId.uuidString]
            )
        }
    }

    // MARK: - Summaries

    public func saveSummary(_ summary: Summary) async throws {
        try await dbQueue.write { db in
            try SummaryRecord.from(summary).insert(db)
        }
    }

    public func summaries(for sessionId: UUID) async throws -> [Summary] {
        try await dbQueue.read { db in
            try SummaryRecord
                .filter(Column("sessionId") == sessionId.uuidString)
                .order(Column("createdAt").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    public func latestSummary(for sessionId: UUID) async throws -> Summary? {
        try await dbQueue.read { db in
            try SummaryRecord
                .filter(Column("sessionId") == sessionId.uuidString)
                .order(Column("createdAt").desc)
                .fetchOne(db)?
                .toDomain()
        }
    }

    // MARK: - Topics

    public func saveTopic(_ topic: Topic) async throws {
        try await dbQueue.write { db in
            try TopicRecord.from(topic).insert(db)
        }
    }

    public func topics(for sessionId: UUID) async throws -> [Topic] {
        try await dbQueue.read { db in
            try TopicRecord
                .filter(Column("sessionId") == sessionId.uuidString)
                .order(Column("segmentRangeStart").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }
}
