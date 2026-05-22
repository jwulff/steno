import CoreGraphics
import Foundation

// MARK: - DisplayEventTarget

/// Receiver of debounced "a display became available" events.
///
/// `RecordingEngine` is the production target — when the observer
/// resolves the post-debounce display state and at least one display
/// is online, it trampolines into `engine.handleDisplayBecameAvailable()`
/// which re-arms a parked sys pipeline (see #42).
public protocol DisplayEventTarget: AnyObject, Sendable {
    /// Invoked once per debounced burst of display-reconfiguration
    /// events *iff* the trailing-edge presence check reports at least
    /// one online display. Detach-only bursts (lid close, monitor
    /// unplug) deliberately do NOT call this — there's nothing to
    /// re-arm against.
    func displayBecameAvailable() async
}

// MARK: - DisplayChangeSubscribing

/// Closure invoked by the underlying notifier when a display
/// reconfiguration event fires.
public typealias DisplayChangeHandler = @Sendable () -> Void

/// Abstraction over `CGDisplayRegisterReconfigurationCallback`.
/// Production uses `CGDisplayReconfigSubscriber`; tests inject
/// `MockDisplayChangeNotifier` to fire synthetic notifications without
/// actually reconfiguring displays.
public protocol DisplayChangeSubscribing: AnyObject, Sendable {
    /// Begin observing. The handler may fire on a Core Graphics
    /// internal queue — the observer trampolines all decisions onto
    /// its own debounce queue.
    func subscribe(handler: @escaping DisplayChangeHandler)

    /// Stop observing.
    func unsubscribe()
}

// MARK: - Production CG callback bridge

/// Per-subscriber handler state. Lives behind an `Unmanaged` pointer
/// passed as `userInfo` to `CGDisplayRegisterReconfigurationCallback`,
/// so each `CGDisplayReconfigSubscriber` resolves its own handler from
/// the C callback. Avoids the global singleton trap where a second
/// subscriber would silently steal callbacks from the first (PR #43
/// review).
private final class _DisplayReconfigHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: DisplayChangeHandler?

    func setHandler(_ h: DisplayChangeHandler?) {
        lock.lock(); defer { lock.unlock() }
        handler = h
    }

    func fire() {
        let h: DisplayChangeHandler? = {
            lock.lock(); defer { lock.unlock() }
            return handler
        }()
        h?()
    }
}

/// Top-level C-callable bridge. Must be a top-level function so Swift
/// can synthesize the `@convention(c)` pointer.
///
/// Core Graphics fires this callback twice per reconfiguration — once
/// with `.beginConfigurationFlag` set, once at completion. We forward
/// both to the per-subscriber box; the trailing-edge debounce in
/// `DisplayObserver` collapses the pair into a single fire.
private func _displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let box = Unmanaged<_DisplayReconfigHandlerBox>.fromOpaque(userInfo).takeUnretainedValue()
    box.fire()
}

/// Thrown by `CGDisplayReconfigSubscriber.subscribe(handler:)` when
/// Core Graphics rejects the callback registration. Surfaces up to
/// `DisplayObserver.start(target:)`, which can decide whether the
/// daemon proceeds without display-reconfig observation.
public struct CGDisplayReconfigSubscribeError: Error, Equatable, Sendable {
    public let cgErrorRawValue: Int32
    public init(_ cgError: CGError) {
        self.cgErrorRawValue = cgError.rawValue
    }
}

