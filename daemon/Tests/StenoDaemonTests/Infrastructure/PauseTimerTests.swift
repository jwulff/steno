import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U10's `PauseTimer` — the wall-clock-based timer that drives
/// auto-resume from a hard pause. Uses `DispatchSourceTimer` with
/// `schedule(wallDeadline:)` so the timer survives system sleep.
///
/// We can't actually sleep the laptop in tests, but the wall-clock
/// semantics are still verifiable: arming at `now + Xms` MUST fire within
/// tolerance, cancelling MUST suppress the firing, and re-arming MUST
/// drop the prior deadline.
@Suite("PauseTimer Tests (U10)")
struct PauseTimerTests {

    @Test("arm fires at the configured deadline within tolerance")
    func armFiresAtDeadline() async throws {
        let timer = PauseTimer()
        let fired = AsyncFlag()

        let deadline = Date().addingTimeInterval(0.150) // 150ms ahead
        timer.arm(at: deadline) {
            Task { await fired.signal() }
        }

        let didFire = await fired.wait(timeout: .seconds(2))
        #expect(didFire)
        #expect(!timer.isArmed())
    }

    @Test("cancel before fire suppresses the closure")
    func cancelSuppressesFire() async throws {
        let timer = PauseTimer()
        let fired = AsyncFlag()

        timer.arm(at: Date().addingTimeInterval(0.500)) {
            Task { await fired.signal() }
        }
        // Cancel well before the deadline.
        try await Task.sleep(for: .milliseconds(50))
        timer.cancel()

        // Wait past the original deadline to make sure nothing fires.
        let didFire = await fired.wait(timeout: .milliseconds(750))
        #expect(!didFire)
        #expect(!timer.isArmed())
    }

    @Test("re-arm replaces the prior deadline (only the new one fires)")
    func reArmReplacesPriorDeadline() async throws {
        let timer = PauseTimer()
        let firstFired = AsyncFlag()
        let secondFired = AsyncFlag()

        timer.arm(at: Date().addingTimeInterval(0.300)) {
            Task { await firstFired.signal() }
        }
        // Re-arm well before the first deadline lands.
        try await Task.sleep(for: .milliseconds(50))
        timer.arm(at: Date().addingTimeInterval(0.150)) {
            Task { await secondFired.signal() }
        }

        let secondDidFire = await secondFired.wait(timeout: .milliseconds(750))
        #expect(secondDidFire)

        // The first deadline (300ms) must not fire even after we wait past it.
        let firstDidFire = await firstFired.wait(timeout: .milliseconds(400))
        #expect(!firstDidFire)
    }

    @Test("currentDeadline reports the armed time")
    func currentDeadlineReportsArmedTime() {
        let timer = PauseTimer()
        #expect(timer.currentDeadline == nil)

        let deadline = Date().addingTimeInterval(60)
        timer.arm(at: deadline) { }
        // Allow some tolerance — the timer might re-create the wall-time
        // and a hair of drift is OK at the second granularity.
        if let actual = timer.currentDeadline {
            let drift = abs(actual.timeIntervalSince(deadline))
            #expect(drift < 1.0)
        } else {
            Issue.record("currentDeadline should be set after arm")
        }

        timer.cancel()
        #expect(timer.currentDeadline == nil)
    }

    @Test("arm at a past deadline fires immediately")
    func pastDeadlineFiresImmediately() async throws {
        let timer = PauseTimer()
        let fired = AsyncFlag()

        // Deadline already passed — DispatchWallTime semantics fire ASAP.
        timer.arm(at: Date().addingTimeInterval(-1.0)) {
            Task { await fired.signal() }
        }

        let didFire = await fired.wait(timeout: .seconds(1))
        #expect(didFire)
    }
}

// MARK: - Test helper: AsyncFlag

/// One-shot flag used by the tests above to await a closure-driven signal
/// without polling. `signal()` flips the flag; `wait(timeout:)` returns
/// `true` if it was flipped within the budget, `false` otherwise.
actor AsyncFlag {
    private var fired: Bool = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func signal() {
        fired = true
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.resume(returning: true)
        }
    }

    func wait(timeout: Duration) async -> Bool {
        if fired { return true }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
            Task {
                try? await Task.sleep(for: timeout)
                await self.timeoutFire()
            }
        }
    }

    private func timeoutFire() {
        guard !fired, !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.resume(returning: false)
        }
    }
}
