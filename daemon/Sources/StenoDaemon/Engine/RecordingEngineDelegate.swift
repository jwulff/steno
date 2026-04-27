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
    /// Ephemeral: a pipeline restart is starting (U5).
    ///
    /// Fires on the *entry* to a `restartMicPipeline(reason:)` /
    /// `restartSystemPipeline(reason:)` call, before the backoff wait.
    /// Pairs with a later `.healed(...)` (success) or
    /// `.recoveryExhausted(...)` (surrender) event.
    case recovering(reason: String)
    /// Ephemeral: a pipeline restart succeeded and the gap is now closed (U5).
    ///
    /// Fires on the first segment finalized after the rebuilt pipeline
    /// begins delivering results, carrying the measured gap from the
    /// teardown that triggered the restart through to first-finalized.
    /// Used by the TUI to surface the brief "healed" indicator.
    case healed(gapSeconds: Double)
    /// Ephemeral: the backoff policy surrendered after 5 same-error
    /// attempts (U5). Engine status transitions to `.error`. The TUI
    /// surfaces this as a non-transient error (U9).
    case recoveryExhausted(reason: String)
}

/// Status of the recording engine.
public enum EngineStatus: String, Sendable, Codable {
    case idle
    case starting
    case recording
    case stopping
    case error
    /// Pipeline is being restarted in place after a transient failure (U5).
    /// The engine is between teardown and successful rebuild; clients
    /// should expect a brief gap in transcription. Status returns to
    /// `.recording` on success or `.error` on surrender.
    case recovering
}

/// Delegate that receives events from the RecordingEngine.
public protocol RecordingEngineDelegate: Sendable {
    func engine(_ engine: RecordingEngine, didEmit event: EngineEvent) async
}
