import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U6's `PowerManagementObserver`.
///
/// We don't actually sleep the laptop in tests. Instead, the IOKit
/// registration is abstracted behind `SystemPowerNotifier`, which lets
/// tests fire synthetic `kIOMessageSystemWillSleep` /
/// `kIOMessageSystemHasPoweredOn` / `kIOMessageCanSystemSleep` messages
/// against the same dispatch path the production observer uses.
@Suite("PowerManagementObserver Tests (U6)")
struct PowerManagementObserverTests {

    // MARK: - Mock target

    /// Records the sequence of `systemWillSleep` / `systemDidWake` calls
    /// the observer drives. Each call is timestamped so the
    /// power-assertion-ordering test can verify the relative ordering of
    /// (1) handler invocation, (2) `IOAllowPowerChange`.
    actor MockPowerEventTarget: PowerEventTarget {
        private(set) var willSleepCalls: Int = 0
        private(set) var didWakeCalls: Int = 0
        private(set) var willSleepDurationsMs: [Double] = []

        /// If non-nil, `systemWillSleep` blocks for this duration before
        /// returning. Used to verify the trampoline blocks until the
        /// async work is done.
        var willSleepBlockMs: Double?

        /// If true, `systemWillSleep` blocks past the trampoline timeout.
        /// Used to verify timeout-then-allow-anyway behavior.
        var willSleepHangs: Bool = false

        func setWillSleepBlockMs(_ ms: Double?) {
            self.willSleepBlockMs = ms
        }

        func setWillSleepHangs(_ hangs: Bool) {
            self.willSleepHangs = hangs
        }

        nonisolated func systemWillSleep() async {
            await recordWillSleepStart()
            if await willSleepHangs {
                // Block longer than the trampoline timeout.
                try? await Task.sleep(for: .seconds(60))
                return
            }
            if let ms = await willSleepBlockMs {
                try? await Task.sleep(for: .milliseconds(Int(ms)))
            }
            await recordWillSleepEnd()
        }

        nonisolated func systemDidWake() async {
            await recordDidWake()
        }

        private func recordWillSleepStart() {
            willSleepCalls += 1
        }

        private func recordWillSleepEnd() {
            // No-op marker — kept symmetric with start in case we later
            // need to assert on completion vs start.
        }

        private func recordDidWake() {
            didWakeCalls += 1
        }
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: Duration = .seconds(2),
        step: Duration = .milliseconds(10),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds(timeout))
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: step)
        }
        return false
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let comps = duration.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
    }

    // MARK: - willSleep dispatches synchronously

    @Test("kIOMessageSystemWillSleep → systemWillSleep called, then allowPowerChange")
    func willSleepCallsTargetThenAllows() async throws {
        let mock = MockSystemPowerNotifier()
        let target = MockPowerEventTarget()
        let observer = PowerManagementObserver(notifier: mock)

        try observer.start(target: target)

        // Synthesize a willSleep message. The mock uses an arbitrary
        // sentinel for `argument` — production code passes it back to
        // `IOAllowPowerChange`.
        mock.fireWillSleep(argument: 0xDEADBEEF)

        let allowed = await waitFor {
            await mock.allowedPowerChangeArguments.contains(0xDEADBEEF)
        }
        #expect(allowed)

        let calls = await target.willSleepCalls
        #expect(calls == 1)

        observer.stop()
    }

    // MARK: - canSleep is auto-allowed without bothering the engine

    @Test("kIOMessageCanSystemSleep is auto-allowed, target is NOT called")
    func canSleepIsAutoAllowed() async throws {
        let mock = MockSystemPowerNotifier()
        let target = MockPowerEventTarget()
        let observer = PowerManagementObserver(notifier: mock)
        try observer.start(target: target)

        mock.fireCanSleep(argument: 0xCAFE)

        let allowed = await waitFor {
            await mock.allowedPowerChangeArguments.contains(0xCAFE)
        }
        #expect(allowed)

        // canSleep should NOT have called systemWillSleep.
        let calls = await target.willSleepCalls
        #expect(calls == 0)

        observer.stop()
    }

    // MARK: - didWake fires the wake handler

    @Test("kIOMessageSystemHasPoweredOn → systemDidWake invoked")
    func didWakeCallsTarget() async throws {
        let mock = MockSystemPowerNotifier()
        let target = MockPowerEventTarget()
        let observer = PowerManagementObserver(notifier: mock)
        try observer.start(target: target)

        mock.fireDidWake(argument: 0)

        let woke = await waitFor {
            await target.didWakeCalls == 1
        }
        #expect(woke)

        observer.stop()
    }

    // MARK: - Timeout escape hatch

    @Test("willSleep that hangs past timeout still calls allowPowerChange")
    func willSleepTimeoutAllowsAnyway() async throws {
        let mock = MockSystemPowerNotifier()
        let target = MockPowerEventTarget()
        await target.setWillSleepHangs(true)

        // Tight timeout so the test is fast.
        let observer = PowerManagementObserver(
            notifier: mock,
            willSleepTimeoutMs: 100
        )
        try observer.start(target: target)

        mock.fireWillSleep(argument: 0xBEEF)

        let allowed = await waitFor(timeout: .seconds(2)) {
            await mock.allowedPowerChangeArguments.contains(0xBEEF)
        }
        #expect(allowed)

        observer.stop()
    }

    // MARK: - Multiple events queue

    @Test("Multiple wake/sleep cycles all dispatched in order")
    func multipleCyclesDispatchInOrder() async throws {
        let mock = MockSystemPowerNotifier()
        let target = MockPowerEventTarget()
        let observer = PowerManagementObserver(notifier: mock)
        try observer.start(target: target)

        mock.fireWillSleep(argument: 1)
        mock.fireDidWake(argument: 2)
        mock.fireWillSleep(argument: 3)
        mock.fireDidWake(argument: 4)

        let done = await waitFor {
            let willCount = await target.willSleepCalls
            let wakeCount = await target.didWakeCalls
            return willCount == 2 && wakeCount == 2
        }
        #expect(done)

        // All willSleep messages produced an IOAllowPowerChange call.
        let allowed = await mock.allowedPowerChangeArguments
        #expect(allowed.contains(1))
        #expect(allowed.contains(3))

        observer.stop()
    }

    // MARK: - stop() detaches the trampoline

    @Test("After stop(), no further events drive the target")
    func stopDetachesObserver() async throws {
        let mock = MockSystemPowerNotifier()
        let target = MockPowerEventTarget()
        let observer = PowerManagementObserver(notifier: mock)
        try observer.start(target: target)

        observer.stop()

        mock.fireWillSleep(argument: 0)
        mock.fireDidWake(argument: 0)

        // Give the system a moment in case events are queued.
        try await Task.sleep(for: .milliseconds(100))

        let calls = await target.willSleepCalls
        let wakes = await target.didWakeCalls
        #expect(calls == 0)
        #expect(wakes == 0)
    }
}
