import AVFoundation

/// Result from a speech recognizer — text, finality, and optional metadata.
public struct RecognizerResult: Sendable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Float?
    public let timestamp: Date
    public let source: AudioSourceType
    /// Audio-frame start of this result on the analyzer's input timeline
    /// (seconds since the analyzer began consuming audio), when the recognizer
    /// reports it. This is the frame-accurate join axis for diarization (#64) —
    /// it shares the source's capture clock with the diarization ring buffer
    /// (#56), unlike `timestamp` (wall-clock emission time, kept for dedup /
    /// demarcation / display). `nil` when unavailable (e.g. the mock
    /// recognizer, or an invalid range).
    public let audioStartSeconds: TimeInterval?
    /// Audio duration of this result in seconds, when reported.
    public let audioDurationSeconds: TimeInterval?

    public init(
        text: String,
        isFinal: Bool,
        confidence: Float? = nil,
        timestamp: Date = Date(),
        source: AudioSourceType = .microphone,
        audioStartSeconds: TimeInterval? = nil,
        audioDurationSeconds: TimeInterval? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
        self.source = source
        self.audioStartSeconds = audioStartSeconds
        self.audioDurationSeconds = audioDurationSeconds
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
    /// Create a new recognizer for the given locale, audio format, and source type.
    func makeRecognizer(locale: Locale, format: AVAudioFormat, source: AudioSourceType)
        async throws -> SpeechRecognizerHandle
}
