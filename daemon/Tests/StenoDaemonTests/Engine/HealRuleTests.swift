import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U6's heal-rule decision logic.
///
/// The heal rule is a pure decision function: given a `(gap, deviceUID,
/// lastDeviceUID, threshold)` tuple, decide whether to reuse the current
/// session (heal in place with a heal marker) or roll over (close
/// `interrupted`, open a new active session).
///
/// All tests here exercise the pure `HealRule.decide(...)` function so the
/// boundary semantics (`<` vs `<=`), the "device change overrides short
/// gap" rule, and the heal-marker formatting are all locked down without
/// spinning up an actor, an IOKit observer, or a database.
@Suite("Heal Rule Tests (U6)")
struct HealRuleTests {

    // MARK: - Reuse path

    @Test("gap=12s, same device → reuse with heal_marker after_gap:12s")
    func reuseShortGapSameDevice() {
        let outcome = HealRule.decide(
            gap: 12,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        #expect(outcome == .reuseSession(healMarker: "after_gap:12s"))
    }

    @Test("gap=0s (instant) → reuse with heal_marker after_gap:0s")
    func reuseInstantWake() {
        let outcome = HealRule.decide(
            gap: 0,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        #expect(outcome == .reuseSession(healMarker: "after_gap:0s"))
    }

    // MARK: - Rollover path

    @Test("gap=45s, same device → rollover (over-threshold)")
    func rolloverLongGap() {
        let outcome = HealRule.decide(
            gap: 45,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        #expect(outcome == .rollover)
    }

    @Test("gap=10s, different device → rollover (device change overrides short gap)")
    func rolloverDeviceChange() {
        let outcome = HealRule.decide(
            gap: 10,
            deviceUID: "AirPodsPro",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        #expect(outcome == .rollover)
    }

    // MARK: - Boundary

    @Test("gap=30s exactly → rollover (boundary is < threshold for reuse)")
    func rolloverAtBoundary() {
        let outcome = HealRule.decide(
            gap: 30,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        #expect(outcome == .rollover)
    }

    @Test("gap=29.999s → reuse (just under threshold)")
    func reuseJustUnderBoundary() {
        let outcome = HealRule.decide(
            gap: 29.999,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        // Heal marker rounds to the nearest whole second → 30s.
        #expect(outcome == .reuseSession(healMarker: "after_gap:30s"))
    }

    // MARK: - Unknown / nil deviceUID

    @Test("Same nil deviceUID (no Core Audio info) treated as same device")
    func reuseWhenBothDeviceUIDsNil() {
        let outcome = HealRule.decide(
            gap: 5,
            deviceUID: nil,
            lastDeviceUID: nil,
            thresholdSeconds: 30
        )
        #expect(outcome == .reuseSession(healMarker: "after_gap:5s"))
    }

    @Test("nil current deviceUID, non-nil last → rollover (treat as device change)")
    func rolloverWhenCurrentDeviceUIDIsNil() {
        let outcome = HealRule.decide(
            gap: 5,
            deviceUID: nil,
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 30
        )
        #expect(outcome == .rollover)
    }

    @Test("non-nil current deviceUID, nil last → rollover (treat as device change)")
    func rolloverWhenLastDeviceUIDIsNil() {
        let outcome = HealRule.decide(
            gap: 5,
            deviceUID: "BuiltInMic",
            lastDeviceUID: nil,
            thresholdSeconds: 30
        )
        #expect(outcome == .rollover)
    }

    // MARK: - Threshold configurability

    @Test("Configurable threshold: 60s threshold, gap=45s → reuse")
    func customThresholdAllowsLongerReuse() {
        let outcome = HealRule.decide(
            gap: 45,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 60
        )
        #expect(outcome == .reuseSession(healMarker: "after_gap:45s"))
    }

    @Test("Configurable threshold: 10s threshold, gap=12s → rollover")
    func customThresholdShortensReuseWindow() {
        let outcome = HealRule.decide(
            gap: 12,
            deviceUID: "BuiltInMic",
            lastDeviceUID: "BuiltInMic",
            thresholdSeconds: 10
        )
        #expect(outcome == .rollover)
    }

    // MARK: - Heal marker formatting

    @Test("Heal marker rounds to whole seconds")
    func healMarkerRoundsSeconds() {
        // 12.4 rounds to 12.
        let near12 = HealRule.decide(
            gap: 12.4,
            deviceUID: "X",
            lastDeviceUID: "X",
            thresholdSeconds: 30
        )
        #expect(near12 == .reuseSession(healMarker: "after_gap:12s"))

        // 12.6 rounds to 13.
        let near13 = HealRule.decide(
            gap: 12.6,
            deviceUID: "X",
            lastDeviceUID: "X",
            thresholdSeconds: 30
        )
        #expect(near13 == .reuseSession(healMarker: "after_gap:13s"))
    }

    @Test("Negative gap clamps to 0")
    func negativeGapClamps() {
        let outcome = HealRule.decide(
            gap: -1,
            deviceUID: "X",
            lastDeviceUID: "X",
            thresholdSeconds: 30
        )
        #expect(outcome == .reuseSession(healMarker: "after_gap:0s"))
    }
}
