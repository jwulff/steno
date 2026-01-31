import Foundation
import FoundationModels

/// Summarization service using Apple's Foundation Models (on-device LLM).
///
/// This service uses the system's built-in language model available on
/// macOS 26+ for on-device, private summarization.
public final class FoundationModelSummarizationService: SummarizationService, Sendable {
    private let systemPrompt = """
        You are a concise summarizer. Create brief, accurate summaries of transcribed speech.
        Focus on key points and maintain the speaker's intent.
        Keep summaries under 100 words.
        """

    public init() {}

    public var isAvailable: Bool {
        get async {
            let model = SystemLanguageModel.default
            if case .available = model.availability { return true }
            return false
        }
    }

    public func summarize(segments: [StoredSegment], previousSummary: String?) async throws -> String {
        guard await isAvailable else {
            throw SummarizationError.modelNotAvailable
        }

        let session = LanguageModelSession { systemPrompt }

        var prompt = ""
        if let previous = previousSummary {
            prompt += "Previous context: \(previous)\n\n"
        }
        prompt += "Summarize this transcript:\n\n"
        prompt += segments.map(\.text).joined(separator: " ")

        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 150
        )

        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }
}
