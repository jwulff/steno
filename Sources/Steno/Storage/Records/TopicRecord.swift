import Foundation
import GRDB

/// GRDB record type for the topics table.
struct TopicRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topics"

    var id: String
    var sessionId: String
    var title: String
    var summary: String
    var segmentRangeStart: Int
    var segmentRangeEnd: Int
    var createdAt: Double

    /// Convert to domain model.
    ///
    /// - Returns: The domain Topic, or nil if UUIDs are invalid.
    func toDomain() -> Topic? {
        guard let uuid = UUID(uuidString: id),
              let sessionUUID = UUID(uuidString: sessionId) else {
            return nil
        }

        return Topic(
            id: uuid,
            sessionId: sessionUUID,
            title: title,
            summary: summary,
            segmentRange: segmentRangeStart...segmentRangeEnd,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    /// Create a record from a domain model.
    ///
    /// - Parameter topic: The domain Topic.
    /// - Returns: A TopicRecord ready for persistence.
    static func from(_ topic: Topic) -> TopicRecord {
        TopicRecord(
            id: topic.id.uuidString,
            sessionId: topic.sessionId.uuidString,
            title: topic.title,
            summary: topic.summary,
            segmentRangeStart: topic.segmentRange.lowerBound,
            segmentRangeEnd: topic.segmentRange.upperBound,
            createdAt: topic.createdAt.timeIntervalSince1970
        )
    }
}
