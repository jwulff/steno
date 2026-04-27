import Foundation

/// Outcome of applying the U6 heal rule on a wake / device-change /
/// recovery event.
public enum HealOutcome: Sendable, Equatable {
    /// Reuse the current session and stamp the given heal marker on the
    /// next finalized segment of each rebuilt pipeline.
    case reuseSession(healMarker: String)
    /// Close the current session as `interrupted` and open a new active
    /// session. The first segment of the new session does NOT carry a
    /// heal marker (it is a new session, not a heal-in-place).
    case rollover
}

/// Pure heal-rule decision logic for U6.
///
/// The rule (verbatim from the plan):
///   - If `gap < threshold && deviceUID == lastDeviceUID` → `reuse_session`
///     with `heal_marker = "after_gap:<N>s"` on the next finalized
///     segment.
///   - Else (gap reached the threshold OR device changed) → `rollover`:
///     close the current session as `interrupted`, open a new active
///     session, the first segment of the new session does NOT carry a
///     heal marker.
///
/// `nil` device UIDs are treated as "unknown device." Two `nil`s match
/// (both unknown, treat as same), but `nil` vs non-nil is treated as a
/// device change (we do not know whether the device changed, so we err
/// on the safer side: rollover).
///
/// The 30-second threshold is configurable via `StenoSettings.healGapSeconds`
/// (call site reads the setting; this type only takes the resolved
/// threshold as a parameter so the rule itself is purely functional).
public enum HealRule {

    /// Apply the heal rule.
    ///
    /// - Parameters:
    ///   - gap: Wall-clock seconds between teardown (gap_started_at) and
    ///     the wake/recovery event.
    ///   - deviceUID: The current default-input device UID, looked up via
    ///     Core Audio HAL on wake. `nil` if unknown.
    ///   - lastDeviceUID: The device UID captured at the last successful
    ///     pipeline bring-up. `nil` if never captured.
    ///   - thresholdSeconds: The reuse-window threshold. Default 30s
    ///     (R5). Configurable via `StenoSettings.healGapSeconds`.
    /// - Returns: `.reuseSession(healMarker:)` or `.rollover`.
    public static func decide(
        gap: TimeInterval,
        deviceUID: String?,
        lastDeviceUID: String?,
        thresholdSeconds: Int
    ) -> HealOutcome {
        // Device-change override: even a 0-second gap rolls the session
        // when the input device changed. The semantics for `nil` are
        // documented above.
        let sameDevice = (deviceUID == lastDeviceUID)
        if !sameDevice {
            return .rollover
        }

        // Boundary is `<` for reuse: gap == threshold rolls over.
        if gap >= TimeInterval(thresholdSeconds) {
            return .rollover
        }

        // Reuse path: stamp `after_gap:<N>s`. Negative gaps clamp to 0.
        let clamped = max(0, gap)
        let seconds = Int(clamped.rounded())
        return .reuseSession(healMarker: "after_gap:\(seconds)s")
    }
}
