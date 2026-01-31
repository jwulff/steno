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

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        text: String,
        startedAt: Date,
        endedAt: Date,
        confidence: Float? = nil,
        sequenceNumber: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.confidence = confidence
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
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
            sequenceNumber: sequenceNumber
        )
    }
}
