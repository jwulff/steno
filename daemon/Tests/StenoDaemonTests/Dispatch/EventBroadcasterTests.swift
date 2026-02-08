import Testing
import Foundation
@testable import StenoDaemon

@Suite("EventBroadcaster Tests")
struct EventBroadcasterTests {

    @Test func subscribedClientReceivesEvent() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()

        await broadcaster.subscribe(client: client, events: [.partial])

        // Simulate engine event
        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .partialText("hello", .microphone))

        let events = await client.sentEvents
        #expect(events.count == 1)
        #expect(events[0].event == "partial")
        #expect(events[0].text == "hello")
        #expect(events[0].source == "microphone")
    }

    @Test func unsubscribedClientDoesNotReceive() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()

        await broadcaster.subscribe(client: client, events: [.level])

        // Send a partial event — client is only subscribed to level
        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .partialText("hello", .microphone))

        let events = await client.sentEvents
        #expect(events.isEmpty)
    }

    @Test func disconnectedClientRemoved() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await client.setShouldThrow(true)

        await broadcaster.subscribe(client: client, events: [.partial])

        let engine = await makeTestEngine()

        // First send fails — client should be removed
        await broadcaster.engine(engine, didEmit: .partialText("hello", .microphone))

        // Reset the throw flag
        await client.reset()

        // Second send should not reach client (already removed)
        await broadcaster.engine(engine, didEmit: .partialText("world", .microphone))

        let events = await client.sentEvents
        #expect(events.isEmpty)
    }

    @Test func segmentEventMapped() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await broadcaster.subscribe(client: client, events: [.segment])

        let segment = StoredSegment(
            sessionId: UUID(),
            text: "test segment",
            startedAt: Date(),
            endedAt: Date(),
            sequenceNumber: 5,
            source: .systemAudio
        )

        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .segmentFinalized(segment))

        let events = await client.sentEvents
        #expect(events.count == 1)
        #expect(events[0].event == "segment")
        #expect(events[0].text == "test segment")
        #expect(events[0].source == "systemAudio")
        #expect(events[0].sequenceNumber == 5)
    }

    @Test func statusEventMapped() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await broadcaster.subscribe(client: client, events: [.status])

        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .statusChanged(.recording))

        let events = await client.sentEvents
        #expect(events.count == 1)
        #expect(events[0].event == "status")
        #expect(events[0].recording == true)
    }

    @Test func errorEventMapped() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await broadcaster.subscribe(client: client, events: [.error])

        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .error("mic failed", isTransient: true))

        let events = await client.sentEvents
        #expect(events.count == 1)
        #expect(events[0].event == "error")
        #expect(events[0].message == "mic failed")
        #expect(events[0].transient == true)
    }

    @Test func modelProcessingEventMapped() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await broadcaster.subscribe(client: client, events: [.modelProcessing])

        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .modelProcessing(true))

        let events = await client.sentEvents
        #expect(events.count == 1)
        #expect(events[0].event == "model_processing")
        #expect(events[0].modelProcessing == true)
    }

    @Test func topicsEventMapped() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await broadcaster.subscribe(client: client, events: [.topics])

        let topics = [
            Topic(sessionId: UUID(), title: "Budget", summary: "Review.", segmentRange: 1...3),
            Topic(sessionId: UUID(), title: "Hiring", summary: "Plan.", segmentRange: 4...6)
        ]

        let engine = await makeTestEngine()
        await broadcaster.engine(engine, didEmit: .topicsUpdated(topics))

        let events = await client.sentEvents
        #expect(events.count == 1)
        #expect(events[0].event == "topics")
        #expect(events[0].title == "Budget, Hiring")
    }

    @Test func unsubscribeStopsDelivery() async throws {
        let broadcaster = EventBroadcaster()
        let client = MockClientConnection()
        await broadcaster.subscribe(client: client, events: [.partial])

        let engine = await makeTestEngine()

        // First event delivered
        await broadcaster.engine(engine, didEmit: .partialText("hello", .microphone))
        let count1 = await client.sentEvents.count
        #expect(count1 == 1)

        // Unsubscribe
        await broadcaster.unsubscribe(client.id)

        // Second event not delivered
        await broadcaster.engine(engine, didEmit: .partialText("world", .microphone))
        let count2 = await client.sentEvents.count
        #expect(count2 == 1)
    }

    // MARK: - Helpers

    @MainActor
    private func makeTestEngine() -> RecordingEngine {
        RecordingEngine(
            repository: MockTranscriptRepository(),
            permissionService: MockPermissionService(),
            summaryCoordinator: RollingSummaryCoordinator(
                repository: MockTranscriptRepository(),
                summarizer: MockSummarizationService()
            ),
            audioSourceFactory: MockAudioSourceFactory(),
            speechRecognizerFactory: MockSpeechRecognizerFactory()
        )
    }
}

// Helper to set the flag on MockClientConnection
extension MockClientConnection {
    func setShouldThrow(_ value: Bool) {
        shouldThrowOnSend = value
    }
}
