import Foundation
import GRDB

/// GRDB record type for the sessions table.
struct SessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sessions"

    var id: String
    var locale: String
    var startedAt: Double
    var endedAt: Double?
    var title: String?
    var status: String
    var createdAt: Double

    /// Cursor advanced by `DedupCoordinator` (U11). The mic-segment seq up to
    /// which dedup has evaluated this session. Defaults to 0 for fresh rows;
    /// the migration backfills `0` for existing sessions.
    var lastDedupedSegmentSeq: Int = 0

    /// Wall-clock UNIX time at which a timed pause expires. NULL when the
    /// session is not paused, or when the pause is indefinite (see
    /// `pausedIndefinitely`). Survives daemon restart so `pause` outlives
    /// crashes/sleep.
    var pauseExpiresAt: Double?

    /// `1` when pause has no auto-resume (privacy-critical disambiguator —
    /// see U10's daemon-start rule). `0` means either not paused, or paused
    /// with auto-resume governed by `pauseExpiresAt`.
    var pausedIndefinitely: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, locale, startedAt, endedAt, title, status, createdAt
        case lastDedupedSegmentSeq = "last_deduped_segment_seq"
        case pauseExpiresAt = "pause_expires_at"
        case pausedIndefinitely = "paused_indefinitely"
    }

    /// Convert to domain model.
    ///
    /// - Returns: The domain Session, or nil if the UUID is invalid.
    func toDomain() -> Session? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        return Session(
            id: uuid,
            locale: Locale(identifier: locale),
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map { Date(timeIntervalSince1970: $0) },
            title: title,
            status: Session.Status(rawValue: status) ?? .active,
            lastDedupedSegmentSeq: lastDedupedSegmentSeq,
            pauseExpiresAt: pauseExpiresAt.map { Date(timeIntervalSince1970: $0) },
            pausedIndefinitely: pausedIndefinitely != 0
        )
    }

    /// Create a record from a domain model.
    ///
    /// - Parameter session: The domain Session.
    /// - Returns: A SessionRecord ready for persistence.
    static func from(_ session: Session) -> SessionRecord {
        SessionRecord(
            id: session.id.uuidString,
            locale: session.locale.identifier,
            startedAt: session.startedAt.timeIntervalSince1970,
            endedAt: session.endedAt?.timeIntervalSince1970,
            title: session.title,
            status: session.status.rawValue,
            createdAt: Date().timeIntervalSince1970,
            lastDedupedSegmentSeq: session.lastDedupedSegmentSeq,
            pauseExpiresAt: session.pauseExpiresAt?.timeIntervalSince1970,
            pausedIndefinitely: session.pausedIndefinitely ? 1 : 0
        )
    }
}
