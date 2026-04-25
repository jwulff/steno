import Foundation

/// Protocol for transcript persistence operations.
///
/// Implementations handle storage of sessions, segments, and summaries.
/// All operations are async and can throw database errors.
public protocol TranscriptRepository: Sendable {
    // MARK: - Sessions

    /// Create a new recording session.
    ///
    /// - Parameter locale: The locale for speech recognition.
    /// - Returns: The created session.
    func createSession(locale: Locale) async throws -> Session

    /// Mark any stranded `active` sessions as `interrupted` and atomically
    /// open a fresh active session. Both operations run inside a single
    /// SQLite transaction so concurrent writers (e.g. a willSleep handler)
    /// never observe the half-state between sweep and new-session-insert,
    /// and so the UPDATE cannot accidentally match the just-inserted new row.
    ///
    /// Each interrupted session's `endedAt` is set to
    /// `COALESCE(MAX(segments.endedAt), startedAt)` — orphans with zero
    /// segments close to their `startedAt` (their cascade-delete eligibility
    /// is U12's concern, not this method's).
    ///
    /// - Parameter locale: The locale for the newly opened session.
    /// - Returns: The newly opened active session.
    func recoverOrphansAndOpenFresh(locale: Locale) async throws -> Session

    /// Mark any stranded `active` sessions as `interrupted` WITHOUT opening
    /// a fresh session. Used by U4's daemon-start path when the privacy
    /// check finds an active pause: orphans must still be closed (they are
    /// stranded rows from a prior crash, separate from the user's pause
    /// intent), but a fresh active session must NOT be opened, since that
    /// would surprise-resume recording.
    ///
    /// Uses the same `endedAt = COALESCE(MAX(segments.endedAt), startedAt)`
    /// rule as `recoverOrphansAndOpenFresh`.
    func sweepActiveOrphans() async throws

    /// Mark a session as completed.
    ///
    /// - Parameter sessionId: The ID of the session to end.
    func endSession(_ sessionId: UUID) async throws

    /// Retrieve a session by ID.
    ///
    /// - Parameter id: The session ID.
    /// - Returns: The session if found, nil otherwise.
    func session(_ id: UUID) async throws -> Session?

    /// Retrieve all sessions, ordered by most recent first.
    ///
    /// - Returns: Array of all sessions.
    func allSessions() async throws -> [Session]

    /// Retrieve the most-recently-modified session, ordered by
    /// `COALESCE(endedAt, startedAt) DESC`. Used by U4's daemon-start
    /// privacy check: if the most recent session is paused (indefinitely
    /// or via an unexpired `pause_expires_at`), the daemon must NOT
    /// auto-start recording.
    ///
    /// - Returns: The most-recently-modified session, or nil if the DB is empty.
    func mostRecentlyModifiedSession() async throws -> Session?

    /// Delete a session and all associated segments and summaries.
    ///
    /// - Parameter id: The ID of the session to delete.
    func deleteSession(_ id: UUID) async throws

    // MARK: - Segments

    /// Save a transcript segment.
    ///
    /// - Parameter segment: The segment to save.
    func saveSegment(_ segment: StoredSegment) async throws

    /// Retrieve all segments for a session, ordered by sequence number.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: Array of segments in order.
    func segments(for sessionId: UUID) async throws -> [StoredSegment]

    /// Retrieve segments within a time range across all sessions.
    ///
    /// - Parameters:
    ///   - from: Start of the time range.
    ///   - to: End of the time range.
    /// - Returns: Array of matching segments.
    func segments(from: Date, to: Date) async throws -> [StoredSegment]

    /// Count segments in a session.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: Number of segments.
    func segmentCount(for sessionId: UUID) async throws -> Int

    // MARK: - Summaries

    /// Save a summary.
    ///
    /// - Parameter summary: The summary to save.
    func saveSummary(_ summary: Summary) async throws

    /// Retrieve all summaries for a session, ordered by creation time.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: Array of summaries.
    func summaries(for sessionId: UUID) async throws -> [Summary]

    /// Get the most recent summary for a session.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: The latest summary if any exist.
    func latestSummary(for sessionId: UUID) async throws -> Summary?

    // MARK: - Topics

    /// Save a topic.
    ///
    /// - Parameter topic: The topic to save.
    func saveTopic(_ topic: Topic) async throws

    /// Retrieve all topics for a session, ordered by segment range start.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: Array of topics in order.
    func topics(for sessionId: UUID) async throws -> [Topic]
}
