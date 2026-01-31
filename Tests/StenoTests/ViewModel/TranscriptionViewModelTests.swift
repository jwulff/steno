import Testing
import Foundation
@testable import Steno

@Suite("TranscriptionViewModel Tests")
@MainActor
struct TranscriptionViewModelTests {
    let mockSpeechService = MockSpeechService()
    let mockPermissionService = MockPermissionService()

    // MARK: - Initial State Tests

    @Test func initialState() async {
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        #expect(viewModel.isListening == false)
        #expect(viewModel.segments.isEmpty)
        #expect(viewModel.partialText == "")
        #expect(viewModel.error == nil)
    }

    // MARK: - Start/Stop Listening Tests

    @Test func startListeningSetsIsListening() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()

        // Give the stream time to start
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.isListening == true)
        #expect(mockSpeechService.startCalled == true)
    }

    @Test func stopListeningClearsIsListening() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        await viewModel.stopListening()

        #expect(viewModel.isListening == false)
        #expect(mockSpeechService.stopCalled == true)
    }

    // MARK: - Partial Results Tests

    @Test func partialResultUpdatesPartialText() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        let partialResult = TranscriptionResult(
            text: "hello wor",
            isFinal: false,
            confidence: nil,
            timestamp: Date()
        )
        mockSpeechService.emit(partialResult)
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.partialText == "hello wor")
    }

    @Test func partialTextClearsOnFinalResult() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        // First send a partial result
        let partialResult = TranscriptionResult(
            text: "hello wor",
            isFinal: false,
            timestamp: Date()
        )
        mockSpeechService.emit(partialResult)
        try await Task.sleep(for: .milliseconds(50))

        // Then send a final result
        let finalResult = TranscriptionResult(
            text: "hello world",
            isFinal: true,
            confidence: 0.95,
            timestamp: Date()
        )
        mockSpeechService.emit(finalResult)
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.partialText == "")
    }

    // MARK: - Final Results Tests

    @Test func finalResultAddsSegment() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        let timestamp = Date()
        let finalResult = TranscriptionResult(
            text: "hello world",
            isFinal: true,
            confidence: 0.95,
            timestamp: timestamp
        )
        mockSpeechService.emit(finalResult)
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.segments.count == 1)
        #expect(viewModel.segments.first?.text == "hello world")
        #expect(viewModel.segments.first?.confidence == 0.95)
    }

    @Test func multipleFinalResultsAccumulate() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        mockSpeechService.emit(TranscriptionResult(text: "first", isFinal: true, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(50))

        mockSpeechService.emit(TranscriptionResult(text: "second", isFinal: true, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(50))

        mockSpeechService.emit(TranscriptionResult(text: "third", isFinal: true, timestamp: Date()))
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.segments.count == 3)
        #expect(viewModel.fullText == "first second third")
    }

    // MARK: - Error Handling Tests

    @Test func errorFromServiceSetsErrorState() async throws {
        mockPermissionService.grantAll()
        mockSpeechService.errorToThrow = SpeechRecognitionError.audioInputUnavailable

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.error != nil)
    }

    @Test func errorStopsListening() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        mockSpeechService.finishWithError(SpeechRecognitionError.recognitionFailed("test"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.isListening == false)
    }

    @Test func canRestartAfterError() async throws {
        mockPermissionService.grantAll()
        mockSpeechService.errorToThrow = SpeechRecognitionError.audioInputUnavailable

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        // First attempt fails
        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.error != nil)

        // Clear the error for the second attempt
        mockSpeechService.reset()
        viewModel.clearError()

        // Second attempt should work
        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.isListening == true)
        #expect(viewModel.error == nil)
    }

    // MARK: - Permission Tests

    @Test func startRequiresPermissions() async throws {
        mockPermissionService.grantAll()
        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        #expect(mockPermissionService.permissionsChecked == true)
    }

    @Test func deniedPermissionSetsError() async throws {
        mockPermissionService.denyAll()

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.error != nil)
        #expect(viewModel.isListening == false)
    }

    // MARK: - Persistence Tests

    @Test func createsSessionOnStartWithRepository() async throws {
        mockPermissionService.grantAll()
        let mockRepo = MockTranscriptRepository()

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService,
            repository: mockRepo
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.currentSession != nil)
        let sessions = try await mockRepo.allSessions()
        #expect(sessions.count == 1)
    }

    @Test func savesSegmentsToRepository() async throws {
        mockPermissionService.grantAll()
        let mockRepo = MockTranscriptRepository()

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService,
            repository: mockRepo
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        let finalResult = TranscriptionResult(
            text: "hello world",
            isFinal: true,
            confidence: 0.95,
            timestamp: Date()
        )
        mockSpeechService.emit(finalResult)
        try await Task.sleep(for: .milliseconds(100))

        guard let session = viewModel.currentSession else {
            Issue.record("No session created")
            return
        }

        let storedSegments = try await mockRepo.segments(for: session.id)
        #expect(storedSegments.count == 1)
        #expect(storedSegments.first?.text == "hello world")
    }

    @Test func endsSessionOnStop() async throws {
        mockPermissionService.grantAll()
        let mockRepo = MockTranscriptRepository()

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService,
            repository: mockRepo
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        let sessionId = viewModel.currentSession?.id

        await viewModel.stopListening()
        try await Task.sleep(for: .milliseconds(50))

        guard let id = sessionId else {
            Issue.record("No session was created")
            return
        }

        let session = try await mockRepo.session(id)
        #expect(session?.status == .completed)
        #expect(session?.endedAt != nil)
    }

    @Test func worksWithoutRepository() async throws {
        mockPermissionService.grantAll()

        let viewModel = TranscriptionViewModel(
            speechService: mockSpeechService,
            permissionService: mockPermissionService
            // No repository provided
        )

        await viewModel.startListening()
        try await Task.sleep(for: .milliseconds(50))

        let finalResult = TranscriptionResult(
            text: "no persistence",
            isFinal: true,
            timestamp: Date()
        )
        mockSpeechService.emit(finalResult)
        try await Task.sleep(for: .milliseconds(50))

        // Should still work without persistence
        #expect(viewModel.segments.count == 1)
        #expect(viewModel.currentSession == nil)
    }
}
