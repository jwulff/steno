import Foundation

/// An LLM-generated summary of transcript segments.
public struct Summary: Sendable, Codable, Identifiable, Equatable {
    /// Unique identifier for the summary.
    public let id: UUID

    /// The session this summary belongs to.
    public let sessionId: UUID

    /// The generated summary text.
    public let content: String

    /// The type of summary (rolling during transcription or final).
    public let summaryType: SummaryType

    /// First segment sequence number included in this summary.
    public let segmentRangeStart: Int

    /// Last segment sequence number included in this summary.
    public let segmentRangeEnd: Int

    /// Identifier of the model that generated this summary.
    public let modelId: String

    /// When this summary was generated.
    public let createdAt: Date

    /// Types of summaries.
    public enum SummaryType: String, Sendable, Codable {
        /// Generated during transcription every N segments.
        case rolling
        /// Generated at the end of a session.
        case final
    }

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        content: String,
        summaryType: SummaryType = .rolling,
        segmentRangeStart: Int,
        segmentRangeEnd: Int,
        modelId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.content = content
        self.summaryType = summaryType
        self.segmentRangeStart = segmentRangeStart
        self.segmentRangeEnd = segmentRangeEnd
        self.modelId = modelId
        self.createdAt = createdAt
    }
}
