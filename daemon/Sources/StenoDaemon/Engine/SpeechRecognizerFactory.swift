import AVFoundation

/// Result from a speech recognizer — text, finality, and optional metadata.
public struct RecognizerResult: Sendable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Float?
    public let timestamp: Date
    public let source: AudioSourceType

    public init(
        text: String,
        isFinal: Bool,
        confidence: Float? = nil,
        timestamp: Date = Date(),
        source: AudioSourceType = .microphone
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
        self.source = source
    }
}

/// Handle to a running speech recognizer instance.
public protocol SpeechRecognizerHandle: Sendable {
    /// Feed audio buffers and get transcription results.
    func transcribe(buffers: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<RecognizerResult, Error>

    /// Stop the recognizer.
    func stop() async
}

/// Factory for creating speech recognizer instances.
public protocol SpeechRecognizerFactory: Sendable {
    /// Create a new recognizer for the given locale and audio format.
    func makeRecognizer(locale: Locale, format: AVAudioFormat)
        async throws -> SpeechRecognizerHandle
}
