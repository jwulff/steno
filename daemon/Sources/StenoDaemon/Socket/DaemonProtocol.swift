import Foundation

/// A command sent from a client to the daemon over the Unix socket.
public struct DaemonCommand: Codable, Sendable {
    public let cmd: String
    public let locale: String?
    public let device: String?
    public let systemAudio: Bool?
    public let events: [String]?

    /// U10 — pause auto-resume window (seconds of wall clock from now).
    /// `nil` AND `indefinite != true` falls back to a server-side default
    /// (`CommandDispatcher.defaultPauseAutoResumeSeconds`). Ignored for
    /// commands other than `pause`.
    public let autoResumeSeconds: Double?

    /// U10 — explicit indefinite-pause flag (no auto-resume timer). When
    /// `true`, `autoResumeSeconds` is ignored and the pause is anchored
    /// only by `paused_indefinitely=1` on the most-recent session row.
    public let indefinite: Bool?

    public init(
        cmd: String,
        locale: String? = nil,
        device: String? = nil,
        systemAudio: Bool? = nil,
        events: [String]? = nil,
        autoResumeSeconds: Double? = nil,
        indefinite: Bool? = nil
    ) {
        self.cmd = cmd
        self.locale = locale
        self.device = device
        self.systemAudio = systemAudio
        self.events = events
        self.autoResumeSeconds = autoResumeSeconds
        self.indefinite = indefinite
    }
}

/// A response from the daemon to a client command.
public struct DaemonResponse: Codable, Sendable {
    public var ok: Bool
    public var sessionId: String?
    public var recording: Bool?
    public var segments: Int?
    public var devices: [String]?
    public var error: String?
    public var status: String?
    public var device: String?
    public var systemAudio: Bool?

    /// U10 — `true` when the engine is currently in `.paused` state.
    /// Surfaced on `status` and `pause` / `resume` responses so a
    /// connecting TUI sees the pause state immediately.
    public var paused: Bool?

    /// U10 — `true` when the active pause has no auto-resume timer
    /// (privacy-critical, matches `paused_indefinitely=1`).
    public var pausedIndefinitely: Bool?

    /// U10 — Unix timestamp (seconds) at which the auto-resume timer will
    /// fire. `nil` for indefinite pauses or when not paused.
    public var pauseExpiresAt: Double?

    public init(
        ok: Bool,
        sessionId: String? = nil,
        recording: Bool? = nil,
        segments: Int? = nil,
        devices: [String]? = nil,
        error: String? = nil,
        status: String? = nil,
        device: String? = nil,
        systemAudio: Bool? = nil,
        paused: Bool? = nil,
        pausedIndefinitely: Bool? = nil,
        pauseExpiresAt: Double? = nil
    ) {
        self.ok = ok
        self.sessionId = sessionId
        self.recording = recording
        self.segments = segments
        self.devices = devices
        self.error = error
        self.status = status
        self.device = device
        self.systemAudio = systemAudio
        self.paused = paused
        self.pausedIndefinitely = pausedIndefinitely
        self.pauseExpiresAt = pauseExpiresAt
    }

    /// Convenience: success response.
    public static func success() -> DaemonResponse {
        DaemonResponse(ok: true)
    }

    /// Convenience: error response.
    public static func failure(_ message: String) -> DaemonResponse {
        DaemonResponse(ok: false, error: message)
    }
}

/// An event streamed from the daemon to subscribed clients.
public struct DaemonEvent: Codable, Sendable {
    public let event: String
    public var text: String?
    public var source: String?
    public var mic: Float?
    public var sys: Float?
    public var sessionId: String?
    public var sequenceNumber: Int?
    public var title: String?
    public var message: String?
    public var transient: Bool?
    public var recording: Bool?
    public var modelProcessing: Bool?
    public var startedAt: Double?

    /// U10 — pause-state event payload.
    public var paused: Bool?
    public var pausedIndefinitely: Bool?
    public var pauseExpiresAt: Double?

    public init(
        event: String,
        text: String? = nil,
        source: String? = nil,
        mic: Float? = nil,
        sys: Float? = nil,
        sessionId: String? = nil,
        sequenceNumber: Int? = nil,
        title: String? = nil,
        message: String? = nil,
        transient: Bool? = nil,
        recording: Bool? = nil,
        modelProcessing: Bool? = nil,
        startedAt: Double? = nil,
        paused: Bool? = nil,
        pausedIndefinitely: Bool? = nil,
        pauseExpiresAt: Double? = nil
    ) {
        self.event = event
        self.text = text
        self.source = source
        self.mic = mic
        self.sys = sys
        self.sessionId = sessionId
        self.sequenceNumber = sequenceNumber
        self.title = title
        self.message = message
        self.transient = transient
        self.recording = recording
        self.modelProcessing = modelProcessing
        self.startedAt = startedAt
        self.paused = paused
        self.pausedIndefinitely = pausedIndefinitely
        self.pauseExpiresAt = pauseExpiresAt
    }
}
