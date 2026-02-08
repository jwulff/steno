import Foundation
import FoundationModels

private func logModel(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date())
    let logMessage = "[\(timestamp)] [Model] \(message)\n"

    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".steno.log")

    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Describes why the summarization model is unavailable.
public enum ModelUnavailableReason: Sendable, Equatable {
    case available
    case appleIntelligenceNotEnabled
    case deviceNotSupported
    case modelNotReady
    case other(String)

    public var userMessage: String? {
        switch self {
        case .available:
            return nil
        case .appleIntelligenceNotEnabled:
            return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri"
        case .deviceNotSupported:
            return "Apple Intelligence requires M1 chip or later"
        case .modelNotReady:
            return "AI model downloading... Summaries will appear once ready."
        case .other(let reason):
            return "AI unavailable: \(reason)"
        }
    }
}

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
            let reason = await availabilityReason
            return reason == .available
        }
    }

    /// Returns the detailed reason for model availability status.
    public var availabilityReason: ModelUnavailableReason {
        get async {
            let model = SystemLanguageModel.default
            let availability = model.availability
            logModel("Availability: \(availability)")

            switch availability {
            case .available:
                return .available
            case .unavailable(let reason):
                let reasonString = String(describing: reason)
                if reasonString.contains("appleIntelligenceNotEnabled") {
                    return .appleIntelligenceNotEnabled
                } else if reasonString.contains("deviceNotSupported") {
                    return .deviceNotSupported
                } else if reasonString.contains("modelNotReady") {
                    return .modelNotReady
                } else {
                    return .other(reasonString)
                }
            @unknown default:
                return .other("Unknown availability status")
            }
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

        let session = LanguageModelSession { meetingNotesPrompt }

        var prompt = ""
        if let previous = previousNotes {
            prompt += "Previous notes to update/expand:\n\(previous)\n\n"
        }
        prompt += "Transcript:\n\n"
        prompt += segments.map(\.text).joined(separator: " ")

        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 500
        )

        let response = try await session.respond(to: prompt, options: options)
        return response.content
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

        let session = LanguageModelSession { topicExtractionPrompt }

        var prompt = ""
        if !previousTopics.isEmpty {
            prompt += "Previously identified topics (DO NOT re-extract): \(previousTopics.map(\.title).joined(separator: ", "))\n\n"
        }
        prompt += "NEW transcript segments (\(segments.count) total):\n\n"
        for segment in segments {
            prompt += "[\(segment.sequenceNumber)] \(segment.text)\n"
        }

        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: 500
        )

        let response = try await session.respond(to: prompt, options: options)
        return TopicParser.parse(response.content, sessionId: sessionId)
    }
}
