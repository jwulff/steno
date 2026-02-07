import Foundation

/// Identifies the audio source that produced a transcript segment.
public enum AudioSourceType: String, Sendable, Codable, Equatable {
    case microphone    // "You"
    case systemAudio   // "Others"
}

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

    /// The audio source that produced this segment.
    public let source: AudioSourceType

    public init(text: String, timestamp: Date, duration: TimeInterval, confidence: Float?, source: AudioSourceType = .microphone) {
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
        self.confidence = confidence
        self.source = source
    }
}
