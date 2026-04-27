import Foundation
@testable import StenoDaemon

/// In-memory mock implementation of TranscriptRepository for testing.
actor MockTranscriptRepository: TranscriptRepository {
    /// Test-only error used by the throw-injection helpers.
    struct InjectedError: Error, Equatable {
        let message: String
        init(_ message: String = "injected") { self.message = message }
    }

    private var sessions: [UUID: Session] = [:]
    private var segments: [UUID: [StoredSegment]] = [:]
    private var summaries: [UUID: [Summary]] = [:]
    private var topics: [UUID: [Topic]] = [:]

    // MARK: - Failure-injection knobs (test-only)
    //
    // U4 / U10 fail-safe assertions need to verify behavior when the
    // repository surfaces a real error. Each knob, when set, causes the
    // matching method to throw `InjectedError` instead of running its
    // normal logic. Defaults are nil, so unset tests behave as before.

    private var mostRecentlyModifiedSessionError: Error?
    private var sweepActiveOrphansError: Error?
    private var recoverOrphansAndOpenFreshError: Error?
    private var openFreshSessionError: Error?

    func setMostRecentlyModifiedSessionError(_ error: Error?) {
        mostRecentlyModifiedSessionError = error
    }
    func setSweepActiveOrphansError(_ error: Error?) {
        sweepActiveOrphansError = error
    }
    func setRecoverOrphansAndOpenFreshError(_ error: Error?) {
        recoverOrphansAndOpenFreshError = error
    }
    func setOpenFreshSessionError(_ error: Error?) {
        openFreshSessionError = error
    }

    // MARK: - Sessions

    func createSession(locale: Locale) async throws -> Session {
        let session = Session(
            id: UUID(),
            locale: locale,
            startedAt: Date(),
            endedAt: nil,
            title: nil,
            status: .active
        )
        sessions[session.id] = session
        segments[session.id] = []
        summaries[session.id] = []
        return session
    }

    func sweepActiveOrphans() async throws {
        if let error = sweepActiveOrphansError { throw error }
        for (id, var session) in sessions where session.status == .active {
            let segs = segments[id] ?? []
            let endedAt = segs.map(\.endedAt).max() ?? session.startedAt
            session.status = .interrupted
            session.endedAt = endedAt
            sessions[id] = session
        }
    }

    func recoverOrphansAndOpenFresh(locale: Locale) async throws -> Session {
        if let error = recoverOrphansAndOpenFreshError { throw error }
        // Simulate the single-transaction sweep + insert.
        // 1. Mark every active session as interrupted with endedAt computed
        //    from MAX(segments.endedAt) or fallback to startedAt.
        let now = Date()
        for (id, var session) in sessions where session.status == .active {
            let segs = segments[id] ?? []
            let endedAt = segs.map(\.endedAt).max() ?? session.startedAt
            session.status = .interrupted
            session.endedAt = endedAt
            sessions[id] = session
        }
        // 2. Open a fresh active session (NOT subject to the prior sweep).
        let fresh = Session(
            id: UUID(),
            locale: locale,
            startedAt: now,
            endedAt: nil,
            title: nil,
            status: .active,
            lastDedupedSegmentSeq: 0,
            pauseExpiresAt: nil,
            pausedIndefinitely: false
        )
        sessions[fresh.id] = fresh
        segments[fresh.id] = []
        summaries[fresh.id] = []
        return fresh
    }

    func openFreshSession(locale: Locale) async throws -> Session {
        if let error = openFreshSessionError { throw error }
        let fresh = Session(
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
        sessions[fresh.id] = fresh
        segments[fresh.id] = []
        summaries[fresh.id] = []
        return fresh
    }

    func endSession(_ sessionId: UUID) async throws {
        guard var session = sessions[sessionId] else { return }
        session = Session(
            id: session.id,
            locale: session.locale,
            startedAt: session.startedAt,
            endedAt: Date(),
            title: session.title,
            status: .completed
        )
        sessions[sessionId] = session
    }

    func session(_ id: UUID) async throws -> Session? {
        sessions[id]
    }

    func allSessions() async throws -> [Session] {
        sessions.values.sorted { $0.startedAt > $1.startedAt }
    }

    func mostRecentlyModifiedSession() async throws -> Session? {
        if let error = mostRecentlyModifiedSessionError { throw error }
        // ORDER BY COALESCE(endedAt, startedAt) DESC.
        return sessions.values.sorted { lhs, rhs in
            let lk = lhs.endedAt ?? lhs.startedAt
            let rk = rhs.endedAt ?? rhs.startedAt
            return lk > rk
        }.first
    }

    func deleteSession(_ id: UUID) async throws {
        sessions.removeValue(forKey: id)
        segments.removeValue(forKey: id)
        summaries.removeValue(forKey: id)
        topics.removeValue(forKey: id)
    }

    // MARK: - Segments

    func saveSegment(_ segment: StoredSegment) async throws {
        segments[segment.sessionId, default: []].append(segment)
    }

    func segments(for sessionId: UUID) async throws -> [StoredSegment] {
        (segments[sessionId] ?? []).sorted {
            if $0.startedAt == $1.startedAt {
                return $0.sequenceNumber < $1.sequenceNumber
            }
            return $0.startedAt < $1.startedAt
        }
    }

    func segments(from: Date, to: Date) async throws -> [StoredSegment] {
        segments.values.flatMap { $0 }
            .filter { $0.startedAt >= from && $0.startedAt <= to }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func segmentCount(for sessionId: UUID) async throws -> Int {
        segments[sessionId]?.count ?? 0
    }

    func maxSegmentSequence(for sessionId: UUID) async throws -> Int {
        // Mirror the SQLite contract: 0 when the session has no
        // segments, otherwise the max `sequenceNumber` value.
        segments[sessionId]?.map(\.sequenceNumber).max() ?? 0
    }

    // MARK: - Summaries

    func saveSummary(_ summary: Summary) async throws {
        summaries[summary.sessionId, default: []].append(summary)
    }

    func summaries(for sessionId: UUID) async throws -> [Summary] {
        (summaries[sessionId] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func latestSummary(for sessionId: UUID) async throws -> Summary? {
        summaries[sessionId]?.max { $0.createdAt < $1.createdAt }
    }

    // MARK: - Topics

    func saveTopic(_ topic: Topic) async throws {
        topics[topic.sessionId, default: []].append(topic)
    }

    func topics(for sessionId: UUID) async throws -> [Topic] {
        (topics[sessionId] ?? []).sorted { $0.segmentRange.lowerBound < $1.segmentRange.lowerBound }
    }

    // MARK: - Test Helpers

    /// Seed a session row directly. Used by U4 tests that need to simulate
    /// pre-existing orphan/paused rows without going through `createSession`.
    func seed(_ session: Session) {
        sessions[session.id] = session
        if segments[session.id] == nil { segments[session.id] = [] }
        if summaries[session.id] == nil { summaries[session.id] = [] }
    }
}
