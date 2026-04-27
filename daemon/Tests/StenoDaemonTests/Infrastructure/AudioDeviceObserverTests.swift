import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import StenoDaemon

/// Tests for U7's `AudioDeviceObserver`.
///
/// We don't actually plug/unplug devices in tests. Instead, the
/// `AVAudioEngine.configurationChangeNotification` subscription is
/// abstracted behind `ConfigurationChangeSubscribing`, which lets
/// tests fire synthetic notifications via
/// `MockConfigurationChangeNotifier.fire()` against the same dispatch
/// path the production observer uses.
@Suite("AudioDeviceObserver Tests (U7)")
struct AudioDeviceObserverTests {

    // MARK: - Mock target

    /// Records the sequence of `audioConfigurationChanged(...)` calls
    /// the observer drives. Each call captures the deviceUID + format
    /// the observer resolved at the trailing edge of the debounce
    /// window.
    actor MockAudioDeviceTarget: AudioDeviceEventTarget {
        struct Call: Sendable {
            let deviceUID: String?
            let sampleRate: Double?
            let timestamp: Date
        }

        private(set) var calls: [Call] = []

        nonisolated func audioConfigurationChanged(deviceUID: String?, format: AVAudioFormat?) async {
            await record(deviceUID: deviceUID, format: format)
        }

        private func record(deviceUID: String?, format: AVAudioFormat?) {
            calls.append(Call(
                deviceUID: deviceUID,
                sampleRate: format?.sampleRate,
                timestamp: Date()
            ))
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

    private func makeFormat(sampleRate: Double) -> AVAudioFormat {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Single notification → debounce → fire

    @Test("Single notification fires the target once after debounce window")
    func singleNotificationFiresOnce() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()
        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.1,
            deviceUIDProvider: { "BuiltInMic" },
            formatProvider: { self.makeFormat(sampleRate: 48000) }
        )

        try observer.start(target: target)

        let beforeFire = Date()
        mock.fire()

        let landed = await waitFor {
            await target.calls.count == 1
        }
        #expect(landed)

        let calls = await target.calls
        #expect(calls.count == 1)
        #expect(calls.first?.deviceUID == "BuiltInMic")
        #expect(calls.first?.sampleRate == 48000)

        // The trailing-edge fire happens at LEAST debounceWindow after
        // the notification (allow a tiny slack for dispatch overhead).
        let elapsed = calls.first!.timestamp.timeIntervalSince(beforeFire)
        #expect(elapsed >= 0.09)

        observer.stop()
    }

    // MARK: - Burst collapses to single fire (250ms BT renegotiation)

    @Test("Three notifications within 200ms collapse to one fire after 250ms debounce")
    func burstCollapsesToSingleFire() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()
        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.25,
            deviceUIDProvider: { "BuiltInMic" },
            formatProvider: { self.makeFormat(sampleRate: 48000) }
        )

        try observer.start(target: target)

        // Three fires within 200ms — simulates BT renegotiation burst.
        mock.fire()
        try await Task.sleep(for: .milliseconds(50))
        mock.fire()
        try await Task.sleep(for: .milliseconds(50))
        mock.fire()

        // After the last fire, wait ~300ms (debounceWindow + slack) and
        // verify EXACTLY ONE callback landed.
        try await Task.sleep(for: .milliseconds(400))

        let calls = await target.calls
        #expect(calls.count == 1)

        observer.stop()
    }

    // MARK: - UID is read at trailing edge, not at notification time

    /// Counter that records provider invocations in a Sendable, lock-
    /// backed wrapper so the @Sendable provider closure can mutate it
    /// safely without `nonisolated(unsafe)` (which is unavailable from
    /// async contexts via NSLock).
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count: Int = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            _count += 1
            return _count
        }
    }

    @Test("Device UID is resolved at the trailing edge of the debounce window")
    func uidResolvedAtTrailingEdge() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()

        // Provider records every invocation. The observer should NOT
        // pre-resolve the UID at notification time — the resolve
        // happens once, at the trailing edge of the debounce window.
        let counter = CallCounter()
        let provider: @Sendable () -> String? = {
            let n = counter.increment()
            return n == 1 ? "first-call" : "later-call"
        }

        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.1,
            deviceUIDProvider: provider,
            formatProvider: { nil }
        )

        try observer.start(target: target)

        // Fire the notification. Provider has not been called yet —
        // the observer should not pre-resolve the UID.
        mock.fire()

        let landed = await waitFor {
            await target.calls.count == 1
        }
        #expect(landed)

        let calls = await target.calls
        // The provider is invoked exactly once (the trailing-edge
        // resolution), and the value returned ("first-call") is what
        // the target sees.
        #expect(calls.first?.deviceUID == "first-call")
        #expect(counter.count == 1)

        observer.stop()
    }

    // MARK: - stop() detaches observer

    @Test("After stop(), no further notifications drive the target")
    func stopDetachesObserver() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()
        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.05,
            deviceUIDProvider: { "BuiltInMic" },
            formatProvider: { nil }
        )
        try observer.start(target: target)

        observer.stop()

        mock.fire()

        // Give debounce window + slack to elapse.
        try await Task.sleep(for: .milliseconds(150))

        let calls = await target.calls
        #expect(calls.isEmpty)
    }

    // MARK: - In-flight burst is cancelled by stop()

    @Test("stop() during in-flight debounce cancels the trailing fire")
    func stopCancelsInFlightDebounce() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()
        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.2,
            deviceUIDProvider: { "BuiltInMic" },
            formatProvider: { nil }
        )
        try observer.start(target: target)

        mock.fire()
        // Stop immediately, well within the 200ms debounce window.
        try await Task.sleep(for: .milliseconds(50))
        observer.stop()

        // Wait past the original debounce window.
        try await Task.sleep(for: .milliseconds(300))

        let calls = await target.calls
        #expect(calls.isEmpty)
    }

    // MARK: - Multiple debounce windows fire independently

    @Test("Two non-overlapping bursts fire two callbacks")
    func twoBurstsFireTwoCallbacks() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()
        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.1,
            deviceUIDProvider: { "BuiltInMic" },
            formatProvider: { nil }
        )
        try observer.start(target: target)

        // First burst.
        mock.fire()
        // Wait > debounceWindow so the first burst settles.
        try await Task.sleep(for: .milliseconds(200))

        // Second burst.
        mock.fire()
        try await Task.sleep(for: .milliseconds(200))

        let calls = await target.calls
        #expect(calls.count == 2)

        observer.stop()
    }

    // MARK: - start() is idempotent

    @Test("Calling start() twice does not double-subscribe")
    func startIsIdempotent() async throws {
        let mock = MockConfigurationChangeNotifier()
        let target = MockAudioDeviceTarget()
        let observer = AudioDeviceObserver(
            notifier: mock,
            debounceWindow: 0.05,
            deviceUIDProvider: { "BuiltInMic" },
            formatProvider: { nil }
        )

        try observer.start(target: target)
        try observer.start(target: target) // second call should be a no-op

        mock.fire()

        let landed = await waitFor {
            await target.calls.count == 1
        }
        #expect(landed)

        // Wait past the debounce window again to confirm no second
        // callback fires.
        try await Task.sleep(for: .milliseconds(150))
        let calls = await target.calls
        #expect(calls.count == 1)

        observer.stop()
    }
}
