import Testing
import Foundation
@testable import StenoDaemon

@Suite("CommandDispatcher Tests")
struct CommandDispatcherTests {

    @MainActor
    private func makeDispatcher() -> (
        dispatcher: CommandDispatcher,
        engine: RecordingEngine,
        broadcaster: EventBroadcaster
    ) {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )

        let engine = RecordingEngine(
            repository: repo,
            permissionService: MockPermissionService(),
            summaryCoordinator: coordinator,
            audioSourceFactory: MockAudioSourceFactory(),
            speechRecognizerFactory: MockSpeechRecognizerFactory()
        )

        let broadcaster = EventBroadcaster()
        let dispatcher = CommandDispatcher(engine: engine, broadcaster: broadcaster)

        return (dispatcher, engine, broadcaster)
    }

    @Test @MainActor func startCommandStartsEngine() async throws {
        let (dispatcher, engine, _) = makeDispatcher()
        let client = MockClientConnection()

        let command = DaemonCommand(cmd: "start", locale: "en_US")
        await dispatcher.handle(command, from: client)

        let status = await engine.status
        #expect(status == .recording)

        // Response should have sessionId
        let responses = await client.sentResponses
        #expect(responses.count == 1)
        #expect(responses[0].ok == true)
        #expect(responses[0].sessionId != nil)
        #expect(responses[0].recording == true)

        await engine.stop()
    }

    @Test @MainActor func stopCommandStopsEngine() async throws {
        let (dispatcher, engine, _) = makeDispatcher()
        let client = MockClientConnection()

        // Start first
        _ = try await engine.start()

        let command = DaemonCommand(cmd: "stop")
        await dispatcher.handle(command, from: client)

        let status = await engine.status
        #expect(status == .idle)

        let responses = await client.sentResponses
        #expect(responses.count == 1)
        #expect(responses[0].ok == true)
        #expect(responses[0].recording == false)
    }

    @Test @MainActor func statusCommandReturnsState() async throws {
        let (dispatcher, engine, _) = makeDispatcher()
        let client = MockClientConnection()

        let command = DaemonCommand(cmd: "status")
        await dispatcher.handle(command, from: client)

        let responses = await client.sentResponses
        #expect(responses.count == 1)
        #expect(responses[0].ok == true)
        #expect(responses[0].status == "idle")
        #expect(responses[0].recording == false)
    }

    @Test @MainActor func devicesCommandReturnsList() async throws {
        let (dispatcher, _, _) = makeDispatcher()
        let client = MockClientConnection()

        let command = DaemonCommand(cmd: "devices")
        await dispatcher.handle(command, from: client)

        let responses = await client.sentResponses
        #expect(responses.count == 1)
        #expect(responses[0].ok == true)
        #expect(responses[0].devices != nil)
    }

    @Test @MainActor func subscribeCommandSubscribesClient() async throws {
        let (dispatcher, _, broadcaster) = makeDispatcher()
        let client = MockClientConnection()

        let command = DaemonCommand(cmd: "subscribe", events: ["partial", "segment"])
        await dispatcher.handle(command, from: client)

        let responses = await client.sentResponses
        #expect(responses.count == 1)
        #expect(responses[0].ok == true)

        // Verify subscription works by sending an event through broadcaster
        let engine = await makeMinimalEngine()
        await broadcaster.engine(engine, didEmit: .partialText("test", .microphone))

        let events = await client.sentEvents
        #expect(events.count == 1)
    }

    @Test @MainActor func unknownCommandReturnsError() async throws {
        let (dispatcher, _, _) = makeDispatcher()
        let client = MockClientConnection()

        let command = DaemonCommand(cmd: "unknown")
        await dispatcher.handle(command, from: client)

        let responses = await client.sentResponses
        #expect(responses.count == 1)
        #expect(responses[0].ok == false)
        #expect(responses[0].error?.contains("Unknown command") == true)
    }

    // MARK: - Helper

    @MainActor
    private func makeMinimalEngine() -> RecordingEngine {
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
