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

    /// Cursor advanced by `DedupCoordinator` (U11). The mic-segment seq up to
    /// which dedup has evaluated this session. `0` means dedup has not run yet
    /// or there are no mic segments to evaluate.
    public var lastDedupedSegmentSeq: Int

    /// Wall-clock expiry of a timed pause. `nil` when not paused or when the
    /// pause is indefinite. Persisted across daemon restart so a pause
    /// outlives crashes/sleep — see U10's daemon-start rule.
    public var pauseExpiresAt: Date?

    /// `true` when the session is paused with no auto-resume. Privacy-critical
    /// disambiguator: a corrupted/unmigrated row must not surprise-resume into
    /// recording — see U10.
    public var pausedIndefinitely: Bool

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
        status: Status = .active,
        lastDedupedSegmentSeq: Int = 0,
        pauseExpiresAt: Date? = nil,
        pausedIndefinitely: Bool = false
    ) {
        self.id = id
        self.locale = locale
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.status = status
        self.lastDedupedSegmentSeq = lastDedupedSegmentSeq
        self.pauseExpiresAt = pauseExpiresAt
        self.pausedIndefinitely = pausedIndefinitely
    }
}
