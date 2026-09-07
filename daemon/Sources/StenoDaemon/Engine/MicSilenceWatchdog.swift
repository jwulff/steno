import Foundation

/// Detects a microphone that reports as recording while producing
/// nothing but digital silence (#104).
///
/// The failure this exists for: a Bluetooth headset selected as the
/// input device negotiates a profile whose microphone endpoint never
/// delivers audio. Capture starts, `status` answers `recording: true`,
/// level events stream at 10Hz, and every one of them is exactly 0.0 —
/// for as long as the session runs. Nothing in the protocol
/// distinguishes that from a quiet room, so the session looks healthy
/// and records nothing.
///
/// A pure state machine over the throttle ticks, so the threshold can be
/// exercised in tests without sleeping through it.
struct MicSilenceWatchdog: Sendable {

    /// Peak amplitude at or below which a tick counts as silence.
    ///
    /// Roughly -100 dBFS. A working microphone in a treated room still
    /// sits well above this; the observed failure reports exactly 0.0.
    static let defaultPeakFloor: Float = 1e-5

    /// Ticks of silence before warning: 30 seconds at the engine's 10Hz
    /// level throttle. Long enough that a held pause or a genuinely
    /// silent stretch of a meeting does not trip it.
    static let defaultTicksToWarn = 300

    /// Seconds per tick, matching the level throttle's interval.
    static let defaultTickSeconds = 0.1

    private let peakFloor: Float
    private let ticksToWarn: Int
    private let tickSeconds: Double

    private var silentTicks = 0
    private var warned = false

    init(
        peakFloor: Float = MicSilenceWatchdog.defaultPeakFloor,
        ticksToWarn: Int = MicSilenceWatchdog.defaultTicksToWarn,
        tickSeconds: Double = MicSilenceWatchdog.defaultTickSeconds
    ) {
        self.peakFloor = peakFloor
        self.ticksToWarn = max(1, ticksToWarn)
        self.tickSeconds = tickSeconds
    }

    /// Feed one level-throttle tick.
    ///
    /// - Returns: The elapsed silent seconds, on the single tick where
    ///   the threshold is first crossed. `nil` otherwise — including for
    ///   every later tick of the same silent stretch, so a wedged
    ///   microphone produces one warning rather than one every 100ms.
    ///   The watchdog re-arms as soon as audio returns.
    mutating func observe(peak: Float) -> Double? {
        guard peak <= peakFloor else {
            silentTicks = 0
            warned = false
            return nil
        }

        silentTicks += 1
        guard !warned, silentTicks >= ticksToWarn else { return nil }

        warned = true
        return Double(silentTicks) * tickSeconds
    }

    /// Drop all accumulated state. Called when the mic pipeline is
    /// rebuilt so a fresh device gets a fresh window.
    mutating func reset() {
        silentTicks = 0
        warned = false
    }
}
