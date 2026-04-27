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
    /// Default: 30s per the plan.
    public var healGapSeconds: Int

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

    public init(
        summarizationProvider: SummarizationProvider = .local,
        anthropicAPIKey: String? = nil,
        anthropicModel: String = "claude-3-5-haiku-20241022",
        lastDevice: String? = nil,
        lastSystemAudioEnabled: Bool = true,
        healGapSeconds: Int = 30,
        dedupOverlapSeconds: Double = 3.0,
        dedupScoreThreshold: Double = 0.92,
        dedupMicPeakThresholdDb: Double = -25.0,
        dedupTriggerDebounceSeconds: Double = 5.0
    ) {
        self.summarizationProvider = summarizationProvider
        self.anthropicAPIKey = anthropicAPIKey
        self.anthropicModel = anthropicModel
        self.lastDevice = lastDevice
        self.lastSystemAudioEnabled = lastSystemAudioEnabled
        self.healGapSeconds = healGapSeconds
        self.dedupOverlapSeconds = dedupOverlapSeconds
        self.dedupScoreThreshold = dedupScoreThreshold
        self.dedupMicPeakThresholdDb = dedupMicPeakThresholdDb
        self.dedupTriggerDebounceSeconds = dedupTriggerDebounceSeconds
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
        case dedupOverlapSeconds
        case dedupScoreThreshold
        case dedupMicPeakThresholdDb
        case dedupTriggerDebounceSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.summarizationProvider = try container.decodeIfPresent(SummarizationProvider.self, forKey: .summarizationProvider) ?? .local
        self.anthropicAPIKey = try container.decodeIfPresent(String.self, forKey: .anthropicAPIKey)
        self.anthropicModel = try container.decodeIfPresent(String.self, forKey: .anthropicModel) ?? "claude-3-5-haiku-20241022"
        self.lastDevice = try container.decodeIfPresent(String.self, forKey: .lastDevice)
        self.lastSystemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .lastSystemAudioEnabled) ?? true
        self.healGapSeconds = try container.decodeIfPresent(Int.self, forKey: .healGapSeconds) ?? 30
        self.dedupOverlapSeconds = try container.decodeIfPresent(Double.self, forKey: .dedupOverlapSeconds) ?? 3.0
        self.dedupScoreThreshold = try container.decodeIfPresent(Double.self, forKey: .dedupScoreThreshold) ?? 0.92
        self.dedupMicPeakThresholdDb = try container.decodeIfPresent(Double.self, forKey: .dedupMicPeakThresholdDb) ?? -25.0
        self.dedupTriggerDebounceSeconds = try container.decodeIfPresent(Double.self, forKey: .dedupTriggerDebounceSeconds) ?? 5.0
    }

    // MARK: - Persistence

    private static var settingsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stenoDir = appSupport.appendingPathComponent("Steno")
        return stenoDir.appendingPathComponent("settings.json")
    }

    /// Load settings from disk, or return defaults if not found.
    public static func load() -> StenoSettings {
        do {
            let data = try Data(contentsOf: settingsURL)
            return try JSONDecoder().decode(StenoSettings.self, from: data)
        } catch {
            return StenoSettings()
        }
    }

    /// Save settings to disk.
    public func save() throws {
        let url = Self.settingsURL
        let directory = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(self)
        try data.write(to: url)
    }
}