/// Production `DisplayChangeSubscribing` backed by
/// `CGDisplayRegisterReconfigurationCallback`. Works in headless CLI
/// processes (the daemon has no `NSApplication`) where AppKit's
/// `NSApplication.didChangeScreenParametersNotification` would never
/// fire.
public final class CGDisplayReconfigSubscriber: DisplayChangeSubscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var registered: Bool = false
    /// Per-instance box held strongly so the `Unmanaged.passUnretained`
    /// pointer we pass to Core Graphics remains valid for the
    /// subscription's lifetime. Released in `unsubscribe()` once Core
    /// Graphics confirms the callback was removed.
    private var handlerBox: _DisplayReconfigHandlerBox?

    public init() {}

    deinit {
        // Best-effort: clear our registration so the daemon doesn't
        // leak a callback into a freed box on shutdown. We swallow
        // errors here because there's no caller to propagate to.
        try? subscribeOrUnsubscribeLocked(handler: nil)
    }

    public func subscribe(handler: @escaping DisplayChangeHandler) {
        // The protocol method does not throw — callers that need to
        // observe registration failures use `DisplayObserver.start`,
        // which calls `subscribeThrowing` below. The non-throwing
        // entry point is here to preserve the protocol contract; on
        // CG registration failure it logs and leaves `registered`
        // false so a future `subscribe` retry can attempt again.
        do {
            try subscribeThrowing(handler: handler)
        } catch let err as CGDisplayReconfigSubscribeError {
            // Best-effort log. The daemon's structured logger isn't
            // wired into Infrastructure types, so use `FileHandle`.
            let message = "DisplayObserver: CGDisplayRegisterReconfigurationCallback " +
                "failed (CGError raw=\(err.cgErrorRawValue)); display-reconfig events will not fire"
            FileHandle.standardError.write(Data((message + "\n").utf8))
        } catch {
            // Future-proofing: no other error types today, but log so
            // we don't silently regress.
            let message = "DisplayObserver: subscribe failed: \(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }

    /// Throwing variant that surfaces `CGDisplayReconfigSubscribeError`
    /// when Core Graphics rejects the callback registration. Used by
    /// the throwing constructor path; the protocol's non-throwing
    /// `subscribe(handler:)` wraps this and logs.
    public func subscribeThrowing(handler: @escaping DisplayChangeHandler) throws {
        try subscribeOrUnsubscribeLocked(handler: handler)
    }

    public func unsubscribe() {
        try? subscribeOrUnsubscribeLocked(handler: nil)
    }

    private func subscribeOrUnsubscribeLocked(handler: DisplayChangeHandler?) throws {
        lock.lock(); defer { lock.unlock() }

        if let handler {
            // Swap or install the handler.
            if registered, let existing = handlerBox {
                // Already registered with CG; just update the per-box
                // handler. New events will route to the new closure.
                existing.setHandler(handler)
                return
            }
            // Fresh registration.
            let box = _DisplayReconfigHandlerBox()
            box.setHandler(handler)
            let userInfo = Unmanaged.passUnretained(box).toOpaque()
            let result = CGDisplayRegisterReconfigurationCallback(_displayReconfigCallback, userInfo)
            if result != .success {
                throw CGDisplayReconfigSubscribeError(result)
            }
            self.handlerBox = box
            self.registered = true
            return
        }

        // Tear down.
        guard registered, let existing = handlerBox else { return }
        let userInfo = Unmanaged.passUnretained(existing).toOpaque()
        existing.setHandler(nil)
        let result = CGDisplayRemoveReconfigurationCallback(_displayReconfigCallback, userInfo)
        // Even on a non-success teardown we drop our refs — there's
        // nothing constructive to do with the error at process scope.
        if result != .success {
            let message = "DisplayObserver: CGDisplayRemoveReconfigurationCallback " +
                "returned non-success (raw=\(result.rawValue)); proceeding anyway"
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
        self.handlerBox = nil
        self.registered = false
    }
}

// MARK: - Mock notifier (test seam)

/// Test-mock notifier that fires synthetic display-reconfiguration
/// events on demand. Mirrors `MockConfigurationChangeNotifier` so
/// `DisplayObserver` tests look like `AudioDeviceObserver` tests.
public final class MockDisplayChangeNotifier: DisplayChangeSubscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: DisplayChangeHandler?

    public init() {}

    public func subscribe(handler: @escaping DisplayChangeHandler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func unsubscribe() {
        lock.lock(); defer { lock.unlock() }
        self.handler = nil
    }

    /// Fire a synthetic display-reconfiguration event.
    public func fire() {
        let h: DisplayChangeHandler? = {
            lock.lock(); defer { lock.unlock() }
            return handler
        }()
        h?()
    }
}

// MARK: - Display-presence provider (production)

/// Returns `true` iff at least one display is reported online by Core
/// Graphics. Used as the production `displayPresenceProvider` for
/// `DisplayObserver` so a detach-only event (lid close, monitor
/// unplug → final count 0) does NOT re-arm the sys pipeline.
///
/// We probe `CGGetOnlineDisplayList` with a single zero-length call
/// to retrieve the count; that variant returns the active display
/// count without allocating an output array.
@Sendable
public func anyOnlineDisplay() -> Bool {
    var count: UInt32 = 0
    let err = CGGetOnlineDisplayList(0, nil, &count)
    return err == .success && count > 0
}

// MARK: - Observer

/// Observes `CGDisplayRegisterReconfigurationCallback` events and
/// trampolines debounced "display became available" events into a
/// `DisplayEventTarget` (typically `RecordingEngine`).
///
/// **Debounce strategy (250ms trailing-edge):** Display
/// reconfiguration fires a paired begin/complete callback per change,
/// and lid-open + auto-detect-and-extend bursts often produce 3–4
/// callbacks within a few hundred milliseconds. We collapse these to a
/// single trailing-edge fire so the target only re-arms once, against
/// the stable post-reconfiguration display state.
///
/// **Presence gating:** at the trailing edge the observer calls
/// `displayPresenceProvider()` — if no displays are online (lid
/// close, all monitors unplugged), the target is NOT notified. This
/// keeps the "park" state stable across detach-only events.
public final class DisplayObserver: @unchecked Sendable {

    // MARK: - Dependencies

    private let notifier: any DisplayChangeSubscribing
    private let debounceWindow: TimeInterval
    private let displayPresenceProvider: @Sendable () -> Bool

    private let debounceQueue: DispatchQueue

    // MARK: - State (lock-protected)

    private let stateLock = NSLock()
    private var _target: (any DisplayEventTarget)?
    private var _started: Bool = false
    /// Generation counter — same shape as `AudioDeviceObserver`. Bumped
    /// on each new notification arrival AND on `stop()`. Trailing-edge
    /// fires check their captured snapshot against the live counter
    /// and bail if it advanced.
    private var generation: UInt64 = 0

    /// - Parameters:
    ///   - notifier: The subscribing notifier. Production passes
    ///     `CGDisplayReconfigSubscriber()`; tests pass a
    ///     `MockDisplayChangeNotifier`.
    ///   - debounceWindow: Trailing-edge debounce window in seconds.
    ///     Default 0.25s mirrors `AudioDeviceObserver`'s window —
    ///     long enough to collapse the paired begin/complete callbacks
    ///     plus auto-detect-and-extend bursts, short enough that
    ///     users don't perceive the delay.
    ///   - displayPresenceProvider: Closure resolving whether any
    ///     display is currently online. Production passes
    ///     `anyOnlineDisplay`; tests inject synthetic flips to
    ///     simulate attach / detach.
    public init(
        notifier: any DisplayChangeSubscribing = CGDisplayReconfigSubscriber(),
        debounceWindow: TimeInterval = 0.25,
        displayPresenceProvider: @Sendable @escaping () -> Bool = { anyOnlineDisplay() }
    ) {
        self.notifier = notifier
        self.debounceWindow = debounceWindow
        self.displayPresenceProvider = displayPresenceProvider
        self.debounceQueue = DispatchQueue(
            label: "com.steno.display-observer.debounce",
            qos: .userInitiated
        )
    }

    deinit {
        notifier.unsubscribe()
    }

    /// Begin observing display-reconfiguration events for the given
    /// target. The observer keeps a strong reference to the target
    /// until `stop()` is called.
    public func start(target: any DisplayEventTarget) throws {
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
        generation &+= 1
        stateLock.unlock()
        notifier.unsubscribe()
    }

    // MARK: - Debounce

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

    private func fireIfStillCurrent(scheduledGen: UInt64) {
        let (target, isCurrent): (DisplayEventTarget?, Bool) = {
            stateLock.lock(); defer { stateLock.unlock() }
            guard _started else { return (nil, false) }
            return (_target, scheduledGen == generation)
        }()

        guard isCurrent, let target else { return }

        // Presence gate — only fire if a display is actually attached.
        // Detach-only events deliberately do not re-arm a parked sys
        // pipeline (there's nothing to attach to).
        guard displayPresenceProvider() else { return }

        Task {
            await target.displayBecameAvailable()
        }
    }

    // MARK: - WeakSelfBox

    private final class WeakSelfBox: @unchecked Sendable {
        weak var value: DisplayObserver?
        init(_ value: DisplayObserver) { self.value = value }
    }
}
