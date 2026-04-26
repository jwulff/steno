import Foundation

/// Recovery-orchestration delegate that `SystemAudioSource` calls when
/// the SCStream stops with an error. Decouples the source from the
/// engine — the source knows how to classify the SCStream error code
/// (via `SystemAudioErrorClassifier`) but does not directly drive U5's
/// `restartSystemPipeline` or emit `recoveryExhausted` events.
///
/// `RecordingEngine` is the production conformer. Tests inject a mock
/// to assert the source dispatched the right action without spinning
/// up the full engine actor.
///
/// **Concurrency:** All methods are `async` and may be invoked from the
/// SCStream's internal delivery queue. Conformers (notably the
/// `RecordingEngine` actor) take care of trampolining onto their own
/// isolation domain.
public protocol SystemAudioRecoveryDelegate: AnyObject, Sendable {
    /// The SCStream stopped because of a transient error. The engine
    /// should rebuild via U5's `restartSystemPipeline` with the given
    /// `errorCode` so the bounded backoff applies "same-error"
    /// surrender semantics correctly.
    ///
    /// - Parameters:
    ///   - errorCode: The stable backoff key (e.g.
    ///     `"<domain>#<code>"`). Pass-through to `BackoffPolicy.record(error:)`.
    ///   - reason: Human-readable reason, surfaced via the
    ///     `.recovering(reason:)` engine event.
    func systemAudioRequestsRetry(errorCode: String, reason: String) async

    /// The SCStream stopped because Screen Recording TCC permission was
    /// revoked. The engine emits a non-transient `recoveryExhausted`
    /// event whose reason is the load-bearing
    /// `MIC_OR_SCREEN_PERMISSION_REVOKED` token, transitions to
    /// `.error`, and does NOT retry.
    func systemAudioPermissionRevoked() async
}
