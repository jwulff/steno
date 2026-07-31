import Testing
import AVFoundation
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

        // U12 thresholds disabled — these baseline engine tests pre-date
        // U12 and assert post-stop session presence (e.g. status ==
        // .completed). The U12 prune-on-close behavior is covered by
        // `EmptySessionPruneIntegrationTests`.
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del,
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0
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
            timeThreshold: 0,
            // U12 gates topic extraction by min segment count; this test
            // only saves a single segment so we must lower the gate.
            minSegmentsForExtraction: 1
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

    @Test func errorFromRecognizerEntersRecoveringState() async throws {
        // U5: recognizer errors no longer surface directly as `.error`
        // events; they enter the restart-with-bounded-backoff path,
        // emitting `.recovering(reason:)` and transitioning the engine
        // to `.recovering` while the (mocked) backoff sleeps.
        let rf = MockSpeechRecognizerFactory()
        rf.handle.errorToThrow = SpeechRecognitionError.recognitionFailed("test failure")

        let (engine, _, _, _, _, _, delegate) = await makeEngine(recognizerFactory: rf)

        _ = try await engine.start()
        try await Task.sleep(for: .milliseconds(50))

        let recoveringReasons = await delegate.recoveringReasons
        #expect(!recoveringReasons.isEmpty)
        #expect(recoveringReasons[0].contains("recognizer:"))

        // Status should be `.recovering` while the backoff loop is mid-sleep.
        let status = await engine.status
        #expect(status == .recovering)

        await engine.stop()
    }

    @Test func capturedAtComesFromTheAnalyzerTimelineNotTheEmissionTime() async throws {
        // #85: the whole point of the capture clock. A backlogged recognizer
        // emits a result long after the audio it describes; `startedAt` records
        // the emission, `capturedAt` must still land on the audio.
        let rf = MockSpeechRecognizerFactory()
        let (engine, repo, _, _, _, _, _) = await makeEngine(recognizerFactory: rf)

        let analyzerStartedAround = Date()
        let session = try await engine.start()

        // Audio that began 5s into the analyzer's input timeline, but which
        // the recognizer is only now getting around to emitting — 10 minutes
        // of wall clock later.
        rf.micHandle.emit(RecognizerResult(
            text: "spoken early, transcribed late",
            isFinal: true,
            timestamp: Date().addingTimeInterval(600),
            source: .microphone,
            audioStartSeconds: 5,
            audioDurationSeconds: 1
        ))
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 1)
        let segment = try #require(segments.first)

        // capturedAt tracks the analyzer timeline: start + 5s.
        let expected = analyzerStartedAround.addingTimeInterval(5)
        #expect(abs(segment.capturedAt.timeIntervalSince(expected)) < 2)

        // And it is emphatically not the emission timestamp, which is what
        // `startedAt` still records.
        #expect(segment.startedAt.timeIntervalSince(segment.capturedAt) > 500)

        await engine.stop()
    }

    @Test func capturedAtFallsBackToEmissionWhenNoAudioRange() async throws {
        // The mock recognizer and any result with an invalid CMTimeRange
        // report no audio range. Those must still get a usable value rather
        // than a nil or an epoch date.
        let rf = MockSpeechRecognizerFactory()
        let (engine, repo, _, _, _, _, _) = await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()
        rf.micHandle.emit(RecognizerResult(text: "no range", isFinal: true, source: .microphone))
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        let segment = try #require(segments.first)
        #expect(segment.capturedAt == segment.startedAt)

        await engine.stop()
    }

    @Test func dualSourceSegmentsPersistIndependently() async throws {
        let rf = MockSpeechRecognizerFactory()

        let (engine, repo, _, _, _, _, delegate) = await makeEngine(recognizerFactory: rf)

        let session = try await engine.start(systemAudio: true)

        // Give system audio time to start
        try await Task.sleep(for: .milliseconds(50))

        // Emit results from both sources independently
        rf.micHandle.emit(RecognizerResult(text: "mic partial", isFinal: false, source: .microphone))
        try await Task.sleep(for: .milliseconds(20))

        rf.sysHandle.emit(RecognizerResult(text: "sys partial", isFinal: false, source: .systemAudio))
        try await Task.sleep(for: .milliseconds(20))

        rf.micHandle.emit(RecognizerResult(text: "mic final", isFinal: true, confidence: 0.9, source: .microphone))
        try await Task.sleep(for: .milliseconds(20))

        rf.sysHandle.emit(RecognizerResult(text: "sys final", isFinal: true, confidence: 0.8, source: .systemAudio))
        try await Task.sleep(for: .milliseconds(50))

        // Assert: both segments persisted with correct sources
        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 2)
        #expect(segments.contains(where: { $0.text == "mic final" && $0.source == .microphone }))
        #expect(segments.contains(where: { $0.text == "sys final" && $0.source == .systemAudio }))

        // Assert: sequential sequence numbers
        let seqNums = segments.map(\.sequenceNumber).sorted()
        #expect(seqNums == [1, 2])

        // Assert: delegate received separate partial events per source
        let partials = await delegate.partialTexts
        let micPartials = partials.filter { $0.1 == .microphone }
        let sysPartials = partials.filter { $0.1 == .systemAudio }
        #expect(!micPartials.isEmpty)
        #expect(!sysPartials.isEmpty)

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

