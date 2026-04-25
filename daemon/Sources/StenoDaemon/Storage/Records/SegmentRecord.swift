import Foundation
import GRDB

/// GRDB record type for the segments table.
struct SegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segments"

    var id: String
    var sessionId: String
    var text: String
    var startedAt: Double
    var endedAt: Double
    var confidence: Double?
    var sequenceNumber: Int
    var createdAt: Double
    var source: String

    // U2 additions (see plan R5/R10/R11/R13).
    //
    // These are storage-layer fields only — `StoredSegment` deliberately does
    // NOT surface them yet. Writers (`DedupCoordinator` U11, heal-marker write
    // path U5) will land in later units, and surfacing them on the domain type
    // before there's a writer would invent shape that the writers may want
    // shaped differently.

    /// FK back to the segment that this segment is a duplicate of (the
    /// "kept" canonical segment). NULL means this segment is canonical / not
    /// yet evaluated.
    var duplicateOf: String?

    /// How the dedup match was scored: `'exact' | 'normalized' | 'fuzzy'`.
    /// NULL when `duplicateOf` is NULL.
    var dedupMethod: String?

    /// Heal-marker free-text annotation written by U5/U6 when an in-place
    /// pipeline restart preserves the session across a gap. Example:
    /// `'after_gap:12s'`.
    var healMarker: String?

    /// Peak dBFS observed on the mic during this segment, used by U11's
    /// audio-level heuristic to avoid dropping actively-spoken mic content.
    /// NULL for non-mic segments and for older rows.
    var micPeakDb: Double?

    enum CodingKeys: String, CodingKey {
        case id, sessionId, text, startedAt, endedAt, confidence
        case sequenceNumber, createdAt, source
        case duplicateOf = "duplicate_of"
        case dedupMethod = "dedup_method"
        case healMarker = "heal_marker"
        case micPeakDb = "mic_peak_db"
    }

    /// Convert to domain model.
    ///
    /// - Returns: The domain StoredSegment, or nil if UUIDs are invalid.
    func toDomain() -> StoredSegment? {
        guard let uuid = UUID(uuidString: id),
              let sessionUUID = UUID(uuidString: sessionId) else {
            return nil
        }

        return StoredSegment(
            id: uuid,
            sessionId: sessionUUID,
            text: text,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: endedAt),
            confidence: confidence.map { Float($0) },
            sequenceNumber: sequenceNumber,
            createdAt: Date(timeIntervalSince1970: createdAt),
            source: AudioSourceType(rawValue: source) ?? .microphone
        )
    }

    /// Create a record from a domain model.
    ///
    /// - Parameter segment: The domain StoredSegment.
    /// - Returns: A SegmentRecord ready for persistence.
    ///
    /// Note: U2 dedup/heal fields default to NULL here. Writers in U5/U11
    /// will mutate them via dedicated UPDATE queries on the repository.
    static func from(_ segment: StoredSegment) -> SegmentRecord {
        SegmentRecord(
            id: segment.id.uuidString,
            sessionId: segment.sessionId.uuidString,
            text: segment.text,
            startedAt: segment.startedAt.timeIntervalSince1970,
            endedAt: segment.endedAt.timeIntervalSince1970,
            confidence: segment.confidence.map { Double($0) },
            sequenceNumber: segment.sequenceNumber,
            createdAt: segment.createdAt.timeIntervalSince1970,
            source: segment.source.rawValue,
            duplicateOf: nil,
            dedupMethod: nil,
            healMarker: nil,
            micPeakDb: nil
        )
    }
}
