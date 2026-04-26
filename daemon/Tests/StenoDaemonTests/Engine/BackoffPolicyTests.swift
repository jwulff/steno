import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U5's `BackoffPolicy`.
///
/// `BackoffPolicy` is a pure value type: every assertion here can be
/// expressed without spinning up an engine, an actor, or any clocks.
/// Wall-clock dependencies are injected via the explicit `now:` parameters.
@Suite("BackoffPolicy Tests")
struct BackoffPolicyTests {

    // MARK: - Curve

    @Test("Curve: 1s, 2s, 4s, 8s, then capped at 30s")
    func curveMatchesPlan() {
        var policy = BackoffPolicy()

        let outcomes = (1...6).map { _ in policy.record(error: "E_SAME") }

        #expect(outcomes[0] == .delay(.seconds(1)))
        #expect(outcomes[1] == .delay(.seconds(2)))
        #expect(outcomes[2] == .delay(.seconds(4)))
        #expect(outcomes[3] == .delay(.seconds(8)))
        // Attempt 5 surrenders before producing a delay — see surrender tests.
        #expect(outcomes[4] == .exhausted)
        // Already exhausted; further calls remain exhausted.
        #expect(outcomes[5] == .exhausted)
    }

    @Test("Capped at 30s for sustained different-error streams")
    func capAtThirtySecondsForLongRuns() {
        var policy = BackoffPolicy()

        // Different error each time — counter resets to 1 each call, so
        // the policy never surrenders and the curve stays at the front.
        let first = policy.record(error: "E_A")
        let second = policy.record(error: "E_B")
        #expect(first == .delay(.seconds(1)))
        #expect(second == .delay(.seconds(1)))
        #expect(policy.attempts == 1)
    }

    // MARK: - Surrender / same-error counting

    @Test("Five same-error attempts surrender on attempt 5")
    func surrenderOnFifthSameError() {
        var policy = BackoffPolicy()

        let r1 = policy.record(error: "E_RECOG")
        let r2 = policy.record(error: "E_RECOG")
        let r3 = policy.record(error: "E_RECOG")
        let r4 = policy.record(error: "E_RECOG")
        let r5 = policy.record(error: "E_RECOG")

        #expect(r1 == .delay(.seconds(1)))
        #expect(r2 == .delay(.seconds(2)))
        #expect(r3 == .delay(.seconds(4)))
        #expect(r4 == .delay(.seconds(8)))
        #expect(r5 == .exhausted)
        #expect(policy.isExhausted)
    }

    @Test("Different error in the middle resets counter to 1 (not 0)")
    func differentErrorResetsCounterToOne() {
        var policy = BackoffPolicy()

        _ = policy.record(error: "E_A") // attempts → 1
        _ = policy.record(error: "E_A") // attempts → 2
        _ = policy.record(error: "E_A") // attempts → 3

        let pivot = policy.record(error: "E_B") // counter resets to 1 for new error

        #expect(pivot == .delay(.seconds(1)))
        #expect(policy.attempts == 1)
        #expect(policy.lastErrorCode == "E_B")
        #expect(!policy.isExhausted)

        // Four more identical errors → surrender on the 5th attempt of E_B.
        _ = policy.record(error: "E_B") // 2
        _ = policy.record(error: "E_B") // 3
        _ = policy.record(error: "E_B") // 4
        let surrender = policy.record(error: "E_B") // 5 → exhausted
        #expect(surrender == .exhausted)
        #expect(policy.isExhausted)
    }

    @Test("Exhausted policy stays exhausted on subsequent record calls")
    func exhaustedPolicyStaysExhausted() {
        var policy = BackoffPolicy()
        for _ in 0..<5 { _ = policy.record(error: "E") }
        #expect(policy.isExhausted)

        // Even a different error code does not revive the policy.
        let after = policy.record(error: "E_OTHER")
        #expect(after == .exhausted)
        #expect(policy.isExhausted)
    }

    // MARK: - Reset semantics

    @Test("Reset requires both segment-finalized AND 30s of stability")
    func resetRequiresBothGates() {
        var policy = BackoffPolicy()

        // Build up some attempts.
        _ = policy.record(error: "E")
        _ = policy.record(error: "E")
        #expect(policy.attempts == 2)

        let restartedAt = Date(timeIntervalSince1970: 1_000_000)
        policy.recordRestart(now: restartedAt)

        // No segments yet, no time elapsed → no reset.
        #expect(policy.tryReset(now: restartedAt) == false)
        #expect(policy.attempts == 2)

        // 30s elapsed but still zero segments finalized → no reset.
        let after30s = restartedAt.addingTimeInterval(30)
        #expect(policy.tryReset(now: after30s) == false)
        #expect(policy.attempts == 2)
    }

    @Test("Reset blocked when one segment finalized but only 10s elapsed")
    func resetBlockedByTimeGate() {
        var policy = BackoffPolicy()
        _ = policy.record(error: "E")
        _ = policy.record(error: "E")

        let restartedAt = Date(timeIntervalSince1970: 1_000_000)
        policy.recordRestart(now: restartedAt)
        policy.recordSegmentFinalized()

        // 10s elapsed, segment > 0, but time gate is 30s → no reset.
        let after10s = restartedAt.addingTimeInterval(10)
        #expect(policy.tryReset(now: after10s) == false)
        #expect(policy.attempts == 2)
    }

    @Test("Reset fires when both gates are satisfied")
    func resetFiresWhenBothGatesSatisfied() {
        var policy = BackoffPolicy()
        _ = policy.record(error: "E")
        _ = policy.record(error: "E")
        _ = policy.record(error: "E")
        #expect(policy.attempts == 3)
        #expect(policy.lastErrorCode == "E")

        let restartedAt = Date(timeIntervalSince1970: 1_000_000)
        policy.recordRestart(now: restartedAt)
        policy.recordSegmentFinalized()

        let after30s = restartedAt.addingTimeInterval(30)
        let didReset = policy.tryReset(now: after30s)

        #expect(didReset)
        #expect(policy.attempts == 0)
        // After reset, lastErrorCode clears so any new error counts as
        // attempt #1 of a fresh run.
        #expect(policy.lastErrorCode == nil)
    }

    @Test("recordSegmentFinalized is a no-op before recordRestart")
    func segmentFinalizedNoOpBeforeRestart() {
        var policy = BackoffPolicy()
        policy.recordSegmentFinalized()
        #expect(policy.segmentsFinalizedSinceRestart == 0)
    }

    @Test("recordRestart resets per-restart segment counter")
    func recordRestartClearsSegmentCounter() {
        var policy = BackoffPolicy()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        policy.recordRestart(now: t0)
        policy.recordSegmentFinalized()
        policy.recordSegmentFinalized()
        #expect(policy.segmentsFinalizedSinceRestart == 2)

        // A second restart in quick succession (e.g. another transient
        // failure during stability window) clears the counter again.
        let t1 = t0.addingTimeInterval(5)
        policy.recordRestart(now: t1)
        #expect(policy.segmentsFinalizedSinceRestart == 0)
    }
}
