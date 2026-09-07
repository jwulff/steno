import Testing
@testable import StenoDaemon

/// Tests for the sustained-silence watchdog (#104).
///
/// The bug this guards against: capture reports `recording: true` and
/// streams level events at 10Hz, every one of them exactly 0.0, for
/// minutes at a time. Nothing in the protocol distinguishes that from a
/// quiet room, so the session looks healthy while recording nothing.
///
/// The watchdog is a pure state machine over the throttle ticks, so the
/// 30-second threshold is exercised here in microseconds rather than by
/// sleeping.
@Suite("MicSilenceWatchdog Tests")
struct MicSilenceWatchdogTests {

    private func makeWatchdog(ticksToWarn: Int = 5) -> MicSilenceWatchdog {
        MicSilenceWatchdog(
            peakFloor: 1e-5,
            ticksToWarn: ticksToWarn,
            tickSeconds: 0.1
        )
    }

    /// The reported figure is `ticks * 0.1`, which is not exact in binary
    /// floating point for every tick count (3 * 0.1 == 0.30000000000000004).
    /// The value is only ever shown to a human, so compare accordingly.
    private func isSeconds(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 1e-9
    }

    @Test("Silence shorter than the threshold does not warn")
    func belowThresholdIsQuiet() {
        var watchdog = makeWatchdog(ticksToWarn: 5)
        for _ in 0..<4 {
            #expect(watchdog.observe(peak: 0) == nil)
        }
    }

    @Test("Crossing the threshold reports the elapsed silent seconds")
    func warnsAtThreshold() {
        var watchdog = makeWatchdog(ticksToWarn: 5)
        for _ in 0..<4 { _ = watchdog.observe(peak: 0) }
        #expect(isSeconds(watchdog.observe(peak: 0), 0.5))
    }

    @Test("A continuing silent stretch warns exactly once")
    func warnsOncePerStretch() {
        var watchdog = makeWatchdog(ticksToWarn: 5)
        var warnings: [Double] = []
        for _ in 0..<50 {
            if let seconds = watchdog.observe(peak: 0) { warnings.append(seconds) }
        }
        #expect(warnings.count == 1)
        #expect(isSeconds(warnings.first, 0.5))
    }

    @Test("Audible input resets the counter")
    func audibleResets() {
        var watchdog = makeWatchdog(ticksToWarn: 5)
        for _ in 0..<4 { _ = watchdog.observe(peak: 0) }
        #expect(watchdog.observe(peak: 0.2) == nil)
        for _ in 0..<4 {
            #expect(watchdog.observe(peak: 0) == nil)
        }
    }

    @Test("A second silent stretch warns again after audio returns")
    func rearmsAfterAudio() {
        var watchdog = makeWatchdog(ticksToWarn: 3)
        for _ in 0..<2 { _ = watchdog.observe(peak: 0) }
        #expect(isSeconds(watchdog.observe(peak: 0), 0.3))
        _ = watchdog.observe(peak: 0.4)
        for _ in 0..<2 { _ = watchdog.observe(peak: 0) }
        #expect(isSeconds(watchdog.observe(peak: 0), 0.3))
    }

    @Test("A peak at the floor still counts as silence")
    func floorIsInclusive() {
        var watchdog = makeWatchdog(ticksToWarn: 2)
        _ = watchdog.observe(peak: 1e-5)
        #expect(isSeconds(watchdog.observe(peak: 1e-5), 0.2))
    }

    @Test("A peak just above the floor is treated as audio")
    func aboveFloorIsAudio() {
        var watchdog = makeWatchdog(ticksToWarn: 2)
        _ = watchdog.observe(peak: 1e-4)
        #expect(watchdog.observe(peak: 1e-4) == nil)
    }

    @Test("reset() clears both the counter and the fired flag")
    func resetClearsState() {
        var watchdog = makeWatchdog(ticksToWarn: 3)
        for _ in 0..<3 { _ = watchdog.observe(peak: 0) }
        watchdog.reset()
        for _ in 0..<2 {
            #expect(watchdog.observe(peak: 0) == nil)
        }
        #expect(isSeconds(watchdog.observe(peak: 0), 0.3))
    }

    @Test("Production defaults warn after 30 seconds of 10Hz ticks")
    func productionDefaults() {
        var watchdog = MicSilenceWatchdog()
        for _ in 0..<299 {
            #expect(watchdog.observe(peak: 0) == nil)
        }
        #expect(isSeconds(watchdog.observe(peak: 0), 30.0))
    }
}
