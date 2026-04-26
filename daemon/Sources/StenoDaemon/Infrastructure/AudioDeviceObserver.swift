@preconcurrency import AVFoundation
import Foundation

// MARK: - AudioDeviceEventTarget

/// Receiver of debounced AVAudioEngine configuration-change events.
///
/// `RecordingEngine` is the production target — when the observer
/// resolves the post-debounce device UID, it trampolines into
/// `engine.handleAudioDeviceChange(deviceUID:format:)` to drive the
/// mic-pipeline restart and the heal-rule decision.
public protocol AudioDeviceEventTarget: AnyObject, Sendable {
    /// Invoked once per debounced burst of
    /// `AVAudioEngine.configurationChangeNotification` events. The
    /// observer reads the current default-input device UID at the
    /// trailing edge of the debounce window (so callbacks see the
    /// stable post-renegotiation state, not the in-flight state).
    func audioConfigurationChanged(deviceUID: String?, format: AVAudioFormat?) async
}

// MARK: - ConfigurationChangeSubscribing

/// Closure invoked by the underlying notifier whenever
/// `AVAudioEngine.configurationChangeNotification` fires. The observer
/// installs one of these and uses it to drive the debounce timer.
public typealias ConfigurationChangeHandler = @Sendable () -> Void

/// Abstraction over `NotificationCenter.default` subscription to
/// `AVAudioEngine.configurationChangeNotification`. Production uses
/// `NotificationCenterAudioConfig` (which subscribes to
/// `NotificationCenter.default`); tests inject `MockConfigurationChangeNotifier`
/// to fire synthetic notifications without an actual AVAudioEngine.
public protocol ConfigurationChangeSubscribing: AnyObject, Sendable {
    /// Begin observing. The handler is invoked synchronously on the
    /// notification dispatch queue (NotificationCenter does not hop
    /// queues by default).
    func subscribe(handler: @escaping ConfigurationChangeHandler)

    /// Stop observing.
    func unsubscribe()
}

// MARK: - Production notifier

/// Production `ConfigurationChangeSubscribing` backed by
/// `NotificationCenter.default` and
/// `AVAudioEngine.configurationChangeNotification`.
///
/// Per Apple's documentation, the engine has already stopped by the
/// time this notification arrives — the AudioDeviceObserver does NOT
/// attempt to interrogate the engine in the handler; instead it
/// trampolines the post-debounce decision back to RecordingEngine,
/// which rebuilds via the U5 restart machinery.
public final class NotificationCenterAudioConfig: ConfigurationChangeSubscribing, @unchecked Sendable {

    private let lock = NSLock()
    private var token: NSObjectProtocol?

    public init() {}

    deinit {
        unsubscribe()
    }

    public func subscribe(handler: @escaping ConfigurationChangeHandler) {
        lock.lock(); defer { lock.unlock() }
        // If a previous subscription is live, drop it before replacing.
        if let existing = token {
            NotificationCenter.default.removeObserver(existing)
            token = nil
        }
        token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { _ in
            handler()
        }
    }

    public func unsubscribe() {
        lock.lock(); defer { lock.unlock() }
        if let existing = token {
            NotificationCenter.default.removeObserver(existing)
            token = nil
        }
    }
}

// MARK: - Mock notifier (test seam)

/// Test-mock notifier that fires synthetic configuration-change
/// notifications on demand. Lives in production code so test targets
/// can compose against it without a separate mocks module.
public final class MockConfigurationChangeNotifier: ConfigurationChangeSubscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ConfigurationChangeHandler?

    public init() {}

    public func subscribe(handler: @escaping ConfigurationChangeHandler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func unsubscribe() {
        lock.lock(); defer { lock.unlock() }
        self.handler = nil
    }

    /// Fire a synthetic notification.
    public func fire() {
        let h: ConfigurationChangeHandler? = {
            lock.lock(); defer { lock.unlock() }
            return handler
        }()
        h?()
    }
}

// MARK: - Observer

/// Observes `AVAudioEngine.configurationChangeNotification` and
/// trampolines debounced events into a `AudioDeviceEventTarget`
/// (typically `RecordingEngine`).
///
/// **Debounce strategy (250ms trailing-edge):** Bluetooth renegotiation
/// produces bursts of 2–3 notifications within a few hundred
/// milliseconds. We collapse these to a single trailing-edge fire so
/// the target only does the rebuild once, against the stable
/// post-renegotiation device state.
///
/// The current default-input device UID is looked up via
/// `defaultInputDeviceUID()` (Core Audio HAL) at the trailing edge —
/// after the debounce window settles — so the target receives the
/// post-renegotiation device state.
public final class AudioDeviceObserver: @unchecked Sendable {

    // MARK: - Dependencies

    private let notifier: any ConfigurationChangeSubscribing
    private let debounceWindow: TimeInterval
    private let deviceUIDProvider: @Sendable () -> String?
    /// Resolves the engine's current mic format at the trailing edge
    /// of the debounce window. Async so production can `await`
    /// `RecordingEngine.currentMicFormat()` (the engine is an actor).
    /// Tests pass a synchronous wrapper. See PR #35 review (issue 5).
    private let formatProvider: @Sendable () async -> AVAudioFormat?

    /// Serial queue that owns the debounce timer state. All
    /// `pending`/`fireAt` mutations happen on this queue so the
    /// debounce machinery is race-safe.
    private let debounceQueue: DispatchQueue

    // MARK: - State (debounce-queue isolated)

