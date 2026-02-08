import Foundation

/// Token usage reported from an API call.
public struct TokenUsage: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }
}

/// Summarization service using Anthropic's Claude API.
public final class AnthropicSummarizationService: SummarizationService, Sendable {
    private let apiKey: String
    private let model: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let onTokenUsage: (@Sendable (TokenUsage) -> Void)?

    private let systemPrompt = """
        You are a concise summarizer. Create brief, accurate summaries of transcribed speech.
        Focus on key points and maintain the speaker's intent.
        Keep summaries under 100 words.
        """

    /// Creates a new Anthropic summarization service.
    ///
    /// - Parameters:
    ///   - apiKey: Your Anthropic API key.
    ///   - model: The model to use (default: claude-3-5-haiku for speed/cost).
    ///   - onTokenUsage: Optional callback invoked with token usage after each API call.
    public init(
        apiKey: String,
        model: String = "claude-3-5-haiku-20241022",
        onTokenUsage: (@Sendable (TokenUsage) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.onTokenUsage = onTokenUsage
    }

    public var isAvailable: Bool {
        get async {
            !apiKey.isEmpty
        }
    }

    public func summarize(segments: [StoredSegment], previousSummary: String?) async throws -> String {
        guard await isAvailable else {
            throw SummarizationError.modelNotAvailable
        }

        var userPrompt = ""
        if let previous = previousSummary {
            userPrompt += "Previous context: \(previous)\n\n"
        }
        userPrompt += "Summarize this transcript:\n\n"
        userPrompt += segments.map(\.text).joined(separator: " ")

        let requestBody = AnthropicRequest(
            model: model,
            max_tokens: 150,
            system: systemPrompt,
            messages: [
                AnthropicMessage(role: "user", content: userPrompt)
            ]
        )

        let request = try makeRequest(body: requestBody)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizationError.apiError(httpResponse.statusCode, errorBody)
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        // Report token usage
        if let usage = anthropicResponse.usage {
            onTokenUsage?(TokenUsage(inputTokens: usage.input_tokens, outputTokens: usage.output_tokens))
        }

        guard let textContent = anthropicResponse.content.first(where: { $0.type == "text" }) else {
            throw SummarizationError.networkError("No text content in response")
        }

        return textContent.text
    }

    private let meetingNotesPrompt = """
        You are a meeting notes assistant. Analyze the transcript and create structured notes.
        Format your response with these sections (use bullet points):

        KEY POINTS:
        • Main topics discussed

        ACTION ITEMS:
        • Tasks mentioned (include who if specified)

        DECISIONS:
        • Any decisions made

        QUESTIONS/FOLLOW-UPS:
        • Open questions or items needing follow-up

        Keep each bullet concise (under 15 words). Skip sections if not applicable.
        """

    public func generateMeetingNotes(segments: [StoredSegment], previousNotes: String?) async throws -> String {
        guard await isAvailable else {
            throw SummarizationError.modelNotAvailable
        }

        var userPrompt = ""
        if let previous = previousNotes {
            userPrompt += "Previous notes to update/expand:\n\(previous)\n\n"
        }
        userPrompt += "Transcript:\n\n"
        userPrompt += segments.map(\.text).joined(separator: " ")

        let requestBody = AnthropicRequest(
            model: model,
            max_tokens: 500,
            system: meetingNotesPrompt,
            messages: [
                AnthropicMessage(role: "user", content: userPrompt)
            ]
        )

        let request = try makeRequest(body: requestBody)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizationError.apiError(httpResponse.statusCode, errorBody)
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        // Report token usage
        if let usage = anthropicResponse.usage {
            onTokenUsage?(TokenUsage(inputTokens: usage.input_tokens, outputTokens: usage.output_tokens))
        }

        guard let textContent = anthropicResponse.content.first(where: { $0.type == "text" }) else {
            throw SummarizationError.networkError("No text content in response")
        }

        return textContent.text
    }

    private let topicExtractionPrompt = """
        You are a meeting topic extractor. Extract topics ONLY from the provided segments \
        (these are NEW segments not yet covered by existing topics).
        Previously identified topics are listed for context — do NOT re-extract them.
        Return a JSON array of topics. Each topic has:
        - "title": 2-5 word topic name
        - "summary": 1-3 sentence description of what was discussed
        - "startSegment": first segment number (1-based)
        - "endSegment": last segment number (1-based)

        Return ONLY the JSON array, no other text.
        """

    public func extractTopics(segments: [StoredSegment], previousTopics: [Topic], sessionId: UUID) async throws -> [Topic] {
        guard await isAvailable else {
            throw SummarizationError.modelNotAvailable
        }

        guard !segments.isEmpty else { return [] }

        var userPrompt = ""
        if !previousTopics.isEmpty {
            userPrompt += "Previously identified topics (DO NOT re-extract): \(previousTopics.map(\.title).joined(separator: ", "))\n\n"
        }
        userPrompt += "NEW transcript segments (\(segments.count) total):\n\n"
        for segment in segments {
            userPrompt += "[\(segment.sequenceNumber)] \(segment.text)\n"
        }

        let requestBody = AnthropicRequest(
            model: model,
            max_tokens: 500,
            system: topicExtractionPrompt,
            messages: [
                AnthropicMessage(role: "user", content: userPrompt)
            ]
        )

        let request = try makeRequest(body: requestBody)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizationError.apiError(httpResponse.statusCode, errorBody)
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        if let usage = anthropicResponse.usage {
            onTokenUsage?(TokenUsage(inputTokens: usage.input_tokens, outputTokens: usage.output_tokens))
        }

        guard let textContent = anthropicResponse.content.first(where: { $0.type == "text" }) else {
            throw SummarizationError.networkError("No text content in response")
        }

        return TopicParser.parse(textContent.text, sessionId: sessionId)
    }

    private func makeRequest(body: AnthropicRequest) throws -> URLRequest {
        guard let url = URL(string: baseURL) else {
            throw SummarizationError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - API Types

private struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [AnthropicMessage]
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: String
}

private struct AnthropicResponse: Decodable {
    let content: [ContentBlock]
    let usage: Usage?
}

private struct ContentBlock: Decodable {
    let type: String
    let text: String
}

private struct Usage: Decodable {
    let input_tokens: Int
    let output_tokens: Int
}

// MARK: - Models API

/// Represents an available Claude model from the API.
public struct ClaudeModel: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let createdAt: Date?
}

/// Fetches available models from the Anthropic API.
public func fetchAvailableModels(apiKey: String) async throws -> [ClaudeModel] {
    guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
        throw SummarizationError.networkError("Invalid URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
        throw SummarizationError.networkError("Invalid response")
    }

    guard httpResponse.statusCode == 200 else {
        let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw SummarizationError.apiError(httpResponse.statusCode, errorBody)
    }

    let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)

    return modelsResponse.data.map { model in
        ClaudeModel(
            id: model.id,
            displayName: model.display_name,
            createdAt: ISO8601DateFormatter().date(from: model.created_at ?? "")
        )
    }
}

private struct ModelsResponse: Decodable {
    let data: [ModelData]
}

private struct ModelData: Decodable {
    let id: String
    let display_name: String
    let created_at: String?
}
