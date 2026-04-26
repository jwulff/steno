import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - PowerEventTarget

/// Receiver of system power events from `PowerManagementObserver`. The
/// observer trampolines IOKit messages into actor-safe `async` calls on
/// this protocol, blocking the dispatch trampoline until the actor work
/// completes (with a hard timeout) so the willSleep handler honours the
/// IOKit budget.
///
/// `canSleep` is intentionally NOT on this protocol: we always allow
/// user-initiated sleep without involving the engine, since the heal
/// rule has no reason to deny it.
public protocol PowerEventTarget: AnyObject, Sendable {
    /// Called on `kIOMessageSystemWillSleep`. Implementations MUST
    /// complete pipeline drain + persistence + power-assertion release
    /// within ~30 seconds (the observer enforces a tighter timeout
    /// internally). After this returns, the observer calls
    /// `IOAllowPowerChange` so the system actually goes to sleep.
    func systemWillSleep() async

    /// Called on `kIOMessageSystemHasPoweredOn`. Implementations apply
    /// the heal rule and bring up pipelines around the surviving or
    /// fresh session.
    func systemDidWake() async
}

// MARK: - SystemPowerNotifier abstraction

/// Power-message kinds the observer dispatches on. Mirrors the IOKit
/// `kIOMessage*` constants but uses a Swift enum for switch exhaustiveness
/// in tests and at the dispatch site.
public enum PowerMessage: Sendable, Equatable {
    case canSystemSleep
    case systemWillSleep
    case systemHasPoweredOn
}

/// Closure signature the notifier invokes when an IOKit power message
/// arrives. The `argument` is the raw IOKit `messageArgument` pointer
/// value (cast to UInt) that must be passed back to `IOAllowPowerChange`
/// for `canSystemSleep` / `systemWillSleep`.
public typealias PowerMessageHandler = @Sendable (PowerMessage, UInt) -> Void

/// Abstraction over `IORegisterForSystemPower` so tests can fire
/// synthetic messages without actually sleeping the laptop. Production
/// uses `IOKitSystemPowerNotifier`; tests use `MockSystemPowerNotifier`.
public protocol SystemPowerNotifier: AnyObject, Sendable {
    /// Begin observing system power messages. The `handler` is invoked
    /// on the libdispatch main queue (or, in tests, on whichever queue
    /// the mock chooses). The implementation is responsible for
    /// retaining itself for the lifetime of the registration.
    func register(handler: @escaping PowerMessageHandler) throws

    /// Stop observing. Future synthetic / IOKit messages must NOT drive
    /// the handler.
    func unregister()

    /// Acknowledge a power-change request to IOKit. Called by the
    /// observer after the target's handler completes (or times out) on
    /// `systemWillSleep`. For `canSystemSleep` the observer also calls
    /// this directly without consulting the target.
    ///
    /// In tests, the mock records the argument so the test can assert on
    /// the (1) target ran, (2) allowPowerChange was called ordering.
    func allowPowerChange(_ argument: UInt)
}

// MARK: - Production IOKit notifier

/// Production `SystemPowerNotifier` backed by `IORegisterForSystemPower`
/// and `IONotificationPortSetDispatchQueue(port, DispatchQueue.main)`.
///
/// This is the IOKit-not-NSWorkspace branch from the plan's "Key
/// Technical Decisions" — the daemon is a launchd-managed CLI binary,
/// not an AppKit app, so we register against IOKit directly. The
/// notification port is routed through libdispatch (NOT via
/// `CFRunLoopAddSource`, which is incompatible with the daemon's
/// `dispatchMain()` runtime: the main thread is owned by libdispatch and
/// CFRunLoop sources never pump).
public final class IOKitSystemPowerNotifier: SystemPowerNotifier, @unchecked Sendable {

    /// IOKit registers a C-style callback. We trampoline through this
    /// shared box, which holds a reference back to the active handler.
    /// `fileprivate` so the C trampoline at file scope can reach it.
    fileprivate final class HandlerBox {
        var handler: PowerMessageHandler?
    }

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var handlerBox: HandlerBox?

    public init() {}

    deinit {
        unregister()
    }

    public func register(handler: @escaping PowerMessageHandler) throws {
        let box = HandlerBox()
        box.handler = handler
        self.handlerBox = box

        // The C trampoline reads the box pointer back via refCon. We
        // pass an unretained pointer because the box's retention is
        // owned by `self`, which outlives the registration as long as
        // the caller keeps a strong reference to the notifier (the
        // observer does).
        let refCon = Unmanaged.passUnretained(box).toOpaque()

        var notifierObj: io_object_t = 0
        let port = IORegisterForSystemPower(
            refCon,
            &notifyPort,
            IOKitPowerCallback,
            &notifierObj
        )

        guard port != 0, let notifyPort else {
            self.handlerBox = nil
            throw NSError(
                domain: "IOKitSystemPowerNotifier",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "IORegisterForSystemPower failed"]
            )
        }
        self.rootPort = port
        self.notifierObject = notifierObj

