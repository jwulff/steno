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
                sequenceNumber: segment.sequenceNumber
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
        }
    }
}
