import Foundation

/// The summarization provider to use.
public enum SummarizationProvider: String, Codable, CaseIterable, Sendable {
    case local = "local"
    case anthropic = "anthropic"

    public var displayName: String {
        switch self {
        case .local: return "Apple Intelligence"
        case .anthropic: return "Anthropic Claude"
        }
    }
}

/// Application settings persisted to disk.
public struct StenoSettings: Codable, Sendable {
    /// The preferred summarization provider.
    public var summarizationProvider: SummarizationProvider

    /// Anthropic API key (stored in settings file - consider Keychain for production).
    /// Can also be set via ANTHROPIC_API_KEY environment variable.
    public var anthropicAPIKey: String?

    /// Returns the effective API key, checking environment variable first.
    public var effectiveAnthropicAPIKey: String? {
        // Environment variable takes precedence
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        return anthropicAPIKey
    }

    /// Anthropic model to use.
    public var anthropicModel: String

    /// Last device string used in a successful `start(...)` call. Used by
    /// U4's daemon-start auto-start path to restore the user's last-known
    /// microphone selection. `nil` means "use the system default mic" —
    /// the audio source factory accepts `nil` as the system-default sentinel,
    /// so we prefer that over a hardcoded device name (which varies per Mac).
    public var lastDevice: String?

    /// Last system-audio capture flag. Defaults to `true` per the plan's
    /// always-on goal — system audio is part of the captured world unless
    /// the user explicitly turns it off.
    public var lastSystemAudioEnabled: Bool

    /// U6 heal-rule reuse-window threshold, in seconds. Wakes / device
    /// changes with `gap < healGapSeconds && deviceUID == lastDeviceUID`
    /// reuse the current session and stamp `heal_marker = "after_gap:<N>s"`
    /// on the next finalized segment. Larger gaps or device changes roll
    /// the session over (close as `interrupted`, open a fresh active).
    /// Defaults to `defaultHealGapSeconds`.
    public var healGapSeconds: Int

    /// Default reuse window for the U6 heal rule, in seconds.
    ///
    /// The original 30s was shorter than almost every real interruption.
    /// Closing the lid to walk to another room, locking the screen for a
    /// few minutes, a display sleep between two halves of the same
    /// dictation — each one cleared 30s, so each one closed the session as
    /// `interrupted` and opened a new one, splitting a single sitting into
    /// pieces. Five minutes covers those. It stops well short of merging
    /// genuinely separate sittings: a gap that long usually does mean the
    /// user went and did something else.
    ///
    /// Raising this only reaches fresh installs. A successful start
    /// persists the whole settings struct, so any install that has ever
    /// recorded already has `healGapSeconds` on disk and keeps the value
    /// it has. That is deliberate — a value already written may be a
    /// deliberate choice, and silently rewriting it would be worse than
    /// leaving it alone.
    public static let defaultHealGapSeconds = 300

    /// Cap on how much un-transcribed audio may sit buffered ahead of the
    /// recognizer, in seconds. `0` disables shedding entirely.
    ///
    /// Once transcription falls behind, the buffer between capture and the
    /// recognizer grows without bound and never drains while audio keeps
    /// arriving — on a long recording that reached ~49 minutes of lag (#85).
    /// A live consumer is better served by fresh-and-lossy than by
    /// complete-and-an-hour-late, but an archival recording is not, so this
    /// defaults to **off**: the historical complete-but-late behavior is
    /// preserved unless an operator opts in.
    ///
    /// When set, the oldest buffered audio is dropped first — the newest is
    /// what a live listener wants — and the discontinuity is recorded on the
    /// next segment's `heal_marker` as `shed:<seconds>s` so a reader can see
    /// that audio was discarded rather than silently missing it.
    public var audioBacklogCapSeconds: Double

    /// U11 dedup overlap window, in seconds. A mic segment matches a sys
    /// segment whose `startedAt` falls within `[mic.startedAt -
    /// dedupOverlapSeconds, mic.startedAt + dedupOverlapSeconds]`. Default
    /// 3.0s per the plan.
    public var dedupOverlapSeconds: Double

    /// U11 dedup similarity-score threshold. Mic segments scoring at or
    /// above this against any overlapping sys candidate are marked as
    /// duplicates. Default 0.92 — borderline scores fall below and are
    /// KEPT (better to show a duplicate occasionally than to silently lose
    /// unique mic content).
    public var dedupScoreThreshold: Double

    /// U11 audio-level guard threshold, in dBFS. A mic segment whose
    /// `mic_peak_db` is at or above this is treated as actively spoken
    /// (not passive pickup) and is KEPT regardless of similarity score.
    /// Default -25.0 dBFS.
    public var dedupMicPeakThresholdDb: Double

    /// U11 trigger debounce window, in seconds. Multiple
    /// `RecordingEngine.saveSegment` triggers for the same session
    /// within this window collapse to a single dedup pass. Default 5.0s.
    public var dedupTriggerDebounceSeconds: Double

