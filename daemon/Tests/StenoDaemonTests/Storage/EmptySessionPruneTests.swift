import Testing
import Foundation
import GRDB
@testable import StenoDaemon

/// Tests for U12's `SQLiteTranscriptRepository.maybeDeleteIfEmpty(...)` and
/// `applyRetentionPolicy(...)`.
///
/// These exercise the empty-session prune logic and the 90-day retention
/// guard at the repository layer (no engine wiring). Engine-integration
/// scenarios live in `Engine/EmptySessionPruneIntegrationTests.swift`.
@Suite("Empty-Session Prune (U12)")
struct EmptySessionPruneTests {

    // MARK: - Helpers

    /// Insert a closed session row directly so we can simulate every
    /// closed status (interrupted/completed). Uses the same SQL shape as
    /// `OrphanSweepTests` for consistency.
    private func insertClosedSession(
        in dbQueue: DatabaseQueue,
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        status: Session.Status = .completed
    ) async throws -> UUID {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, locale, startedAt, endedAt, title, status, createdAt,
                        last_deduped_segment_seq, pause_expires_at, paused_indefinitely
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    "en_US",
                    startedAt.timeIntervalSince1970,
                    endedAt.timeIntervalSince1970,
                    nil,
                    status.rawValue,
                    Date().timeIntervalSince1970,
                    0,
                    nil,
                    0
                ]
            )
        }
        return id
    }

    /// Insert an active session (no endedAt). Used to verify the pruner
    /// refuses to operate on still-recording rows.
    private func insertActiveSession(
        in dbQueue: DatabaseQueue,
        startedAt: Date = Date()
    ) async throws -> UUID {
        let id = UUID()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, locale, startedAt, endedAt, title, status, createdAt,
                        last_deduped_segment_seq, pause_expires_at, paused_indefinitely
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    "en_US",
                    startedAt.timeIntervalSince1970,
                    nil,
                    nil,
                    Session.Status.active.rawValue,
                    Date().timeIntervalSince1970,
                    0,
                    nil,
                    0
                ]
            )
        }
        return id
    }

    private func insertSegment(
        in dbQueue: DatabaseQueue,
        sessionId: UUID,
        text: String,
        startedAt: Date,
        endedAt: Date,
        sequenceNumber: Int,
        duplicateOf: UUID? = nil,
        dedupMethod: DedupMethod? = nil,
        source: AudioSourceType = .microphone
    ) async throws -> UUID {
        let id = UUID()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments (
                        id, sessionId, text, startedAt, endedAt, confidence,
                        sequenceNumber, createdAt, source,
                        duplicate_of, dedup_method, heal_marker, mic_peak_db
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    sessionId.uuidString,
                    text,
                    startedAt.timeIntervalSince1970,
                    endedAt.timeIntervalSince1970,
                    0.9,
                    sequenceNumber,
                    Date().timeIntervalSince1970,
                    source.rawValue,
                    duplicateOf?.uuidString,
                    dedupMethod?.rawValue,
                    nil,
                    nil
                ]
            )
        }
        return id
    }

    // MARK: - Happy paths

    @Test("Happy: zero-segment session is deleted")
    func zeroSegmentSessionDeleted() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let started = Date().addingTimeInterval(-30)
        let ended = Date()
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == true)

        let after = try await repo.session(id)
        #expect(after == nil)
    }

    @Test("Happy: 5 segments totaling 15 chars non-dup → deleted (chars trip)")
    func tooFewCharactersDeleted() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let started = Date().addingTimeInterval(-30)
        let ended = Date()
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )
        // 5 segments × 3 chars = 15 chars total
        for i in 0..<5 {
            _ = try await insertSegment(
                in: dbQueue,
                sessionId: id,
                text: "abc",
                startedAt: started.addingTimeInterval(Double(i)),
                endedAt: started.addingTimeInterval(Double(i) + 0.5),
                sequenceNumber: i + 1
            )
        }

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == true)
        #expect(try await repo.session(id) == nil)
    }

    @Test("Happy: 1 segment 50 chars over 10s duration → kept")
    func meaningfulSessionKept() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let started = Date().addingTimeInterval(-10)
        let ended = Date()
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )
        _ = try await insertSegment(
            in: dbQueue,
            sessionId: id,
            text: String(repeating: "a", count: 50),
            startedAt: started,
            endedAt: started.addingTimeInterval(2),
            sequenceNumber: 1
        )

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == false)
        #expect(try await repo.session(id) != nil)
    }

    // MARK: - Edge cases

    @Test("Edge: 1 segment 50 chars but 2s duration → deleted (duration trips)")
    func tooShortDurationDeleted() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let started = Date().addingTimeInterval(-2)
        let ended = Date()  // 2 seconds duration
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )
        _ = try await insertSegment(
            in: dbQueue,
            sessionId: id,
            text: String(repeating: "a", count: 50),
            startedAt: started,
            endedAt: started.addingTimeInterval(1),
            sequenceNumber: 1
        )

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == true)
        #expect(try await repo.session(id) == nil)
    }

    @Test("Edge: all 5 segments marked duplicate_of → non-dup text = 0, deleted")
    func allDuplicatesDeletedAsEmpty() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let started = Date().addingTimeInterval(-30)
        let ended = Date()
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )

        // Insert one canonical sys segment, then 5 mic segments all
        // pointing back to it via duplicate_of. The non-duplicate query
        // counts only duplicate_of IS NULL rows, so the canonical sys
        // segment counts as 1.
        let canonical = try await insertSegment(
            in: dbQueue,
            sessionId: id,
            text: "canonical text here exceeds 20 chars threshold easily",
            startedAt: started.addingTimeInterval(1),
            endedAt: started.addingTimeInterval(2),
            sequenceNumber: 1,
            source: .systemAudio
        )
        // To exercise "all marked as duplicate_of" — replace the canonical
        // with a self-referencing setup: we create one canonical + several
        // duplicates of it; the "all marked" framing in the plan refers
        // to the mic segments. To get exactly "non-dup text = 0" we need
        // EVERY remaining segment to be a duplicate. Easiest: reset and
        // insert duplicates only.
        try await repo.deleteSession(id)
        let id2 = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )
        // We need a placeholder canonical to FK-point at, but it must be
        // outside this session so the prune query doesn't count it. Use
        // another session as the "kept" target.
        let otherStarted = started.addingTimeInterval(-3600)
        let otherId = try await insertClosedSession(
            in: dbQueue, startedAt: otherStarted, endedAt: otherStarted.addingTimeInterval(60)
        )
        let otherCanonical = try await insertSegment(
            in: dbQueue,
            sessionId: otherId,
            text: "kept canonical, very long text exceeding the threshold",
            startedAt: otherStarted,
            endedAt: otherStarted.addingTimeInterval(1),
            sequenceNumber: 1,
            source: .systemAudio
        )
        for i in 0..<5 {
            _ = try await insertSegment(
                in: dbQueue,
                sessionId: id2,
                text: "long text content well above 20 chars per segment",
                startedAt: started.addingTimeInterval(Double(i)),
                endedAt: started.addingTimeInterval(Double(i) + 0.5),
                sequenceNumber: i + 1,
                duplicateOf: otherCanonical,
                dedupMethod: .fuzzy
            )
        }
        // Sanity: a referenced var to keep `canonical` from being unused
        _ = canonical

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id2, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == true)
        #expect(try await repo.session(id2) == nil)
        // Other session is not touched
        #expect(try await repo.session(otherId) != nil)
    }

    @Test("Edge: exactly 3.0s duration → kept (boundary < 3.0)")
    func exactBoundaryDurationKept() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        // Exactly 3.0s duration with enough text to satisfy the chars
        // threshold. Only the duration boundary matters.
        let started = Date().addingTimeInterval(-3)
        let ended = started.addingTimeInterval(3.0)
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )
        _ = try await insertSegment(
            in: dbQueue,
            sessionId: id,
            text: String(repeating: "a", count: 50),
            startedAt: started,
            endedAt: started.addingTimeInterval(1),
            sequenceNumber: 1
        )

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == false)
        #expect(try await repo.session(id) != nil)
    }

    @Test("Edge: active session → pruner refuses, returns false")
    func activeSessionRefused() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let id = try await insertActiveSession(in: dbQueue)

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == false)
        #expect(try await repo.session(id) != nil)
    }

    @Test("Edge: status non-active but endedAt IS NULL → refused")
    func nullEndedAtRefused() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        // Insert a session with status = interrupted but no endedAt —
        // pathological state we still defensively refuse to prune.
        let id = UUID()
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO sessions (
                        id, locale, startedAt, endedAt, title, status, createdAt,
                        last_deduped_segment_seq, pause_expires_at, paused_indefinitely
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    "en_US",
                    Date().addingTimeInterval(-30).timeIntervalSince1970,
                    nil,  // endedAt IS NULL
                    nil,
                    Session.Status.interrupted.rawValue,
                    Date().timeIntervalSince1970,
                    0,
                    nil,
                    0
                ]
            )
        }

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == false)
        #expect(try await repo.session(id) != nil)
    }

    @Test("Cascade verified: prune deletes segments + topics + summaries")
    func cascadeVerified() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let started = Date().addingTimeInterval(-30)
        let ended = Date()
        let id = try await insertClosedSession(
            in: dbQueue, startedAt: started, endedAt: ended
        )
        // Empty-session: zero segments, but seed a topic + summary so we
        // can verify cascade.
        let topic = Topic(
            id: UUID(),
            sessionId: id,
            title: "T",
            summary: "S",
            segmentRange: 1...1,
            createdAt: Date()
        )
        try await repo.saveTopic(topic)
        let summary = Summary(
            id: UUID(),
            sessionId: id,
            content: "X",
            summaryType: .rolling,
            segmentRangeStart: 1,
            segmentRangeEnd: 1,
            modelId: "test",
            createdAt: Date()
        )
        try await repo.saveSummary(summary)

        let deleted = try await repo.maybeDeleteIfEmpty(
            sessionId: id, minChars: 20, minDurationSeconds: 3.0
        )
        #expect(deleted == true)
        #expect(try await repo.session(id) == nil)
        #expect(try await repo.topics(for: id).isEmpty)
        #expect(try await repo.summaries(for: id).isEmpty)
    }

    // MARK: - Retention policy

    @Test("Retention: sessions older than N days are cascade-deleted")
    func retentionDeletesOldSessions() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let now = Date()
        let oldStarted = now.addingTimeInterval(-100 * 86_400)  // 100 days ago
        let oldEnded = oldStarted.addingTimeInterval(60)
        let recentStarted = now.addingTimeInterval(-30 * 86_400)  // 30 days ago
        let recentEnded = recentStarted.addingTimeInterval(60)

        let oldId = try await insertClosedSession(
            in: dbQueue, startedAt: oldStarted, endedAt: oldEnded
        )
        let recentId = try await insertClosedSession(
            in: dbQueue, startedAt: recentStarted, endedAt: recentEnded
        )

        // Add a segment + topic to the old session so we can verify cascade.
        _ = try await insertSegment(
            in: dbQueue,
            sessionId: oldId,
            text: "old segment text long enough to count",
            startedAt: oldStarted,
            endedAt: oldStarted.addingTimeInterval(1),
            sequenceNumber: 1
        )
        try await repo.saveTopic(Topic(
            id: UUID(),
            sessionId: oldId,
            title: "old",
            summary: "old",
            segmentRange: 1...1,
            createdAt: Date()
        ))

        let deletedCount = try await repo.applyRetentionPolicy(retentionDays: 90)
        #expect(deletedCount == 1)
        #expect(try await repo.session(oldId) == nil)
        #expect(try await repo.session(recentId) != nil)
        #expect(try await repo.topics(for: oldId).isEmpty)
        #expect(try await repo.segments(for: oldId).isEmpty)
    }

    @Test("Retention: active sessions (endedAt IS NULL) are never deleted")
    func retentionLeavesActiveSessions() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        // Insert an "active" session that started 100 days ago — no
        // endedAt, so retention should leave it alone (only completed
        // sessions get pruned).
        let activeId = try await insertActiveSession(
            in: dbQueue, startedAt: Date().addingTimeInterval(-100 * 86_400)
        )

        let deletedCount = try await repo.applyRetentionPolicy(retentionDays: 90)
        #expect(deletedCount == 0)
        #expect(try await repo.session(activeId) != nil)
    }

    @Test("Retention: zero retention days disables sweep")
    func retentionZeroDisables() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let oldId = try await insertClosedSession(
            in: dbQueue,
            startedAt: Date().addingTimeInterval(-100 * 86_400),
            endedAt: Date().addingTimeInterval(-100 * 86_400 + 60)
        )

        let deletedCount = try await repo.applyRetentionPolicy(retentionDays: 0)
        #expect(deletedCount == 0)
        #expect(try await repo.session(oldId) != nil)
    }

    // MARK: - Defensive topic / summary writes

    @Test("Defensive: saveTopic against deleted session is a no-op")
    func saveTopicNoOpsOnDeletedSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let id = UUID()  // Session that does not exist in the DB.
        let topic = Topic(
            id: UUID(),
            sessionId: id,
            title: "T",
            summary: "S",
            segmentRange: 1...1,
            createdAt: Date()
        )
        // Must not throw — the defensive pre-check returns silently.
        try await repo.saveTopic(topic)

        let topics = try await repo.topics(for: id)
        #expect(topics.isEmpty)
    }

    @Test("Defensive: saveSummary against deleted session is a no-op")
    func saveSummaryNoOpsOnDeletedSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let id = UUID()
        let summary = Summary(
            id: UUID(),
            sessionId: id,
            content: "S",
            summaryType: .rolling,
            segmentRangeStart: 1,
            segmentRangeEnd: 1,
            modelId: "test",
            createdAt: Date()
        )
        try await repo.saveSummary(summary)
        #expect(try await repo.summaries(for: id).isEmpty)
    }
}
