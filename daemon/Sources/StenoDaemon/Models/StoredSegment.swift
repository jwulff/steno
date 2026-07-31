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

    /// When the recognizer *emitted* this result, in wall clock.
    ///
    /// Despite the name this is not an audio time: `RecognizerResult.timestamp`
    /// defaults to `Date()` at the moment the result is constructed, and the
    /// production recognizer never overrides it. Under a transcription backlog
    /// that can be far later than the audio it describes. Kept for continuity
    /// and for pre-`captured_at` rows — order and window on `capturedAt`.
    public let startedAt: Date

    /// When this segment was handed to persistence, in wall clock. Like
    /// `startedAt`, not an audio time.
    public let endedAt: Date

    /// Wall-clock instant the audio was *captured* (#85).
    ///
    /// Recovered from the analyzer's own input timeline —
    /// `analyzerStartWallClock[source] + audioStart` — which advances with
    /// audio frames rather than with processing, so it stays true no matter
    /// how far behind transcription has fallen. This is the only timeline on
    /// which the microphone and systemAudio workers are comparable, and
    /// therefore the axis for ordering, dedup windows, and lag.
    ///
    /// Falls back to `startedAt` when the recognizer reports no valid audio
    /// range (the mock recognizer, an invalid `CMTimeRange`) and for rows
    /// written before the column existed, so it is always populated.
    public let capturedAt: Date

    /// Recognition confidence score (0.0 to 1.0), if available.
    public let confidence: Float?

    /// Position of this segment within the session (1-based).
    ///
    /// Assigned by `TranscriptRepository.appendSegment` inside the same
    /// transaction as the insert (#83), so assignment order and commit order
    /// are identical. Construct with `unassignedSequence` when appending;
    /// the value you pass is overwritten.
    public let sequenceNumber: Int

    /// Sentinel for a segment whose sequence number has not been assigned
    /// yet. Real sequence numbers are 1-based.
    public static let unassignedSequence = 0

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

    /// Audio-frame start of this segment in seconds on the source's per-bring-up
    /// capture clock — the frame-accurate axis shared with the diarization ring
    /// buffer (#56), used by the diarization merge (#61) to attach speaker
    /// labels. Distinct from `startedAt` (wall-clock, for dedup / demarcation /
    /// display). `nil` when the recognizer didn't report a valid range, or for
    /// rows persisted before #64.
    public let audioStart: TimeInterval?

    /// Audio-frame end (`audioStart + duration`) in capture-clock seconds.
    /// `nil` under the same conditions as `audioStart`.
    public let audioEnd: TimeInterval?

    /// Global speaker this segment was attributed to by the diarization merge
    /// (#61), as the raw UUID of a `SpeakerID`. `nil` until a diarization window
    /// covering this segment finalizes (labels backfill, so this can transition
    /// nil → set and may be revised). Display ("Speaker N" / a name) is derived
    /// from this ID separately (#54), never stored here.
    public let speakerId: UUID?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        text: String,
        startedAt: Date,
        endedAt: Date,
        capturedAt: Date? = nil,
        confidence: Float? = nil,
        sequenceNumber: Int,
        createdAt: Date = Date(),
        source: AudioSourceType = .microphone,
        healMarker: String? = nil,
        duplicateOf: UUID? = nil,
        dedupMethod: DedupMethod? = nil,
        micPeakDb: Double? = nil,
        audioStart: TimeInterval? = nil,
        audioEnd: TimeInterval? = nil,
        speakerId: UUID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        // Default to the emission timestamp so every construction site —
        // including tests and pre-`captured_at` rows — has a usable audio
        // axis without having to know about the analyzer timeline.
        self.capturedAt = capturedAt ?? startedAt
        self.confidence = confidence
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
        self.source = source
        self.healMarker = healMarker
        self.duplicateOf = duplicateOf
        self.dedupMethod = dedupMethod
        self.micPeakDb = micPeakDb
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.speakerId = speakerId
    }

    /// This segment with `sequenceNumber` replaced. Used by the repository
    /// to return the value it assigned during the insert transaction.
    public func withSequenceNumber(_ sequenceNumber: Int) -> StoredSegment {
        StoredSegment(
            id: id,
            sessionId: sessionId,
            text: text,
            startedAt: startedAt,
            endedAt: endedAt,
            capturedAt: capturedAt,
            confidence: confidence,
            sequenceNumber: sequenceNumber,
            createdAt: createdAt,
            source: source,
            healMarker: healMarker,
            duplicateOf: duplicateOf,
            dedupMethod: dedupMethod,
            micPeakDb: micPeakDb,
            audioStart: audioStart,
            audioEnd: audioEnd,
            speakerId: speakerId
        )
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