    /// U12 empty-session prune threshold: minimum non-duplicate text length
    /// (`SUM(LENGTH(text)) WHERE duplicate_of IS NULL`) below which the
    /// just-closed session is deleted. Default 20 chars.
    public var emptySessionMinChars: Int

    /// U12 empty-session prune threshold: minimum wall-clock session
    /// duration (`endedAt - startedAt`) below which the just-closed session
    /// is deleted. Default 3.0 seconds. Boundary is `< minDurationSeconds`,
    /// so an exactly-3s session is KEPT.
    public var emptySessionMinDurationSeconds: Double

    /// U12 topic-extraction gate: minimum non-duplicate segment count below
    /// which the LLM call is skipped. Avoids wasted 45s LLM timeouts on
    /// sessions about to be pruned. Default 3 segments — any session with
    /// fewer is also a strong empty-session-pruner candidate.
    public var topicExtractionMinSegments: Int

    /// U12 retention guard: sessions whose `endedAt` is older than
    /// `now - retentionDays * 86400` are cascade-deleted at daemon start.
    /// **Default 0 = indefinite** — keep everything. Back-of-envelope
    /// (~150 wpm × 10 active hrs/day × 365 days) puts a year of always-on
    /// transcript text at ~100–200 MB on disk including indexes and dedup
    /// metadata, which is small enough on modern hardware that an automatic
    /// cap is more likely to lose moments the user wanted than to save
    /// meaningful disk. Set to a positive integer if you want a hard
    /// rolling window for privacy or storage reasons.
    public var retentionDays: Int

    /// How often, in seconds, the engine re-attempts a full rebuild while
    /// it sits in the `error` state (#109). Maps to the always-on plan's
    /// `error_recovery_interval_secs` (camelCase here like every other
    /// key).
    ///
    /// Before this existed, a U5 surrender while the Mac stayed awake
    /// left the daemon dark until a client happened to send `start`; only
    /// a wake rebuild (#112) could clear the error on its own. Each
    /// attempt is bounded: at most one per interval, whichever trigger
    /// fires (this timer or an audio device change), and never from a
    /// surrender with no session to recover into.
    ///
    /// Default 60. `0` or a negative value turns off both automatic
    /// triggers (the timer AND the device-change trigger) and the anchor
    /// restore after a failed rebuild. `stop()` works from `error` at
    /// every interval.
    public var errorRecoveryIntervalSeconds: Int

    /// #111 — whether a wake re-applies the always-on arm rule when the
    /// engine is sitting in `.idle`.
    ///
    /// `.idle` is reachable only from `stop()`. Always-on recording (#32)
    /// has no user-facing stop, but `stop` is still a valid wire command
    /// and nothing in the engine ever leaves `.idle` on its own, so a stop
    /// from any client otherwise disables capture for the life of the
    /// daemon process. A wake re-runs the same check daemon start does,
    /// including the persisted pause anchor, so an explicit `pause` is
    /// still honoured.
    ///
    /// #113 review fix: default is `false`. A plain `stop()` and a
    /// privacy-motivated `stop()` are the same wire command — this layer
    /// cannot tell an incidental script/test stop from a deliberate one,
    /// so the safe default is to keep `stop` terminal and require an
    /// explicit opt-in (`true`) for the self-healing behavior.
    /// Default: `false`.
    public var reArmIdleOnWake: Bool

    /// #76 automatic real-audio health pulses. Disabled by default because a
    /// pulse intentionally speaks through the default output device; the
    /// on-demand `steno --health-pulse` command works regardless.
    public var healthPulseAutomaticEnabled: Bool

    /// #76 timeout for the real speaker→air→mic health pulse.
    public var healthPulseTimeoutSeconds: Double

    /// #76 fuzzy threshold for matching lossy TTS→ASR output.
    public var healthPulseFuzzyThreshold: Double

