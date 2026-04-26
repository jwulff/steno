import Testing
import Foundation
import GRDB
@testable import StenoDaemon

/// Tests for U4's `recoverOrphansAndOpenFresh` repository method.
///
/// These tests exercise the orphan-sweep + new-session-insert atomic
/// transaction directly against the SQLite repository — they are storage-
/// layer tests, not engine-layer tests, but they live in `Engine/` because
/// they belong to the U4 unit alongside the auto-start tests.
@Suite("Orphan Sweep Tests")
struct OrphanSweepTests {

    // MARK: - Helpers

    /// Insert a session row directly via SQL so the test can simulate
    /// pre-existing rows of any status.
    private func insertSession(
        in dbQueue: DatabaseQueue,
        id: UUID = UUID(),
        startedAt: Date = Date().addingTimeInterval(-3600),
        endedAt: Date? = nil,
        status: Session.Status = .active,
        pausedIndefinitely: Bool = false,
        pauseExpiresAt: Date? = nil
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
                    endedAt?.timeIntervalSince1970,
                    nil,
                    status.rawValue,
                    Date().timeIntervalSince1970,
                    0,
                    pauseExpiresAt?.timeIntervalSince1970,
                    pausedIndefinitely ? 1 : 0
                ]
            )
        }
        return id
    }

    /// Insert a segment row directly.
    private func insertSegment(
        in dbQueue: DatabaseQueue,
        sessionId: UUID,
        startedAt: Date,
        endedAt: Date,
        sequenceNumber: Int
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segments (
                        id, sessionId, text, startedAt, endedAt, confidence,
                        sequenceNumber, createdAt, source
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    sessionId.uuidString,
                    "test segment text",
                    startedAt.timeIntervalSince1970,
                    endedAt.timeIntervalSince1970,
                    0.9,
                    sequenceNumber,
                    Date().timeIntervalSince1970,
                    AudioSourceType.microphone.rawValue
                ]
            )
        }
    }

    /// Read a session row by id (uses the repository's domain-level method).
    private func readSession(_ id: UUID, in repo: SQLiteTranscriptRepository) async throws -> Session? {
        try await repo.session(id)
    }

    // MARK: - Test scenarios

    @Test("Happy: no prior sessions opens a fresh active session")
    func freshDatabaseOpensActiveSession() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let session = try await repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        #expect(session.status == .active)
        #expect(session.endedAt == nil)
        #expect(session.title == nil)
        #expect(session.lastDedupedSegmentSeq == 0)
        #expect(session.pauseExpiresAt == nil)
        #expect(session.pausedIndefinitely == false)
        #expect(session.locale.identifier == "en_US")

        // The new session is in the DB and is the only active session.
        let all = try await repo.allSessions()
        #expect(all.count == 1)
        #expect(all[0].id == session.id)
        #expect(all[0].status == .active)
    }

    @Test("Happy: stranded active session with N segments becomes interrupted with endedAt = MAX(segments.endedAt)")
    func strandedSessionWithSegmentsClosesAtLastSegment() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let orphanId = try await insertSession(
            in: dbQueue,
            startedAt: Date().addingTimeInterval(-3600)
        )

        // Insert 3 segments. The latest endedAt should be the second one.
        let earliest = Date().addingTimeInterval(-3500)
        let middle = Date().addingTimeInterval(-3400)
        let lastEnded = Date().addingTimeInterval(-3300)
        try await insertSegment(in: dbQueue, sessionId: orphanId,
                                 startedAt: earliest, endedAt: earliest.addingTimeInterval(5),
                                 sequenceNumber: 1)
        try await insertSegment(in: dbQueue, sessionId: orphanId,
                                 startedAt: middle, endedAt: lastEnded,
                                 sequenceNumber: 2)
        try await insertSegment(in: dbQueue, sessionId: orphanId,
                                 startedAt: middle.addingTimeInterval(-30), endedAt: middle.addingTimeInterval(10),
                                 sequenceNumber: 3)
        // MAX(endedAt) = lastEnded among the three.

        let fresh = try await repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        // Orphan is now interrupted with endedAt = MAX segment endedAt.
        let orphan = try await readSession(orphanId, in: repo)
        #expect(orphan?.status == .interrupted)
        #expect(orphan?.endedAt != nil)
        if let endedAt = orphan?.endedAt {
            #expect(abs(endedAt.timeIntervalSince1970 - lastEnded.timeIntervalSince1970) < 0.01)
        }

        // Fresh session is active and distinct.
        #expect(fresh.id != orphanId)
        #expect(fresh.status == .active)
        let freshFromDb = try await readSession(fresh.id, in: repo)
        #expect(freshFromDb?.status == .active)
    }

    @Test("Edge: stranded active session with zero segments becomes interrupted with endedAt = startedAt")
    func strandedSessionWithZeroSegmentsClosesAtStartedAt() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let startedAt = Date().addingTimeInterval(-3600)
        let orphanId = try await insertSession(in: dbQueue, startedAt: startedAt)

        _ = try await repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        let orphan = try await readSession(orphanId, in: repo)
        #expect(orphan?.status == .interrupted)
        #expect(orphan?.endedAt != nil)
        if let endedAt = orphan?.endedAt {
            #expect(abs(endedAt.timeIntervalSince1970 - startedAt.timeIntervalSince1970) < 0.01)
        }
    }

    @Test("Edge: multiple stranded active sessions are all marked interrupted")
    func multipleStrandedSessionsAllInterrupted() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let id1 = try await insertSession(in: dbQueue, startedAt: Date().addingTimeInterval(-7200))
        let id2 = try await insertSession(in: dbQueue, startedAt: Date().addingTimeInterval(-3600))
        let id3 = try await insertSession(in: dbQueue, startedAt: Date().addingTimeInterval(-1800))

        let fresh = try await repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        for orphanId in [id1, id2, id3] {
            let s = try await readSession(orphanId, in: repo)
            #expect(s?.status == .interrupted)
        }

        // Fresh is the only active session.
        let all = try await repo.allSessions()
        let activeCount = all.filter { $0.status == .active }.count
        #expect(activeCount == 1)
        #expect(all.first { $0.status == .active }?.id == fresh.id)
    }

    @Test("Edge: completed sessions are not touched by the sweep")
    func completedSessionsNotAffected() async throws {
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let completedId = try await insertSession(
            in: dbQueue,
            startedAt: Date().addingTimeInterval(-7200),
            endedAt: Date().addingTimeInterval(-7000),
            status: .completed
        )
        let activeId = try await insertSession(
            in: dbQueue,
            startedAt: Date().addingTimeInterval(-3600)
        )

        _ = try await repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        let completed = try await readSession(completedId, in: repo)
        #expect(completed?.status == .completed)
        let active = try await readSession(activeId, in: repo)
        #expect(active?.status == .interrupted)
    }

    @Test("Race: UPDATE clause does not match the just-inserted new row")
    func sweepDoesNotInterruptJustInsertedSession() async throws {
        // The contract is that the sweep + insert happen in a single
        // transaction such that the UPDATE WHERE status='active' clause
        // sees the original `active` rows but NOT the freshly inserted
        // row. We assert this via the new session's final status.
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let orphanId = try await insertSession(in: dbQueue)

        let fresh = try await repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        // Critical invariant: the new session is still active after the call.
        // If the UPDATE matched the new row (e.g., due to ordering bug or
        // statement reordering), the new session would already be interrupted.
        let freshFromDb = try await readSession(fresh.id, in: repo)
        #expect(freshFromDb?.status == .active)
        #expect(freshFromDb?.endedAt == nil)

        // And the orphan is interrupted as expected.
        let orphan = try await readSession(orphanId, in: repo)
        #expect(orphan?.status == .interrupted)
    }

    @Test("Race: concurrent writers do not see the half-state between sweep and insert")
    func concurrentWritersDoNotObserveHalfState() async throws {
        // GRDB serializes writes through DatabaseQueue, so the
        // `dbQueue.write { ... }` block that wraps the orphan sweep + insert
        // is atomic from any other writer's perspective. We verify that
        // observation here: a concurrent writer scheduled at the same time
        // either sees the pre-state (orphan still active, no new session)
        // or the post-state (orphan interrupted, new active session present)
        // — never the half-state.
        let dbQueue = try DatabaseConfiguration.makeInMemoryQueue()
        let repo = SQLiteTranscriptRepository(dbQueue: dbQueue)

        let orphanId = try await insertSession(in: dbQueue)

        async let recover: Session = repo.recoverOrphansAndOpenFresh(
            locale: Locale(identifier: "en_US")
        )

        // Concurrent observer reads the state on the same queue. Because
        // dbQueue.write serializes, this either runs before or after the
        // recovery transaction, but never inside it.
        async let observation: (activeCount: Int, hasOrphan: Bool, hasFresh: Bool) = dbQueue.read { db in
            let activeCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sessions WHERE status = 'active'"
            ) ?? 0
            let hasOrphan = (try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ? AND status = 'interrupted')",
                arguments: [orphanId.uuidString]
            )) ?? false
            // Just count whether *any* active session exists with an id
            // different from the orphan.
            let hasFresh = (try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE status = 'active' AND id != ?)",
                arguments: [orphanId.uuidString]
            )) ?? false
            return (activeCount: activeCount, hasOrphan: hasOrphan, hasFresh: hasFresh)
        }

        _ = try await recover
        let snap = try await observation

        // Whatever ordering the scheduler picked, the DB invariant is:
        // exactly one active session at all times (from the observer's POV).
        // If the read happened before recovery: activeCount = 1 (orphan), hasOrphan = false, hasFresh = false.
        // If after: activeCount = 1 (fresh), hasOrphan = true, hasFresh = true.
        #expect(snap.activeCount == 1)
        // Half-state check: it is NEVER the case that orphan is interrupted
        // AND no fresh session exists; nor that orphan is still active AND
        // a fresh session also exists.
        let halfStateA = snap.hasOrphan && !snap.hasFresh    // sweep done, insert missing
        let halfStateB = !snap.hasOrphan && snap.hasFresh && snap.activeCount > 1
        #expect(halfStateA == false)
        #expect(halfStateB == false)
    }
}
