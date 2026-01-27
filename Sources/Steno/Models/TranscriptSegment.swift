import Foundation

/// A single segment of transcribed speech with timing and confidence information.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    /// The transcribed text content.
    public let text: String

    /// When this segment was captured.
    public let timestamp: Date

    /// Duration of the audio for this segment in seconds.
    public let duration: TimeInterval

    /// Recognition confidence score (0.0 to 1.0), if available.
    public let confidence: Float?

    public init(text: String, timestamp: Date, duration: TimeInterval, confidence: Float?) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.confidence = confidence
    }
}