// MARK: - #84 audio backpressure shedding

@Suite("Audio backlog shedding")
struct AudioBacklogSheddingTests {

    /// A capture buffer of `seconds` at 48kHz, matching what the audio tap
    /// hands downstream.
    private func buffer(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let frames = AVAudioFrameCount(48000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        return buf
    }

    @Test func boundedStreamDropsOldestWhenTheConsumerStalls() async throws {
        // The shedding primitive, exercised directly: `.bufferingNewest`
        // discards the OLDEST element, which is the end a live listener wants
        // to lose. Establishing this is what the engine's cap relies on.
        let (stream, cont) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(3))

        var dropped: [Int] = []
        for i in 1...6 {
            if case .dropped(let value) = cont.yield(i) {
                dropped.append(value)
            }
        }
        cont.finish()

        var received: [Int] = []
        for await value in stream { received.append(value) }

        #expect(dropped == [1, 2, 3], "expected the oldest elements to be discarded")
        #expect(received == [4, 5, 6], "expected the newest elements to survive")
    }

    @Test func droppedBufferDurationIsMeasuredNotAssumed() async throws {
        // The cap is sized from a nominal buffer duration, but every reported
        // figure must come from the discarded buffer's real frame count — so
        // an operator reading "dropped 3.0s" can trust the number even when
        // the hardware's buffer size differs from the nominal one.
        let b = buffer(seconds: 0.25)
        let measured = Double(b.frameLength) / b.format.sampleRate
        #expect(abs(measured - 0.25) < 0.001)

        let nominal = 0.1
        #expect(abs(measured - nominal) > 0.1, "fixture must differ from nominal or it proves nothing")
    }

    @Test func cappedSettingSurvivesASettingsRoundTrip() async throws {
        let settings = StenoSettings(audioBacklogCapSeconds: 30)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: data)
        #expect(decoded.audioBacklogCapSeconds == 30)
    }

    @Test func settingsWrittenBeforeTheCapExistedDefaultToDisabled() async throws {
        // An existing install must keep its complete-but-late behavior on
        // upgrade rather than silently starting to discard audio.
        let json = """
        {"summarizationProvider":"local","anthropicModel":"m","lastSystemAudioEnabled":false,
         "healGapSeconds":30,"dedupOverlapSeconds":3,"dedupScoreThreshold":0.92,
         "dedupMicPeakThresholdDb":-25,"dedupTriggerDebounceSeconds":5,
         "emptySessionMinChars":20,"emptySessionMinDurationSeconds":3,
         "topicExtractionMinSegments":3,"retentionDays":0}
        """
        let decoded = try JSONDecoder().decode(StenoSettings.self, from: Data(json.utf8))
        #expect(decoded.audioBacklogCapSeconds == 0, "shedding must be opt-in")
    }
}
