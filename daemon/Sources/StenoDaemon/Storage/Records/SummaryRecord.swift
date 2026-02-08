import Foundation
import GRDB

/// GRDB record type for the summaries table.
struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"

    var id: String
    var sessionId: String
    var content: String
    var summaryType: String
    var segmentRangeStart: Int
    var segmentRangeEnd: Int
    var modelId: String
    var createdAt: Double

    /// Convert to domain model.
    ///
    /// - Returns: The domain Summary, or nil if UUIDs are invalid.
    func toDomain() -> Summary? {
        guard let uuid = UUID(uuidString: id),
              let sessionUUID = UUID(uuidString: sessionId) else {
            return nil
        }

        return Summary(
            id: uuid,
            sessionId: sessionUUID,
            content: content,
            summaryType: Summary.SummaryType(rawValue: summaryType) ?? .rolling,
            segmentRangeStart: segmentRangeStart,
            segmentRangeEnd: segmentRangeEnd,
            modelId: modelId,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    /// Create a record from a domain model.
    ///
    /// - Parameter summary: The domain Summary.
    /// - Returns: A SummaryRecord ready for persistence.
    static func from(_ summary: Summary) -> SummaryRecord {
        SummaryRecord(
            id: summary.id.uuidString,
            sessionId: summary.sessionId.uuidString,
            content: summary.content,
            summaryType: summary.summaryType.rawValue,
            segmentRangeStart: summary.segmentRangeStart,
            segmentRangeEnd: summary.segmentRangeEnd,
            modelId: summary.modelId,
            createdAt: summary.createdAt.timeIntervalSince1970
        )
    }
}
