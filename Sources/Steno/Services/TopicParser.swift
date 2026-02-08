import Foundation

/// Parses LLM-generated JSON into Topic arrays.
///
/// Handles common LLM output quirks: markdown code fences, extra whitespace,
/// malformed JSON. Returns empty array on failure (topic extraction is non-critical).
public enum TopicParser {
    /// Parse a JSON string into an array of Topics.
    ///
    /// - Parameter jsonString: Raw LLM output, possibly wrapped in markdown code fences.
    /// - Returns: Parsed topics, or empty array if parsing fails.
    public static func parse(_ jsonString: String) -> [Topic] {
        let cleaned = stripCodeFences(jsonString).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return [] }

        do {
            let raw = try JSONDecoder().decode([RawTopic].self, from: data)
            return raw.compactMap { rawTopic -> Topic? in
                guard rawTopic.startSegment <= rawTopic.endSegment else { return nil }
                return Topic(
                    title: rawTopic.title,
                    summary: rawTopic.summary,
                    segmentRange: rawTopic.startSegment...rawTopic.endSegment
                )
            }
        } catch {
            return []
        }
    }

    /// Strip markdown code fences (```json ... ``` or ``` ... ```).
    static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove opening fence: ```json or ```
        if result.hasPrefix("```") {
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
        }

        // Remove closing fence
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Internal JSON structure matching LLM output format.
private struct RawTopic: Decodable {
    let title: String
    let summary: String
    let startSegment: Int
    let endSegment: Int
}
