import Foundation

/// A command sent from a client to the daemon over the Unix socket.
public struct DaemonCommand: Codable, Sendable {
    public let cmd: String
    public let locale: String?
    public let device: String?
    public let systemAudio: Bool?
    public let events: [String]?

    public init(
        cmd: String,
        locale: String? = nil,
        device: String? = nil,
        systemAudio: Bool? = nil,
        events: [String]? = nil
    ) {
        self.cmd = cmd
        self.locale = locale
        self.device = device
        self.systemAudio = systemAudio
        self.events = events
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

    public init(
        ok: Bool,
        sessionId: String? = nil,
        recording: Bool? = nil,
        segments: Int? = nil,
        devices: [String]? = nil,
        error: String? = nil,
        status: String? = nil,
        device: String? = nil,
        systemAudio: Bool? = nil
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
        modelProcessing: Bool? = nil
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
    }
}
