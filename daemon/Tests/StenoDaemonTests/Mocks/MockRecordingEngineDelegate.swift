import Foundation
@testable import StenoDaemon

/// Mock delegate that collects engine events for test assertions.
actor MockRecordingEngineDelegate: RecordingEngineDelegate {
    private(set) var events: [EngineEvent] = []

    nonisolated func engine(_ engine: RecordingEngine, didEmit event: EngineEvent) async {
        await appendEvent(event)
    }

    private func appendEvent(_ event: EngineEvent) {
        events.append(event)
    }

    /// All status change events.
    var statusChanges: [EngineStatus] {
        events.compactMap {
            if case .statusChanged(let status) = $0 { return status }
            return nil
        }
    }

    /// All finalized segments.
    var finalizedSegments: [StoredSegment] {
        events.compactMap {
            if case .segmentFinalized(let segment) = $0 { return segment }
            return nil
        }
    }

    /// All partial text events.
    var partialTexts: [(String, AudioSourceType)] {
        events.compactMap {
            if case .partialText(let text, let source) = $0 { return (text, source) }
            return nil
        }
    }

    /// All error events.
    var errors: [(String, Bool)] {
        events.compactMap {
            if case .error(let message, let isTransient) = $0 { return (message, isTransient) }
            return nil
        }
    }

    /// All modelProcessing events.
    var modelProcessingStates: [Bool] {
        events.compactMap {
            if case .modelProcessing(let state) = $0 { return state }
            return nil
        }
    }

    /// All topicsUpdated events.
    var topicUpdates: [[Topic]] {
        events.compactMap {
            if case .topicsUpdated(let topics) = $0 { return topics }
            return nil
        }
    }

    func reset() {
        events.removeAll()
    }
}
