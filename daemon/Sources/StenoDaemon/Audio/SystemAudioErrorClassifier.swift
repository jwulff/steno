import Foundation
import ScreenCaptureKit

/// The recovery action `SystemAudioSource` should take in response to an
/// `SCStreamDelegate.stream(_:didStopWithError:)` callback.
///
/// Maps the SCStream error code to one of three orchestration outcomes
/// the engine knows how to handle:
///
///   - `.ignore` — benign / self-inflicted state, no rebuild, no backoff
///     advance. Currently only `attemptToStopStreamState` (-3808).
///   - `.retry` — transient SCK error; engine should rebuild via U5's
///     `restartSystemPipeline(reason:errorCode:)` so the bounded backoff
///     handles wait + re-try + surrender.
///   - `.permissionRevoked` — Screen Recording TCC permission has been
///     revoked (`userDeclined`, -3801). Do NOT retry. Engine emits a
///     non-transient `recoveryExhausted` event with the load-bearing
///     `MIC_OR_SCREEN_PERMISSION_REVOKED` token so U9's TUI surface can
///     match on it.
public enum SCStreamRecoveryAction: Sendable, Equatable {
    case ignore
    case retry
    case permissionRevoked
}

/// The load-bearing token U9's TUI surface matches on. Used both in
/// `recoveryExhausted` event payloads (for SCStream `userDeclined` and
/// AVAudioEngine TCC-revocation paths) and in this file's classifier
/// public API. Do NOT change the wording — the TUI surface and any
/// downstream message-router heuristics depend on this exact string.
public let micOrScreenPermissionRevokedToken = "MIC_OR_SCREEN_PERMISSION_REVOKED"

/// Pure classifier: maps an `Error` from `SCStreamDelegate.stream(_:didStopWithError:)`
/// to a `SCStreamRecoveryAction`. Hosted as a static function so tests
/// can synthesize NSErrors directly without needing real Screen
/// Recording permission.
///
/// Mapping (per the U8 plan; SDK constants verified against
/// `ScreenCaptureKit.SCStreamError` on the build toolchain):
///
///   | Code  | SDK constant                              | Action              |
///   |-------|-------------------------------------------|---------------------|
///   | -3801 | `userDeclined`                            | `.permissionRevoked` |
///   | -3808 | `attemptToStopStreamState`                | `.ignore`           |
///   | -3804 | `failedApplicationConnectionInvalid`      | `.retry`            |
///   | -3805 | `failedApplicationConnectionInterrupted`  | `.retry`            |
///   | -3815 | `noCaptureSource`                         | `.retry`            |
///   | -3821 | `systemStoppedStream`                     | `.retry`            |
///   | other | (unknown / future code)                   | `.retry`            |
///
/// Note on the plan's table: the plan mentioned `-3805 connectionInvalid`
/// as the SDK name. The actual SDK constant at `-3805` is
/// `failedApplicationConnectionInterrupted`; `-3804` is
/// `failedApplicationConnectionInvalid`. Both are retryable, so the
/// behavioral outcome matches the plan's intent. Documented here to
/// avoid future confusion.
public enum SystemAudioErrorClassifier {

    /// SCStream error domain. Surfaces in `SCStreamError.errorDomain`
    /// at runtime; hardcoded here so the classifier is callable on
    /// arbitrary `NSError` values (including synthetic ones in tests).
    public static let scStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

    /// Classify an error produced by `SCStreamDelegate.stream(_:didStopWithError:)`.
    public static func classify(_ error: Error) -> SCStreamRecoveryAction {
        let ns = error as NSError
        // Only dispatch on SCStreamErrorDomain. An error from another
        // domain (rare, but possible if SCK wraps an underlying error
        // pre-classification) is treated as retry — the bounded
        // backoff handles repeated unknown-domain failures via
        // surrender if they keep recurring.
        guard ns.domain == scStreamErrorDomain else {
            return .retry
        }
        switch ns.code {
        case SCStreamError.userDeclined.rawValue:
            return .permissionRevoked
        case SCStreamError.attemptToStopStreamState.rawValue:
            return .ignore
        case SCStreamError.failedApplicationConnectionInvalid.rawValue,
             SCStreamError.failedApplicationConnectionInterrupted.rawValue,
             SCStreamError.noCaptureSource.rawValue,
             SCStreamError.systemStoppedStream.rawValue:
            return .retry
        default:
            // Unknown SCStream codes (future SDK additions, undocumented
            // codes) → retry. Bounded backoff in U5 will surrender if
            // the same unknown code recurs five times.
            return .retry
        }
    }

    /// Compute the stable error-code key used by `BackoffPolicy` for
    /// "same-error" tracking on the SCStream path. Mirrors the engine's
    /// existing `errorCode(for:)` shape (`domain#code`) so the policy
    /// state plays nicely with errors arriving from any source.
    public static func backoffKey(for error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}

/// Heuristic detector for AVAudioEngine / Core Audio errors that signal
/// microphone TCC permission revocation. The plan's U8 spec calls these
/// "AVAudioEngine error class that signals microphone TCC revocation
/// (typically `kAudioServicesNoSuchHardware`-class or AVAudioSession
/// permission errors)." The exact OSStatus the runtime surfaces is
/// environment-dependent; we use a conservative heuristic match against
/// the error message and known OSStatus codes.
///
/// When this returns `true`, the engine emits a non-transient
/// `recoveryExhausted` event with `MIC_OR_SCREEN_PERMISSION_REVOKED`
/// and does NOT enter the U5 backoff loop (per plan: the loop produces
/// "ambiguous orange-indicator flicker while silently failing").
public enum MicrophonePermissionErrorDetector {

    /// Known Core Audio / AVAudioSession OSStatus values that map to
    /// permission-class failures. `kAudioServicesNoSuchHardware`
    /// (`'nope'` = 0x6E6F7065 = 1852796517) surfaces when the input
    /// device disappears, including the post-revocation case.
    /// `kAudioUnitErr_NoConnection` and friends are not included
    /// because they're not exclusively permission-class.
    private static let permissionOSStatusCodes: Set<Int> = [
        // kAudioServicesNoSuchHardware — 'nope'
        1_852_796_517,
        // kAudio_NoSuchHardware — also surfaces on device removal
        560_947_818,
    ]

    /// Conservative substring match. Lower-cased description and
    /// localizedDescription are checked against permission-class
    /// keywords. False positives here are tolerable (the engine ends
    /// up in `.error` instead of attempting a useless rebuild loop);
    /// false negatives mean we'd incorrectly enter the U5 backoff loop
    /// — which is the exact "ambiguous flicker" failure the plan calls
    /// out, so we err on the broad-match side.
    private static let permissionKeywords: [String] = [
        "permission",
        "denied",
        "not authorized",
        "unauthorized",
        "tcc",
        "kaudioservicesnosuchhardware",
        "no such hardware",
    ]

    /// Returns `true` if the error looks like a microphone TCC
    /// revocation. Used by the engine's mic-error path to skip the
    /// U5 backoff loop for non-retryable permission failures.
    public static func isPermissionRevocation(_ error: Error) -> Bool {
        let ns = error as NSError
        if permissionOSStatusCodes.contains(ns.code) {
            return true
        }
        let haystack = (ns.localizedDescription + " " + String(describing: error)).lowercased()
        return permissionKeywords.contains { haystack.contains($0) }
    }
}