    public init(
        summarizationProvider: SummarizationProvider = .local,
        anthropicAPIKey: String? = nil,
        anthropicModel: String = "claude-3-5-haiku-20241022",
        lastDevice: String? = nil,
        lastSystemAudioEnabled: Bool = true,
        healGapSeconds: Int = StenoSettings.defaultHealGapSeconds,
        audioBacklogCapSeconds: Double = 0,
        dedupOverlapSeconds: Double = 3.0,
        dedupScoreThreshold: Double = 0.92,
        dedupMicPeakThresholdDb: Double = -25.0,
        dedupTriggerDebounceSeconds: Double = 5.0,
        emptySessionMinChars: Int = 20,
        emptySessionMinDurationSeconds: Double = 3.0,
        topicExtractionMinSegments: Int = 3,
        retentionDays: Int = 0,
        errorRecoveryIntervalSeconds: Int = 60,
        reArmIdleOnWake: Bool = false,
        healthPulseAutomaticEnabled: Bool = false,
        healthPulseTimeoutSeconds: Double = 45,
        healthPulseFuzzyThreshold: Double = 0.82
    ) {
        self.summarizationProvider = summarizationProvider
        self.anthropicAPIKey = anthropicAPIKey
        self.anthropicModel = anthropicModel
        self.lastDevice = lastDevice
        self.lastSystemAudioEnabled = lastSystemAudioEnabled
        self.healGapSeconds = healGapSeconds
        self.audioBacklogCapSeconds = audioBacklogCapSeconds
        self.dedupOverlapSeconds = dedupOverlapSeconds
        self.dedupScoreThreshold = dedupScoreThreshold
        self.dedupMicPeakThresholdDb = dedupMicPeakThresholdDb
        self.dedupTriggerDebounceSeconds = dedupTriggerDebounceSeconds
        self.emptySessionMinChars = emptySessionMinChars
        self.emptySessionMinDurationSeconds = emptySessionMinDurationSeconds
        self.topicExtractionMinSegments = topicExtractionMinSegments
        self.retentionDays = retentionDays
        self.errorRecoveryIntervalSeconds = errorRecoveryIntervalSeconds
        self.reArmIdleOnWake = reArmIdleOnWake
        self.healthPulseAutomaticEnabled = healthPulseAutomaticEnabled
        self.healthPulseTimeoutSeconds = healthPulseTimeoutSeconds
        self.healthPulseFuzzyThreshold = healthPulseFuzzyThreshold
    }

    // MARK: - Codable

    // Custom Decodable so settings.json files written before U4 (which
    // had no `lastDevice` / `lastSystemAudioEnabled` keys) decode cleanly
    // into the new defaults.
    private enum CodingKeys: String, CodingKey {
        case summarizationProvider
        case anthropicAPIKey
        case anthropicModel
        case lastDevice
        case lastSystemAudioEnabled
        case healGapSeconds
        case audioBacklogCapSeconds
        case dedupOverlapSeconds
        case dedupScoreThreshold
        case dedupMicPeakThresholdDb
        case dedupTriggerDebounceSeconds
        case emptySessionMinChars
        case emptySessionMinDurationSeconds
        case topicExtractionMinSegments
        case retentionDays
        case errorRecoveryIntervalSeconds
        case reArmIdleOnWake
        case healthPulseAutomaticEnabled
        case healthPulseTimeoutSeconds
        case healthPulseFuzzyThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.summarizationProvider = try container.decodeIfPresent(SummarizationProvider.self, forKey: .summarizationProvider) ?? .local
        self.anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey)
        self.anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel) ?? "claude-3-5-haiku-20241022"
        self.lastDevice = try container.decodeIfPresent(String.self, forKey: .lastDevice)
        self.lastSystemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .lastSystemAudioEnabled) ?? true
        self.healGapSeconds = try container.decodeIfPresent(Int.self, forKey: .healGapSeconds) ?? Self.defaultHealGapSeconds
        // Absent in a settings file written before #84 — default off, so an
        // existing install keeps its complete-but-late behavior on upgrade.
        self.audioBacklogCapSeconds = try container.decodeIfPresent(Double.self, forKey: .audioBacklogCapSeconds) ?? 0
        self.dedupOverlapSeconds = try container.decodeIfPresent(Double.self, forKey: .dedupOverlapSeconds) ?? 3.0
        self.dedupScoreThreshold = try container.decodeIfPresent(Double.self, forKey: .dedupScoreThreshold) ?? 0.92
        self.dedupMicPeakThresholdDb = try container.decodeIfPresent(Double.self, forKey: .dedupMicPeakThresholdDb) ?? -25.0
        self.dedupTriggerDebounceSeconds = try container.decodeIfPresent(Double.self, forKey: .dedupTriggerDebounceSeconds) ?? 5.0
        self.emptySessionMinChars = try container.decodeIfPresent(Int.self, forKey: .emptySessionMinChars) ?? 20
        self.emptySessionMinDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .emptySessionMinDurationSeconds) ?? 3.0
        self.topicExtractionMinSegments = try container.decodeIfPresent(Int.self, forKey: .topicExtractionMinSegments) ?? 3
        self.retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 0
        // Absent in a settings file written before #109's timer: default
        // on, so an upgraded install gets automatic recovery from `error`.
        self.errorRecoveryIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .errorRecoveryIntervalSeconds) ?? 60
        self.reArmIdleOnWake = try container.decodeIfPresent(Bool.self, forKey: .reArmIdleOnWake) ?? false
        self.healthPulseAutomaticEnabled = try container.decodeIfPresent(Bool.self, forKey: .healthPulseAutomaticEnabled) ?? false
        self.healthPulseTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .healthPulseTimeoutSeconds) ?? 45
        self.healthPulseFuzzyThreshold = try container.decodeIfPresent(Double.self, forKey: .healthPulseFuzzyThreshold) ?? 0.82
    }
}
