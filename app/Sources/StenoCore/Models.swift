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

/// Overall health of the daemon process, as the app sees it. Combines socket
/// reachability, engine status, and whether the process is actually running.
public enum DaemonHealth: String, Sendable {
    case healthy        // connected, engine recording/idle
    case paused         // connected, intentionally paused
    case recovering     // engine restarting its pipeline
    case error          // engine reported an error (often missing permission)
    case unreachable    // process up but socket not responding
    case stopped        // no daemon process running
    case restarting     // we're restarting it right now
    case connecting     // initial connect in progress

    public enum Severity: Sendable { case ok, warn, bad, neutral }

    public var severity: Severity {
        switch self {
        case .healthy: return .ok
        case .paused, .recovering, .connecting, .restarting: return .warn
        case .error, .unreachable, .stopped: return .bad
        }
    }

    public var title: String {
        switch self {
        case .healthy: return "Engine healthy"
        case .paused: return "Engine paused"
        case .recovering: return "Engine recovering"
        case .error: return "Engine error"
        case .unreachable: return "Engine unreachable"
        case .stopped: return "Engine stopped"
        case .restarting: return "Restarting…"
        case .connecting: return "Connecting…"
        }
    }

    public var symbol: String {
        switch self {
        case .healthy: return "bolt.heart.fill"
        case .paused: return "pause.circle.fill"
        case .recovering, .connecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .unreachable: return "bolt.horizontal.circle"
        case .stopped: return "bolt.slash.fill"
        case .restarting: return "arrow.triangle.2.circlepath"
        }
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