        // Route the notification port through libdispatch on the main
        // queue so it pumps under `dispatchMain()`. NOT CFRunLoop —
        // CFRunLoop sources never pump under a libdispatch-owned main
        // thread.
        IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)
    }

    public func unregister() {
        if notifierObject != 0 {
            IODeregisterForSystemPower(&notifierObject)
            notifierObject = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
        handlerBox = nil
    }

    public func allowPowerChange(_ argument: UInt) {
        guard rootPort != 0 else { return }
        // IOAllowPowerChange takes a raw pointer-shaped argument that was
        // delivered alongside the power message. We simply pass it back.
        IOAllowPowerChange(rootPort, Int(bitPattern: UInt(argument)))
    }

    fileprivate func dispatch(_ message: PowerMessage, argument: UInt) {
        handlerBox?.handler?(message, argument)
    }
}

/// IOKit power-message constants. These macros aren't auto-bridged into
/// Swift because they expand to `iokit_common_msg(...)`, which uses
/// `sys_iokit | sub_iokit_common | message` — values the Swift importer
/// can't statically resolve. The integer values are stable across macOS
/// releases (defined in IOKit/IOMessage.h since macOS 10.0).
///
/// `sys_iokit | sub_iokit_common = 0xE0000000`. The trailing nibble is
/// the message-specific code from IOMessage.h.
private let kIOMessageCanSystemSleepValue: UInt32 = 0xE0000270
private let kIOMessageSystemWillSleepValue: UInt32 = 0xE0000280
private let kIOMessageSystemHasPoweredOnValue: UInt32 = 0xE0000300

/// C trampoline for `IORegisterForSystemPower`. Bridges the (refCon,
/// service, type, argument) tuple into the Swift `PowerMessageHandler`.
private func IOKitPowerCallback(
    _ refCon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refCon else { return }
    let box = Unmanaged<IOKitSystemPowerNotifier.HandlerBox>
        .fromOpaque(refCon)
        .takeUnretainedValue()
    guard let handler = box.handler else { return }

    let argValue = UInt(bitPattern: messageArgument)
    switch messageType {
    case kIOMessageCanSystemSleepValue:
        handler(PowerMessage.canSystemSleep, argValue)
    case kIOMessageSystemWillSleepValue:
        handler(PowerMessage.systemWillSleep, argValue)
    case kIOMessageSystemHasPoweredOnValue:
        handler(PowerMessage.systemHasPoweredOn, argValue)
    default:
        // Other messages (kIOMessageSystemWillNotSleep,
        // kIOMessageSystemWillPowerOn, etc.) are not actionable for us.
        break
    }
}

// MARK: - Mock notifier (test seam)

/// Test-mock `SystemPowerNotifier` that fires synthetic power messages
/// against the registered handler. Lives in production code so test
/// targets can compose against it without a separate mocks module.
public final class MockSystemPowerNotifier: SystemPowerNotifier, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: PowerMessageHandler?
    private var _allowed: [UInt] = []

    public init() {}

    public var allowedPowerChangeArguments: [UInt] {
        lock.lock(); defer { lock.unlock() }
        return _allowed
    }

    public func register(handler: @escaping PowerMessageHandler) throws {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }

    public func unregister() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    public func allowPowerChange(_ argument: UInt) {
        lock.lock(); defer { lock.unlock() }
        _allowed.append(argument)
    }

    // MARK: - Test helpers

    public func fireWillSleep(argument: UInt) {
        let h: PowerMessageHandler? = {
            lock.lock(); defer { lock.unlock() }
            return handler
        }()
        h?(.systemWillSleep, argument)
    }

    public func fireDidWake(argument: UInt) {
        let h: PowerMessageHandler? = {
            lock.lock(); defer { lock.unlock() }
            return handler
        }()
        h?(.systemHasPoweredOn, argument)
    }

    public func fireCanSleep(argument: UInt) {
        let h: PowerMessageHandler? = {
            lock.lock(); defer { lock.unlock() }
            return handler
        }()
        h?(.canSystemSleep, argument)
    }
}

// MARK: - Observer

