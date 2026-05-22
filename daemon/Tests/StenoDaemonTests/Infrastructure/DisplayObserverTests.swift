import Testing
import Foundation
@testable import StenoDaemon

/// Tests for #42's `DisplayObserver`.
///
/// Mirror of `AudioDeviceObserverTests` — we do not actually
/// plug/unplug displays in tests. Instead the underlying CG
/// reconfiguration callback is abstracted behind
/// `DisplayChangeSubscribing`; tests inject
/// `MockDisplayChangeNotifier` and a controllable presence provider
/// to exercise the same dispatch path the production observer uses.
@Suite("DisplayObserver Tests (#42)")
struct DisplayObserverTests {

    // MARK: - Mock target

    /// Records the sequence of `displayBecameAvailable()` calls the
    /// observer drives. Each call captures the wall-clock time so
    /// tests can verify the trailing-edge timing.
    actor MockDisplayTarget: DisplayEventTarget {
        private(set) var callTimestamps: [Date] = []

        nonisolated func displayBecameAvailable() async {
            await record()
        }

        private func record() {
            callTimestamps.append(Date())
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

    /// Toggleable Sendable wrapper around a Bool. Lets `displayPresenceProvider`
    /// flip between "display present" and "display absent" across tests.
    final class PresenceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool
        init(_ initial: Bool) { self._value = initial }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    // MARK: - Single notification → debounce → fire (display present)

    @Test("Single notification with display present fires the target once after debounce")
    func singleNotificationFiresWhenDisplayPresent() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(true)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.1,
            displayPresenceProvider: { presence.value }
        )

        try observer.start(target: target)

        let beforeFire = Date()
        mock.fire()

        let landed = await waitFor {
            await target.callTimestamps.count == 1
        }
        #expect(landed)

        let stamps = await target.callTimestamps
        #expect(stamps.count == 1)

        // Trailing-edge fire happens at LEAST debounceWindow after the
        // notification (small slack for dispatch overhead).
        let elapsed = stamps.first!.timeIntervalSince(beforeFire)
        #expect(elapsed >= 0.09)

        observer.stop()
    }

    // MARK: - Notification while NO display attached → target NOT called

    @Test("Notification while no display is online does NOT fire the target")
    func notificationWithNoDisplayDoesNotFire() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(false) // no displays
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.05,
            displayPresenceProvider: { presence.value }
        )

        try observer.start(target: target)

        mock.fire()

        // Wait well past the debounce window — no callback should
        // arrive because the presence gate at trailing edge fails.
        try await Task.sleep(for: .milliseconds(200))

        let stamps = await target.callTimestamps
        #expect(stamps.isEmpty)

        observer.stop()
    }

    // MARK: - Attach event during a parked window

    @Test("Detach burst followed by attach burst fires exactly once (only on the attach)")
    func detachThenAttachFiresOnlyOnAttach() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(false)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.1,
            displayPresenceProvider: { presence.value }
        )

        try observer.start(target: target)

        // Detach burst: lid closes, no displays — the notification
        // fires but the presence gate blocks the trailing-edge fire.
        mock.fire()
        try await Task.sleep(for: .milliseconds(200))

        let stampsAfterDetach = await target.callTimestamps
        #expect(stampsAfterDetach.isEmpty)

        // Attach burst: monitor plugged in, presence flips true, the
        // next reconfig event fires and the observer notifies the
        // target.
        presence.value = true
        mock.fire()

        let landed = await waitFor {
            await target.callTimestamps.count == 1
        }
        #expect(landed)

        observer.stop()
    }

    // MARK: - Burst collapses to single fire

    @Test("Three notifications within 200ms collapse to one fire after 250ms debounce")
    func burstCollapsesToSingleFire() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(true)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.25,
            displayPresenceProvider: { presence.value }
        )

        try observer.start(target: target)

        // CG fires paired begin/complete callbacks plus auto-extend
        // events for a single attach — collapse them all.
        mock.fire()
        try await Task.sleep(for: .milliseconds(50))
        mock.fire()
        try await Task.sleep(for: .milliseconds(50))
        mock.fire()

        try await Task.sleep(for: .milliseconds(400))

        let stamps = await target.callTimestamps
        #expect(stamps.count == 1)

        observer.stop()
    }

    // MARK: - stop() detaches observer

    @Test("After stop(), no further notifications drive the target")
    func stopDetachesObserver() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(true)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.05,
            displayPresenceProvider: { presence.value }
        )
        try observer.start(target: target)

        observer.stop()

        mock.fire()

        try await Task.sleep(for: .milliseconds(150))

        let stamps = await target.callTimestamps
        #expect(stamps.isEmpty)
    }

    // MARK: - stop() during in-flight debounce cancels the trailing fire

    @Test("stop() during in-flight debounce cancels the trailing fire")
    func stopCancelsInFlightDebounce() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(true)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.2,
            displayPresenceProvider: { presence.value }
        )
        try observer.start(target: target)

        mock.fire()
        // Stop well within the 200ms debounce window.
        try await Task.sleep(for: .milliseconds(50))
        observer.stop()

        try await Task.sleep(for: .milliseconds(300))

        let stamps = await target.callTimestamps
        #expect(stamps.isEmpty)
    }

    // MARK: - Multiple non-overlapping bursts fire independently

    @Test("Two non-overlapping bursts fire two callbacks")
    func twoBurstsFireTwoCallbacks() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(true)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.1,
            displayPresenceProvider: { presence.value }
        )
        try observer.start(target: target)

        mock.fire()
        try await Task.sleep(for: .milliseconds(200))

        mock.fire()
        try await Task.sleep(for: .milliseconds(200))

        let stamps = await target.callTimestamps
        #expect(stamps.count == 2)

        observer.stop()
    }

    // MARK: - start() is idempotent

    @Test("Calling start() twice does not double-subscribe")
    func startIsIdempotent() async throws {
        let mock = MockDisplayChangeNotifier()
        let target = MockDisplayTarget()
        let presence = PresenceFlag(true)
        let observer = DisplayObserver(
            notifier: mock,
            debounceWindow: 0.05,
            displayPresenceProvider: { presence.value }
        )

        try observer.start(target: target)
        try observer.start(target: target) // second call should be a no-op

        mock.fire()

        let landed = await waitFor {
            await target.callTimestamps.count == 1
        }
        #expect(landed)

        try await Task.sleep(for: .milliseconds(150))
        let stamps = await target.callTimestamps
        #expect(stamps.count == 1)

        observer.stop()
    }
}
