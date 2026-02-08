import Foundation

/// Events emitted by the RecordingEngine.
///
/// Events are either ephemeral (streamed to connected clients only)
/// or persisted (also written to the database).
public enum EngineEvent: Sendable {
    /// Ephemeral: partial transcription text from a recognizer.
    case partialText(String, AudioSourceType)
    /// Ephemeral: audio levels, pre-throttled to 10Hz.
    case audioLevel(mic: Float, system: Float)
    /// Persisted + ephemeral: a finalized segment.
    case segmentFinalized(StoredSegment)
    /// Persisted + ephemeral: topics updated after summarization.
    case topicsUpdated([Topic])
    /// Ephemeral: engine status change.
    case statusChanged(EngineStatus)
    /// Ephemeral: model is processing (summarization in progress).
    case modelProcessing(Bool)
    /// Ephemeral: error occurred.
    case error(String, isTransient: Bool)
}

/// Status of the recording engine.
public enum EngineStatus: String, Sendable, Codable {
    case idle
    case starting
    case recording
    case stopping
    case error
}

/// Delegate that receives events from the RecordingEngine.
public protocol RecordingEngineDelegate: Sendable {
    func engine(_ engine: RecordingEngine, didEmit event: EngineEvent) async
}
