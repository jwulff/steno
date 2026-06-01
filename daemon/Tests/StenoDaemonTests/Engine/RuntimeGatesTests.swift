import Testing
import Foundation
@testable import StenoDaemon

/// #62 — runtime gates & graceful fallbacks. Covers the Layer-A transcription
/// availability gate and the Layer-B diarization model-readiness surface.
@Suite("Runtime gates (#62)")
struct RuntimeGatesTests {

    // MARK: - Test engine builder (injects gate + diarizer mocks)

    @MainActor
    private func makeEngine(
        gate: TranscriptionModelGate,
        micDiarizer: (any DiarizationService)? = nil,
        sysDiarizer: (any DiarizationService)? = nil
    ) -> (RecordingEngine, MockTranscriptRepository, MockRecordingEngineDelegate) {
        let repo = MockTranscriptRepository()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: MockSummarizationService(),
            triggerCount: 100,
            timeThreshold: 3600
        )
        let delegate = MockRecordingEngineDelegate()
        let engine = RecordingEngine(
            repository: repo,
            permissionService: MockPermissionService(),
            summaryCoordinator: coordinator,
            audioSourceFactory: MockAudioSourceFactory(),
            speechRecognizerFactory: MockSpeechRecognizerFactory(),
            delegate: delegate,
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0,
            transcriptionGate: gate,
            micDiarizer: micDiarizer,
            sysDiarizer: sysDiarizer
        )
        return (engine, repo, delegate)
    }

    struct GateError: Error {}

    // MARK: - Layer A: transcription availability gate

    @Test("ready gate emits preparing→ready and records normally")
    func readyGateProceeds() async throws {
        let (engine, _, delegate) = await makeEngine(
            gate: ReadyTranscriptionModelGate()
        )

        _ = try await engine.start(locale: Locale(identifier: "en_US"))

        #expect(await engine.status == .recording)
        let statuses = await delegate.modelStatuses
            .filter { $0.0 == .transcription }
            .map { $0.1 }
        #expect(statuses == [.preparing, .ready])
    }

    @Test("unavailable gate degrades to .unsupported and surfaces the reason")
    func unavailableGateDegrades() async throws {
        let reason = "No 16-core Neural Engine."
        let gate = MockTranscriptionModelGate(outcome: .unavailable(reason: reason))
        let (engine, repo, delegate) = await makeEngine(gate: gate)

        await #expect(throws: RecordingEngineError.transcriptionUnavailable(reason)) {
            _ = try await engine.start(locale: Locale(identifier: "en_US"))
        }

        // Explicit terminal-but-alive state, not .error.
        #expect(await engine.status == .unsupported)
        // No session was created for an unsupported machine.
        #expect(await engine.currentSession == nil)
        #expect(try await repo.allSessions().isEmpty)

        // Surfaced the unavailable model_status with the reason …
        let transcriptionStatuses = await delegate.modelStatuses
            .filter { $0.0 == .transcription }
            .map { $0.1 }
        #expect(transcriptionStatuses == [.preparing, .unavailable(reason: reason)])
        // … and a non-transient error for older clients.
        let errors = await delegate.errors
        #expect(errors.contains { $0.0.contains(reason) && $0.1 == false })
    }

    @Test("gate is checked once — a restart after stop doesn't re-prepare")
    func gateIsIdempotentAcrossStarts() async throws {
        let gate = MockTranscriptionModelGate(outcome: .ready)
        let (engine, _, delegate) = await makeEngine(gate: gate)

        _ = try await engine.start(locale: Locale(identifier: "en_US"))
        await engine.stop()
        await delegate.reset()
        _ = try await engine.start(locale: Locale(identifier: "en_US"))

        // Prepared exactly once across both starts …
        #expect(await gate.prepareCallCount == 1)
        // … so the second start emits no transcription preparing/ready churn.
        let secondStartStatuses = await delegate.modelStatuses
            .filter { $0.0 == .transcription }
        #expect(secondStartStatuses.isEmpty)
    }

    // MARK: - Layer B: diarization model readiness

    @Test("diarization prepare success emits preparing→ready")
    func diarizationPrepareSucceeds() async throws {
        let mic = MockDiarizationService()
        let sys = MockDiarizationService()
        let (engine, _, delegate) = await makeEngine(
            gate: ReadyTranscriptionModelGate(),
            micDiarizer: mic,
            sysDiarizer: sys
        )
        _ = try await engine.start(locale: Locale(identifier: "en_US"))
        await delegate.reset()

        await engine.prepareDiarization()

        let diar = await delegate.modelStatuses
            .filter { $0.0 == .diarization }
            .map { $0.1 }
        #expect(diar == [.preparing, .ready])
        #expect(mic.prepareCallCount == 1)
        #expect(sys.prepareCallCount == 1)
    }

    @Test("diarization prepare failure degrades gracefully — transcript unaffected")
    func diarizationPrepareFailsGracefully() async throws {
        let mic = MockDiarizationService()
        mic.prepareError = GateError()
        let sys = MockDiarizationService()
        let (engine, _, delegate) = await makeEngine(
            gate: ReadyTranscriptionModelGate(),
            micDiarizer: mic,
            sysDiarizer: sys
        )
        _ = try await engine.start(locale: Locale(identifier: "en_US"))
        await delegate.reset()

        await engine.prepareDiarization()

        // Diarization reported unavailable …
        let diar = await delegate.modelStatuses.filter { $0.0 == .diarization }
        #expect(diar.contains { if case .unavailable = $0.1 { return true } else { return false } })
        // … mirrored as a transient (non-fatal) error …
        let errors = await delegate.errors
        #expect(errors.contains { $0.0.contains("Diarization models failed") && $0.1 == true })
        // … and the transcript pipeline keeps running.
        #expect(await engine.status == .recording)
    }

    // MARK: - ModelReadiness value type

    @Test("ModelReadiness wire tokens and reason")
    func modelReadinessWire() {
        #expect(ModelReadiness.preparing.wireState == "preparing")
        #expect(ModelReadiness.ready.wireState == "ready")
        #expect(ModelReadiness.unavailable(reason: "x").wireState == "unavailable")
        #expect(ModelReadiness.preparing.reason == nil)
        #expect(ModelReadiness.ready.reason == nil)
        #expect(ModelReadiness.unavailable(reason: "boom").reason == "boom")
    }
}
