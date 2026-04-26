import Foundation

/// Bounded exponential backoff policy used by U5 (recognizer restart),
/// U6 (sleep/wake recovery), U7 (device-change recovery), and U8 (SCStream
/// recovery) to throttle pipeline-restart attempts and surrender after a
/// run of repeated same-error failures.
///
/// Curve (per attempt N, capped at 30s):
///   1 → 1s, 2 → 2s, 3 → 4s, 4 → 8s, 5+ → 30s.
///
/// Surrender semantics:
///   - 5 consecutive *same-error* attempts exhaust the policy.
///     `record(error:)` then returns `.exhausted`, and `isExhausted`
///     stays true until the policy is rebuilt.
///   - "Same error" is judged by an opaque error-code string (the caller
///     decides the keying — typically a stable error-code or NSError
///     domain+code). A different error code resets the consecutive
///     counter to 1 (not 0 — the new error is itself attempt 1).
///
/// Reset semantics (precise — load-bearing for plan U5):
///   `attempts := 0` only after BOTH:
///     (a) at least one segment has been finalized post-restart, AND
///     (b) at least 30 seconds of stable wall-clock operation have
///         elapsed since the last `recordRestart()` call.
///   First-sample arrival alone is insufficient: that masks infinite
///   cheap-restart loops where audio buffers flow but transcriptions
///   never finalize before the next failure.
///
/// Concurrency: `BackoffPolicy` is a pure value type (struct). Callers
/// embed it inside an actor (e.g. `RecordingEngine`) and let the actor's
/// serialization provide thread-safety. No internal locking is needed.
public struct BackoffPolicy: Sendable, Equatable {

    /// Outcome of recording an error against the policy.
    public enum RecordOutcome: Sendable, Equatable {
        /// Wait this duration before retrying.
        case delay(Duration)
        /// Surrender — five same-error attempts have been exhausted.
        case exhausted
    }

    // MARK: - Tunables

    /// Backoff curve in seconds. Capped at 30s for attempts beyond the curve.
    private static let curveSeconds: [Int] = [1, 2, 4, 8]
    /// Cap for attempts past the end of `curveSeconds`.
    private static let capSeconds: Int = 30
    /// Number of consecutive same-error attempts before surrender.
    public static let surrenderThreshold: Int = 5
    /// Wall-clock seconds of stable operation needed for reset.
    private static let resetStabilitySeconds: TimeInterval = 30

    // MARK: - State

    /// Number of recorded restart attempts. 0 means fresh / just reset.
    public private(set) var attempts: Int = 0

    /// Error code observed on the most recent `record(error:)` call. Used
    /// to detect "same error" runs for surrender.
    public private(set) var lastErrorCode: String?

    /// Wall-clock timestamp of the most recent `recordRestart()` call.
    /// `nil` until the engine reports a successful pipeline rebuild.
    public private(set) var restartTimestamp: Date?

    /// Count of segments finalized since the most recent
    /// `recordRestart()`. Resets to 0 on each `recordRestart()`.
    public private(set) var segmentsFinalizedSinceRestart: Int = 0

    /// Whether the policy has surrendered. Once exhausted, callers should
    /// rebuild the policy (typically after an external stimulus
    /// re-enables recording, per the plan's "Engine-state recovery from
    /// `error`" section).
    public private(set) var isExhausted: Bool = false

    public init() {}

    // MARK: - State transitions

    /// Record an error and return the next backoff outcome.
    ///
    /// Behavior:
    ///   - If `errorCode == lastErrorCode`, the consecutive counter
    ///     advances. Five same-error attempts → `.exhausted`.
    ///   - If `errorCode != lastErrorCode`, the consecutive counter
    ///     resets to 1 (the new error itself is attempt 1).
    ///   - When already exhausted, returns `.exhausted` without further
    ///     state changes.
    ///
    /// - Parameter errorCode: Stable string identifying the error class.
    /// - Returns: `.delay(Duration)` for callers to await, or `.exhausted`.
    public mutating func record(error errorCode: String) -> RecordOutcome {
        if isExhausted {
            return .exhausted
        }

        if lastErrorCode == errorCode {
            attempts += 1
        } else {
            // Different error → counter restarts at 1 (the new error is
            // itself attempt #1, not attempt #0).
            attempts = 1
            lastErrorCode = errorCode
        }

        if attempts >= Self.surrenderThreshold {
            isExhausted = true
            return .exhausted
        }

        return .delay(Self.delay(forAttempt: attempts))
    }

    /// Notify the policy that a restart attempt has succeeded (the
    /// pipeline is up). Starts the wall-clock window for reset and
    /// clears the per-restart segment counter.
    ///
    /// This does NOT clear `attempts` — reset is conditional on
    /// `tryReset(now:)` after both gates are satisfied.
    public mutating func recordRestart(now: Date = Date()) {
        restartTimestamp = now
        segmentsFinalizedSinceRestart = 0
    }

    /// Notify the policy that a segment was finalized after a restart.
    /// Increments the per-restart finalized-segment counter. No-op if
    /// the policy has not seen a restart yet.
    public mutating func recordSegmentFinalized() {
        guard restartTimestamp != nil else { return }
        segmentsFinalizedSinceRestart += 1
    }

    /// Attempt to reset `attempts` to 0. Reset only happens when BOTH
    /// gates are satisfied:
    ///   (a) at least one finalized segment since the last restart, AND
    ///   (b) at least `resetStabilitySeconds` of wall time have elapsed.
    ///
    /// - Parameter now: Current wall-clock time (injectable for tests).
    /// - Returns: `true` iff the reset actually fired.
    @discardableResult
    public mutating func tryReset(now: Date = Date()) -> Bool {
        guard let restartedAt = restartTimestamp else { return false }
        guard segmentsFinalizedSinceRestart > 0 else { return false }
        guard now.timeIntervalSince(restartedAt) >= Self.resetStabilitySeconds else {
            return false
        }
        attempts = 0
        lastErrorCode = nil
        return true
    }

    // MARK: - Helpers

    /// Compute the delay for a given attempt number (1-indexed).
    private static func delay(forAttempt attempt: Int) -> Duration {
        let idx = attempt - 1
        let seconds: Int
        if idx >= 0 && idx < curveSeconds.count {
            seconds = curveSeconds[idx]
        } else {
            seconds = capSeconds
        }
        return .seconds(seconds)
    }
}