    private let stateLock = NSLock()
    private var _target: (any AudioDeviceEventTarget)?
    private var _started: Bool = false
    /// Generation counter — bumped on each new notification arrival
    /// AND on `stop()`. The trailing-edge dispatch checks against the
    /// snapshot it captured at scheduling time and bails if the
    /// generation has advanced (newer notification arrived) or if
    /// observer has been stopped. This counter alone is sufficient
    /// for burst collapsing: every notification within the debounce
    /// window dispatches its own trailing-edge check, but only the
    /// most recent one's captured generation matches the live
    /// counter, so the rest bail. (Earlier code carried a
    /// `pendingScheduled` flag for this purpose; it was never
    /// read or written and has been removed — see PR #35 review
    /// (issue 7).)
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - notifier: The subscribing notifier. Production passes
    ///     `NotificationCenterAudioConfig()`; tests pass a
    ///     `MockConfigurationChangeNotifier`.
    ///   - debounceWindow: Trailing-edge debounce window in seconds.
    ///     Default 0.25s (250ms) per the plan's "Key Technical
    ///     Decisions" — Bluetooth renegotiation produces ~2–3
    ///     notifications within this window.
    ///   - deviceUIDProvider: Closure resolving the current default-
    ///     input device UID. Production passes
    ///     `defaultInputDeviceUID()` from `CoreAudioDevice.swift`;
    ///     tests inject a synthetic provider that simulates AirPods
    ///     disconnect, USB unplug, etc.
    ///   - formatProvider: Closure resolving the active mic format,
    ///     captured from `MicrophoneAudioSource.currentFormat()`.
    ///     Tests inject synthetic formats to simulate sample-rate
    ///     swaps (16kHz → 48kHz on AirPods → BuiltInMic).
    public init(
        notifier: any ConfigurationChangeSubscribing = NotificationCenterAudioConfig(),
        debounceWindow: TimeInterval = 0.25,
        deviceUIDProvider: @Sendable @escaping () -> String? = { defaultInputDeviceUID() },
        formatProvider: @Sendable @escaping () async -> AVAudioFormat? = { nil }
    ) {
        self.notifier = notifier
        self.debounceWindow = debounceWindow
        self.deviceUIDProvider = deviceUIDProvider
        self.formatProvider = formatProvider
        self.debounceQueue = DispatchQueue(
            label: "com.steno.audio-device-observer.debounce",
            qos: .userInitiated
        )
    }

    deinit {
        notifier.unsubscribe()
    }

    /// Begin observing configuration-change events for the given
    /// target. The observer keeps a strong reference to the target
    /// until `stop()` is called.
    public func start(target: any AudioDeviceEventTarget) throws {
        stateLock.lock()
        guard !_started else {
            stateLock.unlock()
            return
        }
        _target = target
        _started = true
        stateLock.unlock()

        let weakSelfBox = WeakSelfBox(self)
        notifier.subscribe { [weakSelfBox] in
            guard let observer = weakSelfBox.value else { return }
            observer.scheduleTrailingFire()
        }
    }

    /// Stop observing. After this call, any in-flight debounce timer
    /// is invalidated (the trailing-edge check sees the bumped
    /// generation and bails).
    public func stop() {
        stateLock.lock()
        _target = nil
        _started = false
        // Bump the generation so any pending trailing-edge fire bails.
        generation &+= 1
        stateLock.unlock()
        notifier.unsubscribe()
    }

    // MARK: - Debounce

    /// Called from the notifier's handler. Bumps the generation and
    /// schedules a trailing-edge fire `debounceWindow` seconds from
    /// now. If a trailing-edge fire is already pending, we just bump
    /// the generation; the existing dispatched closure will bail
    /// (because its captured generation is now stale) and the new
    /// schedule below will own the trailing edge.
    private func scheduleTrailingFire() {
        let scheduledGen: UInt64 = {
            stateLock.lock(); defer { stateLock.unlock() }
            generation &+= 1
            return generation
        }()

        let window = debounceWindow
        let weakSelf = WeakSelfBox(self)

        debounceQueue.asyncAfter(deadline: .now() + window) { [weakSelf, scheduledGen] in
            guard let observer = weakSelf.value else { return }
            observer.fireIfStillCurrent(scheduledGen: scheduledGen)
        }
    }

    /// Trailing-edge dispatch. Bails if the captured generation is
    /// stale (a newer notification arrived) or if the observer has
    /// been stopped. Otherwise reads the current default-input device
    /// UID + format and trampolines into the target.
    private func fireIfStillCurrent(scheduledGen: UInt64) {
        let (target, isCurrent): (AudioDeviceEventTarget?, Bool) = {
            stateLock.lock(); defer { stateLock.unlock() }
            guard _started else { return (nil, false) }
            return (_target, scheduledGen == generation)
        }()

        guard isCurrent, let target else { return }

        // Resolve at the trailing edge — this is the load-bearing
        // detail. By the time we read it here, the BT renegotiation
        // burst has settled and the HAL reports the stable
        // post-change device. UID is sync (Core Audio HAL); format
        // requires `await` because production threads it through
        // `RecordingEngine.currentMicFormat()` on an actor.
        let deviceUID = deviceUIDProvider()
        let provideFormat = formatProvider

        Task {
            let format = await provideFormat()
            await target.audioConfigurationChanged(deviceUID: deviceUID, format: format)
        }
    }

    // MARK: - WeakSelfBox

    /// Holds a weak reference to the observer so the notifier closure
    /// does not retain `self`. (The observer's lifetime is owned by
    /// the daemon's RunCommand.)
    private final class WeakSelfBox: @unchecked Sendable {
        weak var value: AudioDeviceObserver?
        init(_ value: AudioDeviceObserver) { self.value = value }
    }
}
