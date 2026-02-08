import Foundation

/// Protocol for text summarization services.
///
/// Implementations can use any LLM backend to generate summaries
/// from transcript segments.
public protocol SummarizationService: Sendable {
    /// Whether the summarization model is currently available.
    var isAvailable: Bool { get async }

    /// Generate a brief summary of transcript segments.
    ///
    /// - Parameters:
    ///   - segments: The segments to summarize.
    ///   - previousSummary: Optional previous summary for context.
    /// - Returns: The generated summary text (brief, ~50 tokens).
    /// - Throws: `SummarizationError` if summarization fails.
    func summarize(segments: [StoredSegment], previousSummary: String?) async throws -> String

    /// Generate detailed meeting notes with bullets, action items, and key takeaways.
    ///
    /// - Parameters:
    ///   - segments: The segments to analyze.
    ///   - previousNotes: Optional previous notes for context.
    /// - Returns: Formatted meeting notes with sections.
    /// - Throws: `SummarizationError` if generation fails.
    func generateMeetingNotes(segments: [StoredSegment], previousNotes: String?) async throws -> String

    /// Extract discussion topics from transcript segments.
    ///
    /// - Parameters:
    ///   - segments: The segments to analyze.
    ///   - previousTopics: Previously extracted topics for continuity.
    /// - Returns: Array of extracted topics, or empty array on failure.
    /// - Throws: `SummarizationError` if extraction fails.
    func extractTopics(segments: [StoredSegment], previousTopics: [Topic]) async throws -> [Topic]
}

/// Errors that can occur during summarization.
public enum SummarizationError: Error, Equatable {
    /// The LLM model is not available on this device.
    case modelNotAvailable
    /// Generation failed with the specified reason.
    case generationFailed(String)
    /// Network request failed.
    case networkError(String)
    /// API returned an error response.
    case apiError(Int, String)
}
