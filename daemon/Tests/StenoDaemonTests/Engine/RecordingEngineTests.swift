import Testing
import Foundation
@testable import StenoDaemon

@Suite("RecordingEngine Tests")
struct RecordingEngineTests {

    // MARK: - Helpers

    @MainActor
    private func makeEngine(
        permissionService: MockPermissionService? = nil,
        summarizer: MockSummarizationService? = nil,
        audioFactory: MockAudioSourceFactory? = nil,
        recognizerFactory: MockSpeechRecognizerFactory? = nil,
        delegate: MockRecordingEngineDelegate? = nil
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        permissions: MockPermissionService,
        summarizer: MockSummarizationService,
        audioFactory: MockAudioSourceFactory,
        recognizerFactory: MockSpeechRecognizerFactory,
        delegate: MockRecordingEngineDelegate
    ) {
        let repo = MockTranscriptRepository()
        let perms = permissionService ?? MockPermissionService()
        let summ = summarizer ?? MockSummarizationService()
        let af = audioFactory ?? MockAudioSourceFactory()
        let rf = recognizerFactory ?? MockSpeechRecognizerFactory()
        let del = delegate ?? MockRecordingEngineDelegate()

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summ,
            triggerCount: 100,  // High threshold to avoid accidental triggers in basic tests
            timeThreshold: 3600
        )

        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del
        )

        return (engine, repo, perms, summ, af, rf, del)
    }

    // MARK: - Start / Status

    @Test func startCreatesSessionAndTransitionsToRecording() async throws {
        let (engine, repo, _, _, _, _, delegate) = await makeEngine()

        let session = try await engine.start(locale: Locale(identifier: "en_US"))

        let status = await engine.status
        let currentSession = await engine.currentSession

        #expect(status == .recording)
        #expect(currentSession?.id == session.id)

        // Verify session persisted
        let fetched = try await repo.session(session.id)
        #expect(fetched != nil)
        #expect(fetched?.locale.identifier == "en_US")

        // Verify status transitions: starting → recording
        let statuses = await delegate.statusChanges
        #expect(statuses.contains(.starting))
        #expect(statuses.contains(.recording))

        await engine.stop()
    }

    @Test func startEmitsPartialTextFromRecognizer() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.resultsToYield = [
            RecognizerResult(text: "hello", isFinal: false, source: .microphone)
        ]

        let (engine, _, _, _, _, _, delegate) = await makeEngine(recognizerFactory: rf)

        _ = try await engine.start()

        // Give the recognizer task time to process
        try await Task.sleep(for: .milliseconds(50))

        let partials = await delegate.partialTexts
        #expect(partials.count >= 1)
        #expect(partials[0].0 == "hello")
        #expect(partials[0].1 == .microphone)

        await engine.stop()
    }

    @Test func finalResultsPersistedAsSegments() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.resultsToYield = [
            RecognizerResult(text: "hello world", isFinal: true, confidence: 0.95, source: .microphone)
        ]

        let (engine, repo, _, _, _, _, delegate) = await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()

        // Give the recognizer task time to process
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 1)
        #expect(segments[0].text == "hello world")
        #expect(segments[0].sequenceNumber == 1)
        #expect(segments[0].source == .microphone)

        let finalized = await delegate.finalizedSegments
        #expect(finalized.count == 1)

        await engine.stop()
    }

    @Test func stopEndsSessionAndTransitionsToIdle() async throws {
        let (engine, repo, _, _, _, _, delegate) = await makeEngine()

        let session = try await engine.start()
        await engine.stop()

        let status = await engine.status
        #expect(status == .idle)

        // Session should be ended
        let ended = try await repo.session(session.id)
        #expect(ended?.status == .completed)

        let statuses = await delegate.statusChanges
        #expect(statuses.contains(.stopping))
        #expect(statuses.last == .idle)
    }

    @Test @MainActor func permissionDeniedThrows() async throws {
        let perms = MockPermissionService()
        perms.denyAll()

        let (engine, _, _, _, _, _, delegate) = await makeEngine(permissionService: perms)

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.start()
        }

        let status = await engine.status
        #expect(status == .error)

        let errors = await delegate.errors
        #expect(!errors.isEmpty)
        #expect(errors[0].1 == false) // isTransient = false
    }

    @Test func segmentsTriggerSummaryCoordinator() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let del = MockRecordingEngineDelegate()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let perms = await MainActor.run { MockPermissionService() }

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1,  // Trigger on every segment
            timeThreshold: 0
        )

        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del
        )

        // Set up a final result to trigger summarization
        rf.handle.resultsToYield = [
            RecognizerResult(text: "test segment", isFinal: true, source: .microphone)
        ]

        _ = try await engine.start()
        try await Task.sleep(for: .milliseconds(100))

        let callCount = await summarizer.summarizeCallCount
        #expect(callCount >= 1)

        await engine.stop()
    }

    @Test func modelProcessingEventsEmittedDuringSummarization() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let del = MockRecordingEngineDelegate()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let perms = await MainActor.run { MockPermissionService() }

        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1,
            timeThreshold: 0
        )

        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del
        )

        rf.handle.resultsToYield = [
            RecognizerResult(text: "test segment", isFinal: true, source: .microphone)
        ]

        _ = try await engine.start()
        try await Task.sleep(for: .milliseconds(100))

        let processingStates = await del.modelProcessingStates
        // Should have true (start) and false (end)
        #expect(processingStates.contains(true))
        #expect(processingStates.contains(false))

        await engine.stop()
    }

    @Test func errorFromRecognizerEmitsErrorEvent() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.errorToThrow = SpeechRecognitionError.recognitionFailed("test failure")

        let (engine, _, _, _, _, _, delegate) = await makeEngine(recognizerFactory: rf)

        _ = try await engine.start()
        try await Task.sleep(for: .milliseconds(50))

        let errors = await delegate.errors
        #expect(!errors.isEmpty)
        #expect(errors[0].1 == true) // isTransient = true

        await engine.stop()
    }

    @Test func doubleStartThrowsAlreadyRecording() async throws {
        let (engine, _, _, _, _, _, _) = await makeEngine()

        _ = try await engine.start()

        await #expect(throws: RecordingEngineError.self) {
            _ = try await engine.start()
        }

        await engine.stop()
    }

    @Test func emptyFinalResultNotPersisted() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.resultsToYield = [
            RecognizerResult(text: "", isFinal: true, source: .microphone)
        ]

        let (engine, repo, _, _, _, _, _) = await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        #expect(segments.isEmpty)

        await engine.stop()
    }
}
