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

    @discardableResult
    func sweepActiveOrphans() async throws -> [UUID] {
        if let error = sweepActiveOrphansError { throw error }
        var sweptIds: [UUID] = []
        for (id, var session) in sessions where session.status == .active {
            let segs = segments[id] ?? []
            let endedAt = segs.map(\.endedAt).max() ?? session.startedAt
            session.status = .interrupted
            session.endedAt = endedAt
            sessions[id] = session
            sweptIds.append(id)
        }
        return sweptIds
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

    // MARK: - Dedup (U11)

    /// Optional throw-injection: when set, `markDuplicate` raises and the
    /// coordinator's cursor advance step is skipped. Used to test the
    /// failure-safe (cursor-not-bumped-on-throw) contract.
    private var markDuplicateError: Error?

    func setMarkDuplicateError(_ error: Error?) {
        markDuplicateError = error
    }

    func segmentsAfterDedupCursor(sessionId: UUID, source: AudioSourceType) async throws -> [StoredSegment] {
        guard let session = sessions[sessionId] else { return [] }
        let cursor = session.lastDedupedSegmentSeq
        let segs = segments[sessionId] ?? []
        return segs
            .filter { $0.source == source && $0.sequenceNumber > cursor && $0.duplicateOf == nil }
            .sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    func overlappingSegments(
        sessionId: UUID,
        source: AudioSourceType,
        from: Date,
        to: Date
    ) async throws -> [StoredSegment] {
        let segs = segments[sessionId] ?? []
        return segs
            .filter { $0.source == source && $0.startedAt >= from && $0.startedAt <= to }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func markDuplicate(
        micSegmentId: UUID,
        sysSegmentId: UUID,
        method: DedupMethod
    ) async throws {
        if let err = markDuplicateError { throw err }
        for (sid, segs) in segments {
            if let idx = segs.firstIndex(where: { $0.id == micSegmentId }) {
                let old = segs[idx]
                let updated = StoredSegment(
                    id: old.id,
                    sessionId: old.sessionId,
                    text: old.text,
                    startedAt: old.startedAt,
                    endedAt: old.endedAt,
                    confidence: old.confidence,
                    sequenceNumber: old.sequenceNumber,
                    createdAt: old.createdAt,
                    source: old.source,
                    healMarker: old.healMarker,
                    duplicateOf: sysSegmentId,
                    dedupMethod: method,
                    micPeakDb: old.micPeakDb
                )
                var copy = segs
                copy[idx] = updated
                segments[sid] = copy
                return
            }
        }
    }

    func advanceDedupCursor(sessionId: UUID, toSequence: Int) async throws {
        guard var session = sessions[sessionId] else { return }
        // GREATEST-style — never move backwards.
        if toSequence > session.lastDedupedSegmentSeq {
            session.lastDedupedSegmentSeq = toSequence
            sessions[sessionId] = session
        }
    }

    // MARK: - Summaries

    func saveSummary(_ summary: Summary) async throws {
        // Defensive write — match SQLite repo: only persist when parent
        // session still exists. Mirrors U12's pre-check pattern so tests
        // catching pruner-aware behavior see the same shape.
        guard sessions[summary.sessionId] != nil else { return }
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
        // Defensive write — match SQLite repo: only persist when parent
        // session still exists. The empty-session pruner may have deleted
        // the session between the LLM call's start and this insert.
        guard sessions[topic.sessionId] != nil else { return }
        topics[topic.sessionId, default: []].append(topic)
    }

    func topics(for sessionId: UUID) async throws -> [Topic] {
        (topics[sessionId] ?? []).sorted { $0.segmentRange.lowerBound < $1.segmentRange.lowerBound }
    }

    // MARK: - U12 Empty-Session Prune + Retention

    func maybeDeleteIfEmpty(
        sessionId: UUID,
        minChars: Int,
        minDurationSeconds: Double
    ) async throws -> Bool {
        guard let session = sessions[sessionId] else { return false }
        // Defensive: never prune an active session.
        if session.status == .active { return false }
        guard let endedAt = session.endedAt else { return false }

        let segs = segments[sessionId] ?? []
        let nonDup = segs.filter { $0.duplicateOf == nil }
        let nonDupCount = nonDup.count
        let nonDupChars = nonDup.reduce(0) { $0 + $1.text.count }
        let duration = endedAt.timeIntervalSince(session.startedAt)

        let trips = nonDupCount == 0
            || nonDupChars < minChars
            || duration < minDurationSeconds

        guard trips else { return false }

        sessions.removeValue(forKey: sessionId)
        segments.removeValue(forKey: sessionId)
        summaries.removeValue(forKey: sessionId)
        topics.removeValue(forKey: sessionId)
        return true
    }

    @discardableResult
    func applyRetentionPolicy(retentionDays: Int) async throws -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400.0)
        let toDelete = sessions.filter { _, s in
            guard let endedAt = s.endedAt else { return false }
            return endedAt < cutoff
        }.map(\.key)
        for id in toDelete {
            sessions.removeValue(forKey: id)
            segments.removeValue(forKey: id)
            summaries.removeValue(forKey: id)
            topics.removeValue(forKey: id)
        }
        return toDelete.count
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
