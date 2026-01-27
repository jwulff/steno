import Foundation

/// Result from speech recognition containing transcribed text and metadata.
public struct TranscriptionResult: Sendable, Equatable {
    /// The transcribed text.
    public let text: String

    /// Whether this result is final or may be updated.
    public let isFinal: Bool

    /// Recognition confidence score (0.0 to 1.0), if available.
    public let confidence: Float?

    /// When this result was generated.
    public let timestamp: Date

    /// Detailed segments for this result, if available.
    public let segments: [TranscriptSegment]?

    public init(
        text: String,
        isFinal: Bool,
        confidence: Float? = nil,
        timestamp: Date = Date(),
        segments: [TranscriptSegment]? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
        self.segments = segments
    }
}

/// Errors that can occur during speech recognition.
public enum SpeechRecognitionError: Error, Equatable {
    case notAuthorized
    case audioInputUnavailable
    case recognitionFailed(String)
    case localeNotSupported(Locale)
}

/// Protocol for speech recognition services.
/// Implementations handle audio capture and transcription.
public protocol SpeechRecognitionService: Sendable {
    /// Whether the service is currently listening and transcribing.
    var isListening: Bool { get async }

    /// Starts transcription and returns a stream of results.
    /// - Parameter locale: The locale for speech recognition.
    /// - Returns: An async stream of transcription results.
    func startTranscription(locale: Locale) -> AsyncThrowingStream<TranscriptionResult, Error>

    /// Stops the current transcription session.
    func stopTranscription() async
}
