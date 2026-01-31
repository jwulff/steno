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
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    /// Create a record from a domain model.
    ///
    /// - Parameter segment: The domain StoredSegment.
    /// - Returns: A SegmentRecord ready for persistence.
    static func from(_ segment: StoredSegment) -> SegmentRecord {
        SegmentRecord(
            id: segment.id.uuidString,
            sessionId: segment.sessionId.uuidString,
            text: segment.text,
            startedAt: segment.startedAt.timeIntervalSince1970,
            endedAt: segment.endedAt.timeIntervalSince1970,
            confidence: segment.confidence.map { Double($0) },
            sequenceNumber: segment.sequenceNumber,
            createdAt: segment.createdAt.timeIntervalSince1970
        )
    }
}
