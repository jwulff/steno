import Foundation

/// Which on-device model pipeline a readiness signal refers to (#62).
///
/// - `transcription`: Layer A — Apple `SpeechTranscriber` / `SpeechAnalyzer`
///   (the live transcript). Hard-gated by hardware (16-core Neural Engine) and
///   the per-locale ASR model asset.
/// - `diarization`: Layer B — FluidAudio tier diarizers (speaker labels). Soft
///   dependency: if unavailable the transcript still works, labels just don't
///   appear.
public enum ModelComponent: String, Sendable, Codable {
    case transcription
    case diarization
}

/// Lifecycle of an on-device model pipeline, surfaced to clients so the UI can
/// show "preparing" / "ready" / "unavailable" instead of failing silently (#62).
///
/// `unavailable` carries a human-readable reason for display. The states are
/// monotonic in normal operation (`preparing → ready`), except that a pipeline
/// can go straight to `unavailable` when a gate fails (unsupported hardware,
/// unsupported locale, or a failed asset download).
public enum ModelReadiness: Sendable, Equatable {
    case preparing
    case ready
    case unavailable(reason: String)

    /// Wire token used on the `model_status` NDJSON event (`state` field).
    public var wireState: String {
        switch self {
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .unavailable: return "unavailable"
        }
    }

    /// Display reason for the `unavailable` state; `nil` otherwise.
    public var reason: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .preparing, .ready: return nil
        }
    }
}
