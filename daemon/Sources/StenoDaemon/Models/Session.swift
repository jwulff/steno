import Foundation

/// A recording session container that groups related transcript segments.
public struct Session: Sendable, Codable, Identifiable, Equatable {
    /// Unique identifier for the session.
    public let id: UUID

    /// The locale used for speech recognition in this session.
    public let locale: Locale

    /// When the session started.
    public let startedAt: Date

    /// When the session ended (nil if still active).
    public var endedAt: Date?

    /// Optional user-assigned title for the session.
    public var title: String?

    /// Current status of the session.
    public var status: Status

    /// Possible states for a session.
    public enum Status: String, Sendable, Codable {
        /// Session is currently recording.
        case active
        /// Session ended normally.
        case completed
        /// Session was interrupted (crash, force quit, etc.).
        case interrupted
    }

    public init(
        id: UUID = UUID(),
        locale: Locale,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        title: String? = nil,
        status: Status = .active
    ) {
        self.id = id
        self.locale = locale
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.status = status
    }
}
