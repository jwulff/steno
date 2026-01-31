import Foundation

/// Protocol for text summarization services.
///
/// Implementations can use any LLM backend to generate summaries
/// from transcript segments.
public protocol SummarizationService: Sendable {
    /// Whether the summarization model is currently available.
    var isAvailable: Bool { get async }

    /// Summarize a set of transcript segments.
    ///
    /// - Parameters:
    ///   - segments: The segments to summarize.
    ///   - previousSummary: Optional previous summary for context.
    /// - Returns: The generated summary text.
    /// - Throws: `SummarizationError` if summarization fails.
    func summarize(segments: [StoredSegment], previousSummary: String?) async throws -> String
}

/// Errors that can occur during summarization.
public enum SummarizationError: Error, Equatable {
    /// The LLM model is not available on this device.
    case modelNotAvailable
    /// Generation failed with the specified reason.
    case generationFailed(String)
}
