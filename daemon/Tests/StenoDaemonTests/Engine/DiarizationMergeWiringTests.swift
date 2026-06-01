import Testing
import Foundation
import AVFoundation
@testable import StenoDaemon

/// Wiring-level tests for the diarization merge inside `RecordingEngine`
/// (`applyDiarizationResult`). The pure overlap/inheritance math is covered by
/// `SpeakerLabelMergerTests`; here we verify the engine sources its candidate
/// segments from the DB and persists canonical + inherited labels — the two
/// correctness gaps flagged in the PR #63 review (Bugs 2 and 4).
@Suite("Diarization merge wiring (RecordingEngine)")
struct DiarizationMergeWiringTests {

    @MainActor
    private func makeEngine() async -> (engine: RecordingEngine, repo: MockTranscriptRepository) {
        let repo = MockTranscriptRepository()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: MockSummarizationService(),
            triggerCount: 100,
            timeThreshold: 3600
        )
        let engine = RecordingEngine(
            repository: repo,
            permissionService: MockPermissionService(),
            summaryCoordinator: coordinator,
            audioSourceFactory: MockAudioSourceFactory(),
            speechRecognizerFactory: MockSpeechRecognizerFactory(),
            delegate: MockRecordingEngineDelegate(),
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0
        )
        return (engine, repo)
    }

    private func storedSegment(
        sessionId: UUID,
        sequenceNumber: Int,
        source: AudioSourceType,
        audioStart: TimeInterval?,
        audioEnd: TimeInterval?,
        duplicateOf: UUID? = nil
    ) -> StoredSegment {
        StoredSegment(
            sessionId: sessionId,
            text: "seg-\(sequenceNumber)",
            startedAt: Date(),
            endedAt: Date(),
            sequenceNumber: sequenceNumber,
            source: source,
            duplicateOf: duplicateOf,
            audioStart: audioStart,
            audioEnd: audioEnd
        )
    }

    private func window(
        from: TimeInterval,
        to: TimeInterval,
        _ labeled: [LabeledSegment]
    ) -> DiarizationWindowResult {
        DiarizationWindowResult(
            windowStart: from,
            windowEnd: to,
            model: .sortformer,
            segments: labeled
        )
    }

    // Bug 4: a segment whose audio falls in a window but which finalizes *after*
    // that window's diarization tick must still receive a speaker. The merge
    // now re-queries stored segments per window, so a segment saved before the
    // result is applied is labeled even if it was never in any in-memory
    // snapshot at the moment the window closed.
    @Test func lateFinalizedSegmentInOverlappingWindowGetsSpeaker() async throws {
        let (engine, repo) = await makeEngine()
        let session = try await engine.start()

        // This segment covers 40–44s of audio. Imagine it finalized just after
        // the [0,45) window's diarization tick — it lands in the DB but was not
        // in the snapshot used at tick time. We save it directly to model that
        // late arrival.
        let late = storedSegment(
            sessionId: session.id,
            sequenceNumber: 1,
            source: .microphone,
            audioStart: 40,
            audioEnd: 44
        )
        try await repo.saveSegment(late)

        let speaker = SpeakerID()
        let result = window(from: 0, to: 45, [
            LabeledSegment(startTime: 38, endTime: 45, speaker: speaker)
        ])
        await engine.applyDiarizationResult(result, isMic: true)

        let segments = try await repo.segments(for: session.id)
        let updated = segments.first { $0.id == late.id }
        #expect(updated?.speakerId == speaker.raw)

        await engine.stop()
    }

    // Bug 2: a duplicate segment (duplicateOf set) is never diarized directly;
    // it inherits the speaker of the canonical segment it duplicates. This was
    // never wired, so duplicates kept a NULL speaker_id.
    @Test func duplicateInheritsCanonicalSpeaker() async throws {
        let (engine, repo) = await makeEngine()
        let session = try await engine.start()

        // Canonical sys segment overlapping the window; its mic duplicate has no
        // audio range of its own (the dedup gate means it is never diarized).
        let canonical = storedSegment(
            sessionId: session.id,
            sequenceNumber: 1,
            source: .systemAudio,
            audioStart: 10,
            audioEnd: 20
        )
        let duplicate = storedSegment(
            sessionId: session.id,
            sequenceNumber: 2,
            source: .systemAudio,
            audioStart: nil,
            audioEnd: nil,
            duplicateOf: canonical.id
        )
        try await repo.saveSegment(canonical)
        try await repo.saveSegment(duplicate)

        let speaker = SpeakerID()
        let result = window(from: 0, to: 30, [
            LabeledSegment(startTime: 10, endTime: 20, speaker: speaker)
        ])
        await engine.applyDiarizationResult(result, isMic: false)

        let segments = try await repo.segments(for: session.id)
        let canonicalRow = segments.first { $0.id == canonical.id }
        let duplicateRow = segments.first { $0.id == duplicate.id }
        #expect(canonicalRow?.speakerId == speaker.raw)
        // The dedup gate invariant: the duplicate inherits, never NULL.
        #expect(duplicateRow?.speakerId == speaker.raw)

        await engine.stop()
    }

    // Bug 2 (prior-window canonical): a duplicate may point at a canonical that
    // was labeled in an *earlier* window. Inheritance must consider already
    // persisted labels, not only this window's fresh assignments.
    @Test func duplicateInheritsCanonicalLabeledInPriorWindow() async throws {
        let (engine, repo) = await makeEngine()
        let session = try await engine.start()

        let speaker = SpeakerID()
        // Canonical already carries a speaker (set by a prior window). It does
        // NOT overlap this window, so it won't be reassigned here.
        let canonical = StoredSegment(
            sessionId: session.id,
            text: "canon",
            startedAt: Date(),
            endedAt: Date(),
            sequenceNumber: 1,
            source: .systemAudio,
            audioStart: 5,
            audioEnd: 9,
            speakerId: speaker.raw
        )
        // Duplicate arrives later (this window), pointing at the canonical.
        let duplicate = storedSegment(
            sessionId: session.id,
            sequenceNumber: 2,
            source: .systemAudio,
            audioStart: nil,
            audioEnd: nil,
            duplicateOf: canonical.id
        )
        try await repo.saveSegment(canonical)
        try await repo.saveSegment(duplicate)

        // This window labels some unrelated later segment; the point is the
        // duplicate should still inherit from the prior-window canonical.
        let result = window(from: 50, to: 95, [
            LabeledSegment(startTime: 60, endTime: 70, speaker: SpeakerID())
        ])
        await engine.applyDiarizationResult(result, isMic: false)

        let segments = try await repo.segments(for: session.id)
        let duplicateRow = segments.first { $0.id == duplicate.id }
        #expect(duplicateRow?.speakerId == speaker.raw)

        await engine.stop()
    }
}

