import Foundation

/// Per-source model-tier state machine (epic #53 §5). Each audio source owns
/// one controller. Starts on `.sortformer` (stable, ≤4 speakers) and escalates
/// to `.lsEEND` (≤10, less stable) once a window's distinct-speaker count
/// outgrows the Sortformer cap.
///
/// Escalation is **sticky** for the session — once on LS-EEND it stays there
/// (hysteresis: no flapping). This is the conservative default; optional
/// de-escalation after a sustained low count is intentionally not implemented.
///
/// The controller observes only the distinct-speaker count today (the
/// "Sortformer's own outputs / registry growth" signal from §5). The
/// missed-speech / low-confidence escalation signal needs a confidence channel
/// the diarizer doesn't expose yet, so it's deferred.
///
/// Wiring: `currentModel()` backs the scheduler's model provider (#58);
/// `observe(speakerCount:)` is fed the just-closed window's
/// `DiarizationResult.speakerCount`. Tier never changes mid-window because the
/// model is read once at window start and `observe` runs after.
public actor DiarizationTierController {
    /// A window with strictly more distinct speakers than this escalates the
    /// source. Defaults to the Sortformer cap (4) → a 5th speaker escalates.
    private let escalationThreshold: Int
    private var current: DiarizationModel = .sortformer

    public init(escalationThreshold: Int = DiarizationModel.sortformer.maxSpeakers) {
        self.escalationThreshold = escalationThreshold
    }

    /// The tier to run the next window through.
    public func currentModel() -> DiarizationModel { current }

    /// Whether the source has escalated.
    public var isEscalated: Bool { current == .lsEEND }

    /// Fold in the distinct-speaker count from the just-closed window.
    /// Escalates to LS-EEND the first time the count exceeds the threshold;
    /// never de-escalates.
    public func observe(speakerCount: Int) {
        guard current == .sortformer else { return }
        if speakerCount > escalationThreshold {
            current = .lsEEND
        }
    }
}
