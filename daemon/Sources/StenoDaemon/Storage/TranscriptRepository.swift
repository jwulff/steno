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
    ///
    /// Returns the IDs of the sessions that were just swept from `active`
    /// to `interrupted`. Callers (U6 wake-rollover, U7 device-change-rollover,
    /// U4 daemon-start) feed these IDs into `maybeDeleteIfEmpty` so empty
    /// orphans are pruned at the same close path U10/U12 already covers.
    @discardableResult
    func sweepActiveOrphans() async throws -> [UUID]

    /// Open a fresh `active` session in a single write, without sweeping
    /// orphans first. Used by U4's daemon-start path AFTER a separate
    /// `sweepActiveOrphans()` step has succeeded and any privacy/permission
    /// gates have passed. Splitting this from `recoverOrphansAndOpenFresh`
    /// lets the daemon-start path sequence orphan-sweep BEFORE the
    /// permission check, so a permission failure does not prevent the
    /// orphan sweep (R9).
    ///
    /// - Parameter locale: The locale for the new session.
    /// - Returns: The newly opened active session.
    func openFreshSession(locale: Locale) async throws -> Session

    /// Mark a session as completed.
    ///
    /// - Parameter sessionId: The ID of the session to end.
    func endSession(_ sessionId: UUID) async throws

    /// Atomically close `closingId` (UPDATE → status='completed', endedAt=now)
    /// AND insert a fresh active session — both inside a single SQLite
    /// write transaction. Used by U10's `demarcate` to guarantee the
    /// invariant that at most one row is `status='active'` at any
    /// instant: if the close fails, the new row is NOT inserted; if
    /// the insert fails, the close is rolled back.
    ///
    /// Required because the prior implementation used two separate
    /// writes (`endSession` then `openFreshSession`) with `try?` on the
    /// close — a UPDATE failure could leave the closing session
    /// `active` while the new session was also `active`, violating the
    /// invariant. (Cluster-4 review finding; see PR #37.)
    ///
    /// - Parameters:
    ///   - closingId: The session to close.
    ///   - locale: The locale for the newly opened session.
    /// - Returns: The newly opened active session.
    func closeAndOpenSession(closingId: UUID, locale: Locale) async throws -> Session

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

    /// Count only canonical (non-duplicate) segments in a session.
    /// Used by `RollingSummaryCoordinator` (PR #36 review): the LLM
    /// extraction gate is defined in terms of *meaningful* content, not
    /// total rows. After U11's cross-source dedup runs, a Zoom-style
    /// session may carry mic+sys rows for the same speech and only the
    /// sys rows are canonical — counting both inflates the gate.
    ///
    /// Implemented as `SELECT COUNT(*) FROM segments WHERE sessionId = ?
    /// AND duplicate_of IS NULL`.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: Number of segments where `duplicateOf IS NULL`.
    func nonDuplicateSegmentCount(for sessionId: UUID) async throws -> Int

    /// Largest `sequenceNumber` already persisted for `sessionId`. Returns
    /// 0 when the session has no segments yet (so callers can use
    /// `currentSequenceNumber = max + 1` on the next save without a
    /// special-case for empty sessions).
    ///
    /// Used by the wake-reuse path on `RecordingEngine.bringUpPipelines`
    /// so a resumed session does not collide with its own pre-sleep
    /// segments under the `UNIQUE(sessionId, sequenceNumber)` schema
    /// constraint. Cheap — a single indexed `MAX(sequenceNumber)` lookup.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: The maximum `sequenceNumber` across the session's
    ///   segments, or 0 when the session has no segments.
    func maxSegmentSequence(for sessionId: UUID) async throws -> Int

    // MARK: - Dedup (U11)

    /// Segments past the session's `last_deduped_segment_seq` cursor that
    /// match the given source AND are not already marked as duplicates.
    /// Used by `DedupCoordinator` to enumerate candidates for evaluation.
    ///
    /// - Parameters:
    ///   - sessionId: The session ID.
    ///   - source: Filter by source (typically `.microphone`).
    /// - Returns: Segments ordered by `sequenceNumber` ascending.
    func segmentsAfterDedupCursor(sessionId: UUID, source: AudioSourceType) async throws -> [StoredSegment]

    /// Segments in `sessionId` of the given `source` whose `startedAt`
    /// falls within `[from, to]`. Used by `DedupCoordinator` to find
    /// time-overlapping sys candidates for a given mic segment.
    func overlappingSegments(
        sessionId: UUID,
        source: AudioSourceType,
        from: Date,
        to: Date
    ) async throws -> [StoredSegment]

    /// Mark a mic segment as a duplicate of a sys segment. Sets both
    /// `duplicate_of` and `dedup_method` in a single UPDATE.
    func markDuplicate(
        micSegmentId: UUID,
        sysSegmentId: UUID,
        method: DedupMethod
    ) async throws

    /// Advance the per-session dedup cursor to `toSequence`. Last step of
    /// a `DedupCoordinator.runPass` — only committed after all
    /// `markDuplicate` calls succeed, so a partial failure leaves the
    /// cursor unchanged and the next pass re-evaluates from the same point.
    func advanceDedupCursor(sessionId: UUID, toSequence: Int) async throws

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

    /// Save a topic. Defensive: if the parent session has been pruned
    /// (deleted) between the LLM call's start and this write, the insert
    /// is silently skipped and no FK constraint violation is raised. See
    /// U12 — `RollingSummaryCoordinator` runs LLM calls asynchronously
    /// against a session that may have been deleted by the empty-session
    /// pruner mid-call.
    ///
    /// - Parameter topic: The topic to save.
    func saveTopic(_ topic: Topic) async throws

    /// Retrieve all topics for a session, ordered by segment range start.
    ///
    /// - Parameter sessionId: The session ID.
    /// - Returns: Array of topics in order.
    func topics(for sessionId: UUID) async throws -> [Topic]

    // MARK: - U12 Empty-Session Prune + Retention

    /// Delete `sessionId` if it meets any "empty" criterion. Safe to call
    /// on any closed session (`status != 'active'`). Operates as a single
    /// transaction: read counts/duration → decide → delete (or no-op).
    /// Returns `true` iff the session was deleted.
    ///
    /// Empty criteria (any one trips deletion):
    /// - Zero non-duplicate segments (`COUNT(*) WHERE duplicate_of IS NULL == 0`)
    /// - Sum of non-duplicate segment text length `< minChars` (default 20)
    /// - Wall-clock duration (`endedAt - startedAt`) `< minDurationSeconds` (default 3.0)
    ///
    /// Refuses to operate on a session whose `status == 'active'` or whose
    /// `endedAt IS NULL` — defensive: pruning a session that's still
    /// recording would be a bug. Returns `false` in those cases.
    ///
    /// Cascade-deletes segments, summaries, and topics via the existing
    /// `ON DELETE CASCADE` foreign keys — a single `DELETE FROM sessions
    /// WHERE id = ?` is sufficient.
    ///
    /// Sequencing: callers should run `DedupCoordinator.runPass(sessionId:)`
    /// FIRST so the "non-duplicate text length" check sees the post-dedup
    /// truth.
    func maybeDeleteIfEmpty(
        sessionId: UUID,
        minChars: Int,
        minDurationSeconds: Double
    ) async throws -> Bool

    /// Delete every session whose `endedAt` is older than
    /// `now - retentionDays * 86400`. Cascade-deletes segments, summaries,
    /// and topics via FK. Sessions with `endedAt IS NULL` (still active)
    /// are never touched. Returns the number of sessions deleted.
    ///
    /// Called at daemon start (top of `recoverOrphansAndAutoStart`)
    /// before the orphan sweep so old data is cleaned up before the
    /// fresh session opens. Disk-growth hedge per U12.
    @discardableResult
    func applyRetentionPolicy(retentionDays: Int) async throws -> Int

    // MARK: - Pause state (U10)

    /// Persist pause state on a session row. Anchors the pause to the
    /// most-recent session (typically the just-closed session at the
    /// moment of `pause`); the daemon-start path reads this row to
    /// decide whether to re-enter the paused state across daemon
    /// restart (R-F privacy invariant).
    ///
    /// - Parameters:
    ///   - sessionId: The session whose pause columns are being written.
    ///   - expiresAt: Wall-clock instant the auto-resume timer fires.
    ///     `nil` for indefinite pauses.
    ///   - indefinite: `true` when pause has no auto-resume. Mutually
    ///     exclusive with a non-nil `expiresAt` in normal use; persisting
    ///     both would be a caller bug. Implementations write whatever the
    ///     caller provides.
    func setPauseState(sessionId: UUID, expiresAt: Date?, indefinite: Bool) async throws

    /// Clear pause state on a session row (set both columns to their
    /// "not paused" sentinel: `pause_expires_at = NULL`,
    /// `paused_indefinitely = 0`). Called on `resume`.
    func clearPauseState(sessionId: UUID) async throws
}
