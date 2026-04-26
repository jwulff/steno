import Foundation
import IOKit
import IOKit.pwr_mgt

/// Protocol abstraction over `PowerAssertion` so the engine can be wired
/// against a mock in tests. The production type is `PowerAssertion`; the
/// test type lives in `Tests/StenoDaemonTests/Mocks` (or inline in a test
/// file as `MockPowerAssertion`).
///
/// Idempotency contract:
///   - `acquire()` is a no-op if the assertion is already held.
///   - `release()` is a no-op if no assertion is held.
public protocol PowerAssertionManaging: AnyObject, Sendable {
    func acquire() throws
    func release()
}

/// Errors raised by `PowerAssertion`.
public enum PowerAssertionError: Error, Equatable {
    /// `IOPMAssertionCreateWithName` returned a non-success status.
    case createFailed(kern_return_t)
}

/// Thin Swift wrapper around macOS IOKit's `IOPMAssertionCreateWithName`.
///
/// Lifecycle (per U6, R12):
///   - Acquired on first transition into `EngineStatus.recording`.
///   - Released on every transition OUT of `.recording` (to `.paused`,
///     `.recovering`, `.error`, `.stopping`).
///   - Re-acquired on every transition back INTO `.recording`.
///   - `deinit` releases any still-held assertion as a safety net so a
///     dropped engine never leaks an assertion.
///
/// Discoverability: the `name` shows up in `pmset -g assertions` so the
/// user can see exactly which Steno session is preventing system idle
/// sleep.
public final class PowerAssertion: PowerAssertionManaging, @unchecked Sendable {

    /// Assertion type — prevents user-idle system sleep, matching the
    /// "active capture, do not sleep on us" semantics of R12. Display
    /// sleep is allowed (we don't care about screen state).
    private let assertionType: String = kIOPMAssertionTypePreventUserIdleSystemSleep as String

    /// Identifier shown in `pmset -g assertions` so the user can see
    /// which Steno process holds the assertion.
    public let name: String

    /// Lock guarding the optional assertion ID. Acquire/release can
    /// race in principle (signal handler vs main actor), so we keep the
    /// assertion-ID protected.
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    public init(name: String = "Steno: capturing audio") {
        self.name = name
    }

    deinit {
        // Safety net: if a caller forgot to release, deinit cleans up.
        // We can't take the lock from deinit reliably (deinit isn't
        // re-entrancy-safe), so we read the field directly. This is OK
        // because deinit runs after all references are gone.
        if let id = assertionID {
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    /// Acquire the assertion. Idempotent: a second `acquire()` while one
    /// is already held is a no-op (we don't want to leak a duplicate
    /// assertion ID that the caller would then need to release twice).
    ///
    /// Throws `PowerAssertionError.createFailed` if IOKit returns a
    /// non-success status.
    public func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        if assertionID != nil { return }

        var newID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &newID
        )
        if status != kIOReturnSuccess {
            throw PowerAssertionError.createFailed(status)
        }
        assertionID = newID
    }

    /// Release the assertion. Idempotent: `release()` without a prior
    /// `acquire()` (or after another `release()`) is a no-op.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
    }
}
