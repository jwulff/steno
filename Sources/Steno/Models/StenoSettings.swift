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

    public init(
        summarizationProvider: SummarizationProvider = .local,
        anthropicAPIKey: String? = nil,
        anthropicModel: String = "claude-3-5-haiku-20241022"
    ) {
        self.summarizationProvider = summarizationProvider
        self.anthropicAPIKey = anthropicAPIKey
        self.anthropicModel = anthropicModel
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