/// Observes system sleep/wake events and routes them into a
/// `PowerEventTarget` (typically `RecordingEngine`).
///
/// On `kIOMessageSystemWillSleep`, the observer:
///   1. Calls `target.systemWillSleep()` synchronously (blocking the
///      dispatch trampoline via a `DispatchSemaphore`) so the target
///      drains pipelines, persists in-flight, and releases the power
///      assertion BEFORE the system goes to sleep.
///   2. Calls `IOAllowPowerChange` once the target returns OR the
///      timeout elapses. The plan requires the timeout fallback: the
///      30s IOKit budget is real and we'd rather lose data than block
///      the OS from sleeping.
///
/// On `kIOMessageSystemHasPoweredOn`, the observer dispatches
/// `target.systemDidWake()` asynchronously (no IOKit ack required for
/// wake) and lets the engine apply the heal rule and bring up pipelines.
///
/// On `kIOMessageCanSystemSleep`, the observer immediately calls
/// `IOAllowPowerChange` without bothering the target — there's no
/// reason for Steno to ever deny user-initiated sleep.
public final class PowerManagementObserver: @unchecked Sendable {

    private let notifier: any SystemPowerNotifier
    private let willSleepTimeoutMs: Int

    private let lock = NSLock()
    private var _target: (any PowerEventTarget)?
    private var _started: Bool = false

    /// - Parameters:
    ///   - notifier: The `SystemPowerNotifier` to register against.
    ///     Production passes `IOKitSystemPowerNotifier()`; tests pass
    ///     `MockSystemPowerNotifier()`.
    ///   - willSleepTimeoutMs: Maximum time to block the trampoline
    ///     waiting for `target.systemWillSleep()` to complete. The plan
    ///     specifies a 25-second budget (5s margin under the 30s IOKit
    ///     budget); tests inject a tighter value to verify the timeout
    ///     fallback path. Default: 25_000ms.
    public init(
        notifier: any SystemPowerNotifier = IOKitSystemPowerNotifier(),
        willSleepTimeoutMs: Int = 25_000
    ) {
        self.notifier = notifier
        self.willSleepTimeoutMs = willSleepTimeoutMs
    }

    deinit {
        // We can't take the lock from deinit reliably; rely on the fact
        // that the caller has either explicitly called stop() OR the
        // notifier's own deinit will handle cleanup.
        notifier.unregister()
    }

    /// Begin observing system power events for the given target. The
    /// observer keeps a strong reference to the target until `stop()`
    /// is called.
    public func start(target: any PowerEventTarget) throws {
        lock.lock()
        guard !_started else {
            lock.unlock()
            return
        }
        _target = target
        _started = true
        lock.unlock()

        let timeoutMs = self.willSleepTimeoutMs
        let weakSelfBox = WeakSelfBox(self)

        try notifier.register { [weakSelfBox] message, argument in
            guard let observer = weakSelfBox.value else { return }
            observer.handle(message: message, argument: argument, timeoutMs: timeoutMs)
        }
    }

    /// Stop observing. After this call, no further messages drive the
    /// target.
    public func stop() {
        lock.lock()
        _target = nil
        _started = false
        lock.unlock()
        notifier.unregister()
    }

    // MARK: - Dispatch

    private func currentTarget() -> (any PowerEventTarget)? {
        lock.lock(); defer { lock.unlock() }
        return _target
    }

    private func handle(message: PowerMessage, argument: UInt, timeoutMs: Int) {
        guard let target = currentTarget() else { return }

        switch message {
        case .canSystemSleep:
            // Always allow user-initiated sleep. We have no reason to
            // deny it, and denying inadvertently is a hostile UX.
            notifier.allowPowerChange(argument)

        case .systemWillSleep:
            // Block the trampoline until the target finishes draining
            // pipelines, persisting in-flight work, and releasing the
            // power assertion — OR the timeout fires. Either way, we
            // call IOAllowPowerChange next so the system can sleep.
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await target.systemWillSleep()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
            notifier.allowPowerChange(argument)

        case .systemHasPoweredOn:
            // Wake doesn't require IOAllowPowerChange. Fire-and-forget
            // the engine's wake handler (which applies the heal rule
            // and brings up pipelines).
            Task {
                await target.systemDidWake()
            }
        }
    }

    // MARK: - WeakSelfBox

    /// Holds a weak reference to the observer so the IOKit handler
    /// closure does not retain `self`. (The observer's lifetime is
    /// owned by the daemon's RunCommand.)
    private final class WeakSelfBox: @unchecked Sendable {
        weak var value: PowerManagementObserver?
        init(_ value: PowerManagementObserver) { self.value = value }
    }
}
