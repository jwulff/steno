import Foundation

/// High-level engine state the UI renders. Mirrors the daemon's
/// `EngineStatus` raw values, plus client-side connection states the daemon
/// itself never reports.
public enum EngineStatus: String, Sendable, Equatable {
    case unknown = ""
    case idle
    case starting
    case recording
    case stopping
    case paused
    case recovering
    case error

    // Client-side only:
    case connecting
    case disconnected

    public init(daemonStatus: String?) {
        self = EngineStatus(rawValue: daemonStatus ?? "") ?? .unknown
    }
}

/// A finalized or in-flight transcript line shown in the UI.
public struct TranscriptEntry: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case segment        // finalized
        case partial        // live-typing
        case sessionBoundary
    }

    public var id: String
    public var kind: Kind
    public var source: AudioSource?
    public var text: String
    public var startedAt: Date
    public var sequenceNumber: Int?
    public var speakerId: String?
    public var healMarker: String?

    public init(
        id: String,
        kind: Kind,
        source: AudioSource?,
        text: String,
        startedAt: Date,
        sequenceNumber: Int? = nil,
        speakerId: String? = nil,
        healMarker: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.text = text
        self.startedAt = startedAt
        self.sequenceNumber = sequenceNumber
        self.speakerId = speakerId
        self.healMarker = healMarker
    }
}

/// A topic row (left sidebar), read from SQLite.
public struct Topic: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var summary: String
    public var rangeStart: Int
    public var rangeEnd: Int
    public var createdAt: Date

    public init(id: String, title: String, summary: String, rangeStart: Int, rangeEnd: Int, createdAt: Date) {
        self.id = id
        self.title = title
        self.summary = summary
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.createdAt = createdAt
    }
}

/// A summary row, read from SQLite.
public struct Summary: Sendable, Equatable {
    public var content: String
    public var summaryType: String
    public var createdAt: Date

    public init(content: String, summaryType: String, createdAt: Date) {
        self.content = content
        self.summaryType = summaryType
        self.createdAt = createdAt
    }
}

/// Model-readiness for one pipeline component (#62).
public struct ComponentReadiness: Sendable, Equatable {
    public enum State: String, Sendable { case preparing, ready, unavailable, unknown }
    public var state: State
    public var reason: String?

    public init(state: State = .unknown, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }
}
