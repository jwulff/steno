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

    @discardableResult
    public func sweepActiveOrphans() async throws -> [UUID] {
        try await dbQueue.write { db in
            // Snapshot the active-session IDs BEFORE the UPDATE so we can
            // return them to the caller. Emitted in a single transaction
            // alongside the UPDATE so a concurrent writer can't race a
            // session into `active` between the SELECT and the UPDATE.
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM sessions WHERE status = ?",
                arguments: [Session.Status.active.rawValue]
            )

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

            return ids.compactMap { UUID(uuidString: $0) }
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

    /// Defensive write — pre-checks parent-session existence inside the
    /// same write transaction (U12). The `RollingSummaryCoordinator` may
    /// be mid-LLM-call (45s timeout) when the empty-session pruner deletes
    /// a session; without the guard, the FK cascade would have already
    /// orphaned this insert, and SQLite would raise a CONSTRAINT_FOREIGNKEY
    /// error. The guard is the explicit-pre-check variant rather than
    /// "swallow the FK error" so any OTHER constraint failure still
    /// propagates as a genuine bug.
    public func saveSummary(_ summary: Summary) async throws {
        try await dbQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
                arguments: [summary.sessionId.uuidString]
            ) ?? false
            guard exists else { return }
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

    /// Defensive write — pre-checks parent-session existence inside the
    /// same write transaction (U12). Same shape as `saveSummary` above:
    /// the empty-session pruner may have deleted the session between the
    /// LLM call's start and this insert. Pre-check is explicit so a
    /// genuine constraint violation still propagates.
    public func saveTopic(_ topic: Topic) async throws {
        try await dbQueue.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
                arguments: [topic.sessionId.uuidString]
            ) ?? false
            guard exists else { return }
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

    // MARK: - U12 Empty-Session Prune + Retention

    public func maybeDeleteIfEmpty(
        sessionId: UUID,
        minChars: Int,
        minDurationSeconds: Double
    ) async throws -> Bool {
        try await dbQueue.write { db in
            // Single-transaction read-decide-delete. Any concurrent writer
            // is serialized by GRDB's DatabaseQueue, so the counts and
            // duration we read are the same the DELETE acts on.
            struct Probe: FetchableRecord {
                let status: String
                let startedAt: Double
                let endedAt: Double?
                let nonDupCount: Int
                let nonDupChars: Int

                init(row: Row) {
                    self.status = row["status"]
                    self.startedAt = row["startedAt"]
                    self.endedAt = row["endedAt"]
                    self.nonDupCount = row["non_dup_count"]
                    self.nonDupChars = row["non_dup_chars"]
                }
            }

            guard let probe = try Probe.fetchOne(
                db,
                sql: """
                    SELECT
                        s.status,
                        s.startedAt,
                        s.endedAt,
                        (SELECT COUNT(*) FROM segments
                         WHERE sessionId = s.id AND duplicate_of IS NULL)
                            AS non_dup_count,
                        (SELECT COALESCE(SUM(LENGTH(text)), 0) FROM segments
                         WHERE sessionId = s.id AND duplicate_of IS NULL)
                            AS non_dup_chars
                    FROM sessions s
                    WHERE s.id = ?
                """,
                arguments: [sessionId.uuidString]
            ) else {
                // Session not found — nothing to prune.
                return false
            }

            // Defensive: do NOT prune an active session, ever. Caller bug.
            if probe.status == Session.Status.active.rawValue {
                return false
            }
            guard let endedAt = probe.endedAt else {
                // status is non-active but endedAt is NULL — pathological;
                // refuse to prune to avoid masking the inconsistency.
                return false
            }

            let duration = endedAt - probe.startedAt
            let trips = probe.nonDupCount == 0
                || probe.nonDupChars < minChars
                || duration < minDurationSeconds

            guard trips else { return false }

            // Cascade-delete via FK. Verify by re-counting segments.
            try db.execute(
                sql: "DELETE FROM sessions WHERE id = ?",
                arguments: [sessionId.uuidString]
            )

            // Defensive cascade verification — if FK cascade silently
            // failed (e.g. PRAGMA foreign_keys was off), the segments
            // would be orphaned. Treat as a hard error since the caller
            // expects a clean delete.
            let leftoverSegs = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM segments WHERE sessionId = ?",
                arguments: [sessionId.uuidString]
            ) ?? 0
            if leftoverSegs > 0 {
                throw DatabaseError(
                    message: "FK cascade failed: \(leftoverSegs) segments orphaned for session \(sessionId)"
                )
            }
            return true
        }
    }

    @discardableResult
    public func applyRetentionPolicy(retentionDays: Int) async throws -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Date().timeIntervalSince1970 - Double(retentionDays) * 86_400.0
        return try await dbQueue.write { db in
            // SELECT first so we can return the count of deleted rows.
            // FK cascade handles segments/summaries/topics.
            let ids = try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM sessions
                    WHERE endedAt IS NOT NULL AND endedAt < ?
                """,
                arguments: [cutoff]
            )
            guard !ids.isEmpty else { return 0 }
            try db.execute(
                sql: """
                    DELETE FROM sessions
                    WHERE endedAt IS NOT NULL AND endedAt < ?
                """,
                arguments: [cutoff]
            )
            return ids.count
        }
    }
}