/// Bug 1: `audio_start` and `audio_end` must be NULL together. A present-start
/// / absent-or-nonpositive-duration recognizer result must NOT persist a
/// zero-length `[start, start)` span (which the diarization merge silently
/// skips). Driven end-to-end through the engine's recognizer feed.
@Suite("audio_end NULL-together invariant")
struct AudioEndNullInvariantTests {

    @MainActor
    private func makeEngine(
        _ rf: MockSpeechRecognizerFactory
    ) async -> (engine: RecordingEngine, repo: MockTranscriptRepository) {
        let repo = MockTranscriptRepository()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: MockSummarizationService(),
            triggerCount: 100,
            timeThreshold: 3600
        )
        let engine = RecordingEngine(
            repository: repo,
            permissionService: MockPermissionService(),
            summaryCoordinator: coordinator,
            audioSourceFactory: MockAudioSourceFactory(),
            speechRecognizerFactory: rf,
            delegate: MockRecordingEngineDelegate(),
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0
        )
        return (engine, repo)
    }

    @Test func startPresentButDurationNilLeavesBothNil() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.resultsToYield = [
            RecognizerResult(
                text: "hello",
                isFinal: true,
                confidence: 0.9,
                source: .microphone,
                audioStartSeconds: 12.0,
                audioDurationSeconds: nil
            )
        ]
        let (engine, repo) = await makeEngine(rf)
        let session = try await engine.start()
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 1)
        #expect(segments[0].audioStart == nil)
        #expect(segments[0].audioEnd == nil)

        await engine.stop()
    }

    @Test func startPresentButZeroDurationLeavesBothNil() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.resultsToYield = [
            RecognizerResult(
                text: "hello",
                isFinal: true,
                confidence: 0.9,
                source: .microphone,
                audioStartSeconds: 12.0,
                audioDurationSeconds: 0.0
            )
        ]
        let (engine, repo) = await makeEngine(rf)
        let session = try await engine.start()
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 1)
        #expect(segments[0].audioStart == nil)
        #expect(segments[0].audioEnd == nil)

        await engine.stop()
    }

    @Test func validStartAndDurationProduceSpan() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.handle.resultsToYield = [
            RecognizerResult(
                text: "hello",
                isFinal: true,
                confidence: 0.9,
                source: .microphone,
                audioStartSeconds: 12.0,
                audioDurationSeconds: 3.0
            )
        ]
        let (engine, repo) = await makeEngine(rf)
        let session = try await engine.start()
        try await Task.sleep(for: .milliseconds(50))

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 1)
        #expect(segments[0].audioStart == 12.0)
        #expect(segments[0].audioEnd == 15.0)

        await engine.stop()
    }
}

