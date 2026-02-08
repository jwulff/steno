import Foundation

/// A discussion topic extracted from transcript segments by LLM analysis.
public struct Topic: Sendable, Codable, Identifiable, Equatable {
    /// Unique identifier for this topic.
    public let id: UUID

    /// Short title describing the topic (2-5 words).
    public let title: String

    /// 1-3 sentence detail about what was discussed.
    public let summary: String

    /// Range of segment sequence numbers this topic covers.
    public let segmentRange: ClosedRange<Int>

    /// When this topic was extracted.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        segmentRange: ClosedRange<Int>,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.segmentRange = segmentRange
        self.createdAt = createdAt
    }
}
