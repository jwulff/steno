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
            status: Session.Status(rawValue: status) ?? .active
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
            createdAt: Date().timeIntervalSince1970
        )
    }
}