/// Bug 3: `monoSamples` must downmix all channels, not drop channel 1+.
@Suite("RecordingEngine.monoSamples downmix")
struct MonoSamplesDownmixTests {

    private func stereoBuffer(
        left: [Float],
        right: [Float]
    ) -> AVAudioPCMBuffer {
        precondition(left.count == right.count)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(left.count)
        )!
        buffer.frameLength = AVAudioFrameCount(left.count)
        let channels = buffer.floatChannelData!
        for i in 0..<left.count {
            channels[0][i] = left[i]
            channels[1][i] = right[i]
        }
        return buffer
    }

    private func monoBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channel[i] = samples[i]
        }
        return buffer
    }

    // The headline bug: speech present ONLY on channel 1 (right). The old
    // channel-0-only path returned all zeros — the signal was silently dropped.
    @Test func rightChannelOnlySignalSurvivesDownmix() {
        let buffer = stereoBuffer(
            left: [0, 0, 0, 0],
            right: [1.0, 1.0, 1.0, 1.0]
        )
        let mono = RecordingEngine.monoSamples(buffer)
        #expect(mono.count == 4)
        // Average of (0, 1.0) across 2 channels == 0.5, not 0.
        for sample in mono {
            #expect(abs(sample - 0.5) < 1e-6)
        }
    }

    @Test func bothChannelsAveraged() {
        let buffer = stereoBuffer(
            left: [0.2, 0.4],
            right: [0.6, 0.8]
        )
        let mono = RecordingEngine.monoSamples(buffer)
        #expect(mono.count == 2)
        #expect(abs(mono[0] - 0.4) < 1e-6)  // (0.2 + 0.6) / 2
        #expect(abs(mono[1] - 0.6) < 1e-6)  // (0.4 + 0.8) / 2
    }

    @Test func monoBufferPassesThroughUnchanged() {
        let buffer = monoBuffer([0.1, -0.2, 0.3])
        let mono = RecordingEngine.monoSamples(buffer)
        #expect(mono.count == 3)
        #expect(abs(mono[0] - 0.1) < 1e-6)
        #expect(abs(mono[1] - (-0.2)) < 1e-6)
        #expect(abs(mono[2] - 0.3) < 1e-6)
    }

    @Test func emptyBufferYieldsEmpty() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 0
        #expect(RecordingEngine.monoSamples(buffer).isEmpty)
    }
}
