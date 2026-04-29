import Foundation

/// Event types that clients can subscribe to.
public enum EventType: String, Sendable, Codable, CaseIterable {
    case partial
    case level
    case segment
    case topics
    case status
    case modelProcessing
    case error
}

/// Broadcasts engine events to subscribed socket clients.
///
/// Maintains a subscription map: each client can subscribe to specific event types.
/// Maps EngineEvent → DaemonEvent → NDJSON and sends to subscribed clients.
public actor EventBroadcaster: RecordingEngineDelegate {
    private var subscriptions: [UUID: (client: any ClientConnection, events: Set<EventType>)] = [:]
    private let encoder = JSONEncoder()

    public init() {}

    /// Subscribe a client to receive specific event types.
    public func subscribe(
        client: any ClientConnection,
        events: Set<EventType>
    ) {
        subscriptions[client.id] = (client: client, events: events)
    }

    /// Unsubscribe a client.
    public func unsubscribe(_ clientId: UUID) {
        subscriptions.removeValue(forKey: clientId)
    }

    // MARK: - RecordingEngineDelegate

    nonisolated public func engine(_ engine: RecordingEngine, didEmit event: EngineEvent) async {
        await broadcast(event)
    }

    private func broadcast(_ event: EngineEvent) async {
        let (eventType, daemonEvent) = mapEvent(event)

        guard let data = try? encoder.encode(daemonEvent) else { return }
        let line = data + Data("\n".utf8)

        var disconnected: [UUID] = []

        for (id, sub) in subscriptions {
            guard sub.events.contains(eventType) else { continue }
            do {
                try await sub.client.send(line)
            } catch {
                // Client disconnected — mark for removal
                disconnected.append(id)
            }
        }

        for id in disconnected {
            subscriptions.removeValue(forKey: id)
        }
    }

    private func mapEvent(_ event: EngineEvent) -> (EventType, DaemonEvent) {
        switch event {
        case .partialText(let text, let source):
            return (.partial, DaemonEvent(
                event: "partial",
                text: text,
                source: source.rawValue
            ))

        case .audioLevel(let mic, let sys):
            return (.level, DaemonEvent(
                event: "level",
                mic: mic,
                sys: sys
            ))

        case .segmentFinalized(let segment):
            return (.segment, DaemonEvent(
                event: "segment",
                text: segment.text,
                source: segment.source.rawValue,
                sessionId: segment.sessionId.uuidString,
                sequenceNumber: segment.sequenceNumber,
                startedAt: segment.startedAt.timeIntervalSince1970
            ))

        case .topicsUpdated(let topics):
            // Send just the titles as a simple signal; clients query DB for full data
            return (.topics, DaemonEvent(
                event: "topics",
                title: topics.map(\.title).joined(separator: ", ")
            ))

        case .statusChanged(let status):
            return (.status, DaemonEvent(
                event: "status",
                recording: status == .recording
            ))

        case .modelProcessing(let isProcessing):
            return (.modelProcessing, DaemonEvent(
                event: "model_processing",
                modelProcessing: isProcessing
            ))

        case .error(let message, let isTransient):
            return (.error, DaemonEvent(
                event: "error",
                message: message,
                transient: isTransient
            ))

        // U5: the new restart/heal events are routed onto the existing
        // `.error` wire channel with the `transient` flag distinguishing
        // surrender (non-transient) from in-progress recovery (transient).
        // U9 will introduce dedicated wire-protocol fields and TUI
        // surfaces for these — the placeholder mapping here keeps the
        // event payload visible without expanding the protocol mid-cluster.
        case .recovering(let reason):
            return (.error, DaemonEvent(
                event: "error",
                message: "recovering: \(reason)",
                transient: true
            ))

        case .healed(let gapSeconds):
            return (.error, DaemonEvent(
                event: "error",
                message: "healed: gap=\(gapSeconds)s",
                transient: true
            ))

        case .recoveryExhausted(let reason):
            return (.error, DaemonEvent(
                event: "error",
                message: "recovery_exhausted: \(reason)",
                transient: false
            ))

        // U10: pause-state broadcast. Routed onto the existing `.status`
        // wire channel so a connecting TUI sees pause/resume transitions
        // alongside .recording / .idle. The dedicated pause-state fields
        // on `DaemonEvent` (paused / pausedIndefinitely / pauseExpiresAt)
        // carry the precise state. U9's TUI surface reads those.
        case .pauseStateChanged(let paused, let indefinite, let expiresAt):
            return (.status, DaemonEvent(
                event: "pause_state",
                paused: paused,
                pausedIndefinitely: indefinite,
                pauseExpiresAt: expiresAt?.timeIntervalSince1970
            ))
        }
    }
}
