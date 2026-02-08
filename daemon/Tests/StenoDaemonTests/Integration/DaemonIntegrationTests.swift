import AVFoundation
import Foundation
import Testing

@testable import StenoDaemon

@Suite("Daemon Integration Tests")
struct DaemonIntegrationTests {
    @Test @MainActor func fullPipelineStartToStop() async throws {
        // 1. Set up all mock dependencies
        let repository = MockTranscriptRepository()
        let permissionService = MockPermissionService()
        let summarizer = MockSummarizationService()
        await summarizer.setSummaryToReturn("Test summary")
        let summaryCoordinator = RollingSummaryCoordinator(
            repository: repository,
            summarizer: summarizer
        )

        let audioFactory = MockAudioSourceFactory()
        let recognizerFactory = MockSpeechRecognizerFactory()
        let recognizerHandle = recognizerFactory.handle

        let broadcaster = EventBroadcaster()
        let engine = RecordingEngine(
            repository: repository,
            permissionService: permissionService,
            summaryCoordinator: summaryCoordinator,
            audioSourceFactory: audioFactory,
            speechRecognizerFactory: recognizerFactory,
            delegate: broadcaster
        )

        let dispatcher = CommandDispatcher(engine: engine, broadcaster: broadcaster)

        // 2. Subscribe a client to events
        let client = MockClientConnection()
        let subscribeCmd = DaemonCommand(
            cmd: "subscribe",
            locale: nil, device: nil, systemAudio: nil,
            events: ["partial", "status", "segment"]
        )
        await dispatcher.handle(subscribeCmd, from: client)

        // Check subscription response was sent
        let subResponses = await client.sentResponses
        #expect(subResponses.count == 1)
        #expect(subResponses.first?.ok == true)

        // 3. Start recording
        let startCmd = DaemonCommand(
            cmd: "start",
            locale: nil, device: nil, systemAudio: nil,
            events: nil
        )
        await dispatcher.handle(startCmd, from: client)

        let startResponses = await client.sentResponses
        // Now 2 responses: subscribe + start
        #expect(startResponses.count == 2)
        let startResponse = startResponses[1]
        #expect(startResponse.ok)
        #expect(startResponse.sessionId != nil)

        // 4. Emit a partial recognizer result
        recognizerHandle.emit(RecognizerResult(
            text: "hello world",
            isFinal: false,
            source: .microphone
        ))

        // Give async event propagation time
        try await Task.sleep(for: .milliseconds(100))

        // 5. Emit a final result
        recognizerHandle.emit(RecognizerResult(
            text: "hello world",
            isFinal: true,
            source: .microphone
        ))

        try await Task.sleep(for: .milliseconds(100))

        // 6. Check status
        let statusCmd = DaemonCommand(
            cmd: "status",
            locale: nil, device: nil, systemAudio: nil,
            events: nil
        )
        await dispatcher.handle(statusCmd, from: client)

        let statusResponses = await client.sentResponses
        let statusResponse = statusResponses.last!
        #expect(statusResponse.ok)
        #expect(statusResponse.recording == true)

        // 7. Stop recording
        let stopCmd = DaemonCommand(
            cmd: "stop",
            locale: nil, device: nil, systemAudio: nil,
            events: nil
        )
        await dispatcher.handle(stopCmd, from: client)

        // 8. Verify engine is idle via status
        await dispatcher.handle(statusCmd, from: client)
        let allResponses = await client.sentResponses
        let finalStatus = allResponses.last!
        #expect(finalStatus.recording == false)

        // 9. Verify client received events
        let events = await client.sentEvents
        #expect(events.count > 0)

        // Should have at least one status change event
        let statusEvents = events.filter { $0.event == "status" }
        #expect(statusEvents.count >= 1)
    }

    @Test func pidFileAcquireAndRelease() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-integration-\(UUID().uuidString).pid").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pidFile = PIDFile(path: path)
        #expect(try pidFile.acquire())

        // Second acquire should fail (our process is running)
        let pidFile2 = PIDFile(path: path)
        #expect(try !pidFile2.acquire())

        // Release and re-acquire should work
        pidFile.release()
        #expect(try pidFile2.acquire())

        pidFile2.release()
    }
}
