import Foundation

// Wire types for the steno-daemon NDJSON protocol.
//
// These mirror the daemon's own structs in
// `daemon/Sources/StenoDaemon/Socket/DaemonProtocol.swift`. Both ends are
// default-coded Swift structs with identical property names, so they are
// wire-compatible by construction; `ProtocolRoundTripTests` locks that down.
//
// The daemon uses a plain JSONEncoder/JSONDecoder (no key strategy), so the
// JSON keys are exactly these property names. Optionals are omitted when nil
// (synthesized `encodeIfPresent`), which matches the daemon's tolerant
// decoding of absent fields.

/// A command sent from the app to the daemon.
public struct DaemonCommand: Codable, Sendable, Equatable {
    public var cmd: String
    public var locale: String?
    public var device: String?
    public var systemAudio: Bool?
    public var events: [String]?
    public var autoResumeSeconds: Double?
    public var indefinite: Bool?

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

    // Convenience builders for the verbs the app actually sends.

    /// Subscribe to *all* event types (the daemon defaults to all when
    /// `events` is omitted).
    public static let subscribe = DaemonCommand(cmd: "subscribe")
    public static let status = DaemonCommand(cmd: "status")
    public static let devices = DaemonCommand(cmd: "devices")
    public static let resume = DaemonCommand(cmd: "resume")
    public static let demarcate = DaemonCommand(cmd: "demarcate")

    /// Pause with a timed auto-resume window (seconds from now).
    public static func pause(autoResumeSeconds: Double) -> DaemonCommand {
        DaemonCommand(cmd: "pause", autoResumeSeconds: autoResumeSeconds)
    }

    /// Pause with no auto-resume timer (manual resume only).
    public static let pauseIndefinitely = DaemonCommand(cmd: "pause", indefinite: true)

    /// Toggle system-audio capture on the live session.
    public static func reconfigure(systemAudio: Bool) -> DaemonCommand {
        DaemonCommand(cmd: "reconfigure", systemAudio: systemAudio)
    }
}

/// A response from the daemon to a command.
public struct DaemonResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var sessionId: String?
    public var recording: Bool?
    public var segments: Int?
    public var devices: [String]?
    public var error: String?
    public var status: String?
    public var device: String?
    public var systemAudio: Bool?
    public var paused: Bool?
    public var pausedIndefinitely: Bool?
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
}

/// An event streamed from the daemon to a subscribed client.
///
/// `event` is always present; the rest depend on the event kind. The emitted
/// `event` string is snake_case for multi-word kinds (`pause_state`,
/// `model_processing`, `model_status`, `speaker_label`).
public struct DaemonEvent: Codable, Sendable, Equatable {
    public var event: String
    public var text: String?
    public var source: String?
    public var mic: Double?
    public var sys: Double?
    public var sessionId: String?
    public var sequenceNumber: Int?
    public var title: String?
    public var message: String?
    public var transient: Bool?
    public var recording: Bool?
    public var modelProcessing: Bool?
    public var startedAt: Double?
    public var paused: Bool?
    public var pausedIndefinitely: Bool?
    public var pauseExpiresAt: Double?
    public var speakerId: String?
    public var component: String?
    public var state: String?
    public var reason: String?

    public init(
        event: String,
        text: String? = nil,
        source: String? = nil,
        mic: Double? = nil,
        sys: Double? = nil,
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
        pauseExpiresAt: Double? = nil,
        speakerId: String? = nil,
        component: String? = nil,
        state: String? = nil,
        reason: String? = nil
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
        self.speakerId = speakerId
        self.component = component
        self.state = state
        self.reason = reason
    }
}

// MARK: - Wire vocabulary

/// Audio source identifiers used on `segment` / `partial` events and the
/// `segments.source` column.
public enum AudioSource: String, Sendable {
    case microphone
    case systemAudio
}

/// Event `event` string literals emitted by the daemon's EventBroadcaster.
public enum EventName {
    public static let partial = "partial"
    public static let segment = "segment"
    public static let level = "level"
    public static let status = "status"
    public static let topics = "topics"
    public static let pauseState = "pause_state"
    public static let modelProcessing = "model_processing"
    public static let modelStatus = "model_status"
    public static let speakerLabel = "speaker_label"
    public static let error = "error"
}
