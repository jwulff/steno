import Foundation

/// A persisted transcript segment with session association and sequence information.
///
/// This model is separate from `TranscriptSegment` (used for real-time streaming)
/// to allow independent persistence without breaking the streaming API.
public struct StoredSegment: Sendable, Codable, Identifiable, Equatable {
    /// Unique identifier for the segment.
    public let id: UUID

    /// The session this segment belongs to.
    public let sessionId: UUID

    /// The transcribed text content.
    public let text: String

    /// When this segment started in the audio.
    public let startedAt: Date

    /// When this segment ended in the audio.
    public let endedAt: Date

    /// Recognition confidence score (0.0 to 1.0), if available.
    public let confidence: Float?

    /// Position of this segment within the session (1-based).
    public let sequenceNumber: Int

    /// When this segment was persisted.
    public let createdAt: Date

    /// The audio source that produced this segment.
    public let source: AudioSourceType

    /// Heal-marker annotation written by U5/U6 when an in-place pipeline
    /// restart preserves the session across a gap. Example:
    /// `"after_gap:12s"`. `nil` for normal (non-healed) segments.
    /// Surfaces the U2-schema `segments.heal_marker` column on the
    /// domain model so the engine can stamp the marker on the first
    /// segment delivered after a successful restart (U5).
    public let healMarker: String?

    /// Set by `DedupCoordinator` (U11) when this segment is a duplicate of
    /// another segment in the same session. `nil` means canonical / not yet
    /// evaluated. Surfaces the U2-schema `segments.duplicate_of` column.
    public let duplicateOf: UUID?

    /// One of `.exact / .normalized / .fuzzy` when `duplicateOf` is set;
    /// `nil` otherwise. Surfaces the U2-schema `segments.dedup_method` column.
    public let dedupMethod: DedupMethod?

    /// Peak dBFS observed during a mic segment's lifetime. Used by U11's
    /// audio-level guard to avoid marking actively-spoken mic content as
    /// duplicate. `nil` for non-mic segments and for rows persisted before
    /// per-segment metering landed.
    public let micPeakDb: Double?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        text: String,
        startedAt: Date,
        endedAt: Date,
        confidence: Float? = nil,
        sequenceNumber: Int,
        createdAt: Date = Date(),
        source: AudioSourceType = .microphone,
        healMarker: String? = nil,
        duplicateOf: UUID? = nil,
        dedupMethod: DedupMethod? = nil,
        micPeakDb: Double? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.confidence = confidence
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
        self.source = source
        self.healMarker = healMarker
        self.duplicateOf = duplicateOf
        self.dedupMethod = dedupMethod
        self.micPeakDb = micPeakDb
    }

    /// Create a stored segment from a streaming TranscriptSegment.
    ///
    /// - Parameters:
    ///   - segment: The real-time segment to persist.
    ///   - sessionId: The session to associate with.
    ///   - sequenceNumber: The position within the session.
    /// - Returns: A new StoredSegment ready for persistence.
    public static func from(
        _ segment: TranscriptSegment,
        sessionId: UUID,
        sequenceNumber: Int
    ) -> StoredSegment {
        StoredSegment(
            sessionId: sessionId,
            text: segment.text,
            startedAt: segment.timestamp,
            endedAt: segment.timestamp.addingTimeInterval(segment.duration),
            confidence: segment.confidence,
            sequenceNumber: sequenceNumber,
            source: segment.source
        )
    }
}
