import Foundation

/// Wall-clock-based one-shot timer. Fires at an absolute `Date` and
/// survives system sleep — `DispatchWallTime` advances during sleep, so a
/// timer armed for `now + 30 min` correctly fires 30 minutes of wall-clock
/// time later regardless of how much of that interval the system spent
/// sleeping.
///
/// **Why wall time, not monotonic time?** `DispatchTime` (the
/// `schedule(deadline:)` overload) is `mach_absolute_time`-based and
/// frozen during system sleep. A timer armed for `+30 min` via
/// `DispatchTime` and then immediately slept-through for 25 minutes would
/// fire 30 minutes after wake, not 5 minutes after wake. That's the wrong
/// semantics for U10's auto-resume.
///
/// `DispatchWallTime` (the `schedule(wallDeadline:)` overload) is
/// `gettimeofday`-based — it advances during sleep — which is what U10's
/// auto-resume requires.
///
/// Idempotency:
/// - `arm(at:_:)` overwrites any existing armed timer (cancels the prior
///   source before creating a new one).
/// - `cancel()` is a no-op if no timer is armed.
/// - The fire closure is invoked at most once per `arm` call.
public final class PauseTimer: @unchecked Sendable {

    private let lock = NSLock()
    private var source: DispatchSourceTimer?
    private var deadline: Date?

    public init() {}

    // Note: no `deinit` cleanup. The `DispatchSourceTimer`'s event handler
    // captures `[weak self]`, so the source can outlive `self` without
    // creating a retain cycle. Callers explicitly cancel via `cancel()`
    // during their own teardown paths (see `RecordingEngine.stop()` /
    // `cleanup()` / `pause()`). Adding `source?.cancel()` in deinit
    // surfaces dispatch teardown races during heavy concurrent test load.

    /// Arm the timer to fire at the given absolute wall-clock deadline.
    /// Replaces any existing armed timer. The fire closure is invoked at
    /// most once. If the deadline is in the past, the timer fires as soon
    /// as the global queue services it.
    ///
    /// The closure is `@Sendable` and runs on a global dispatch queue.
    /// Hand off to a `Task` or actor immediately if you need
    /// actor-isolated work.
    public func arm(at deadline: Date, _ fire: @escaping @Sendable () -> Void) {
        // Take a snapshot of the prior source under the lock, then
        // cancel it OUTSIDE the lock so a fire-handler racing toward
        // `clearState()` doesn't deadlock against us.
        lock.lock()
        let prior = source
        source = nil
        self.deadline = nil
        lock.unlock()
        prior?.cancel()

        // Use the default-priority global queue. The fire closure is
        // expected to be near-instantaneous (it just spawns a Task).
        let newSource = DispatchSource.makeTimerSource(
            flags: [],
            queue: .global(qos: .default)
        )
        // Translate the Foundation Date into a DispatchWallTime.
        // DispatchWallTime advances during system sleep, so a deadline
        // 30 minutes in the future fires 30 minutes of wall time later
        // even if the laptop slept for 25 of them.
        let secondsSinceEpoch = deadline.timeIntervalSince1970
        let wholeSeconds = Int(secondsSinceEpoch.rounded(.down))
        let nanos = Int((secondsSinceEpoch - Double(wholeSeconds)) * 1_000_000_000)
        let walltime = DispatchWallTime(
            timespec: timespec(tv_sec: wholeSeconds, tv_nsec: nanos)
        )

        newSource.schedule(wallDeadline: walltime, repeating: .never)
        newSource.setEventHandler { [weak self] in
            // Clear our internal state BEFORE firing so the closure can
            // observe `isArmed() == false` if it queries.
            self?.clearState()
            fire()
        }

        lock.lock()
        self.source = newSource
        self.deadline = deadline
        lock.unlock()

        newSource.resume()
    }

    /// Cancel the armed timer. The fire closure will not be invoked
    /// (unless it has already started running on the dispatch queue, in
    /// which case dispatch's standard cancellation race applies — but the
    /// state is cleared before fire, so a fire that *just* started is
    /// harmless).
    public func cancel() {
        lock.lock()
        let prior = source
        source = nil
        deadline = nil
        lock.unlock()
        prior?.cancel()
    }

    /// Whether a timer is currently armed.
    public func isArmed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return source != nil
    }

    /// The absolute wall-clock deadline of the armed timer, or `nil` if
    /// none is armed (or it has already fired/been cancelled).
    public var currentDeadline: Date? {
        lock.lock(); defer { lock.unlock() }
        return deadline
    }

    /// Internal helper invoked at the top of the fire handler. Clears
    /// the source/deadline so post-fire observers see "not armed."
    private func clearState() {
        lock.lock(); defer { lock.unlock() }
        source = nil
        deadline = nil
    }
}
