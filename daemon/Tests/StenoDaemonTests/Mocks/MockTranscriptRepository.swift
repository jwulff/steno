import Foundation
@testable import StenoDaemon

/// In-memory mock implementation of TranscriptRepository for testing.
actor MockTranscriptRepository: TranscriptRepository {
    private var sessions: [UUID: Session] = [:]
    private var segments: [UUID: [StoredSegment]] = [:]
    private var summaries: [UUID: [Summary]] = [:]
    private var topics: [UUID: [Topic]] = [:]

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
        (segments[sessionId] ?? []).sorted { $0.sequenceNumber < $1.sequenceNumber }
    }

    func segments(from: Date, to: Date) async throws -> [StoredSegment] {
        segments.values.flatMap { $0 }
            .filter { $0.startedAt >= from && $0.startedAt <= to }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func segmentCount(for sessionId: UUID) async throws -> Int {
        segments[sessionId]?.count ?? 0
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
}
