import Testing
import Foundation
@testable import StenoDaemon

@Suite("DiarizationScheduler")
struct DiarizationSchedulerTests {

    /// Append `seconds` of synthetic audio as 1s @ 1 Hz chunks, so capture-clock
    /// time equals the number of appends — window math stays exact. Large
    /// retention keeps everything resident for boundary assertions.
    private func makeRing(seconds: Int) async -> AudioRingBuffer {
        let ring = AudioRingBuffer(retention: 100_000)
        for _ in 0..<seconds {
            await ring.append(samples: [0], sampleRate: 1)
        }
        return ring
    }

    private func mockReturning(
        segments: [DiarizedSegment],
        embeddings: [SpeakerEmbedding]
    ) -> MockDiarizationService {
        let mock = MockDiarizationService()
        mock.resultToReturn = DiarizationResult(
            segments: segments,
            embeddings: embeddings,
            modelId: "sortformer",
            modelVersion: "1"
        )
        return mock
    }

    @Test func noWindowClosesBeforeFullLength() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 30),
            diarizer: MockDiarizationService(),
            registry: SpeakerRegistry()
        )

        #expect(await scheduler.processReadyWindows().isEmpty)
    }

    @Test func firstWindowClosesAtFullLength() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 60),
            diarizer: MockDiarizationService(),
            registry: SpeakerRegistry()
        )

        let results = await scheduler.processReadyWindows()
        #expect(results.count == 1)
        #expect(results.first?.windowStart == 0)
        #expect(results.first?.windowEnd == 60)
        #expect(results.first?.model == .sortformer)
    }

    @Test func windowsSlideWithFifteenSecondOverlap() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 105),
            diarizer: MockDiarizationService(),
            registry: SpeakerRegistry()
        )

        let results = await scheduler.processReadyWindows()
        #expect(results.map(\.windowStart) == [0, 45])
        #expect(results.map(\.windowEnd) == [60, 105])
    }

    @Test func diarizerErrorSkipsWindowButAdvancesCursor() async {
        let ring = await makeRing(seconds: 60)
        let mock = MockDiarizationService()
        mock.errorToThrow = MockError()
        let scheduler = DiarizationScheduler(
            ringBuffer: ring,
            diarizer: mock,
            registry: SpeakerRegistry()
        )

        // First window [0,60] errors → no result, but the cursor advances.
        #expect(await scheduler.processReadyWindows().isEmpty)

        // Recover and extend audio to 105s; the next closed window must be
        // [45,105], proving [0,60] was not retried.
        mock.errorToThrow = nil
        for _ in 0..<45 { await ring.append(samples: [0], sampleRate: 1) }

        let results = await scheduler.processReadyWindows()
        #expect(results.map(\.windowStart) == [45])
    }

    @Test func labelsSegmentsOnTheCaptureClock() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 60),
            diarizer: mockReturning(
                segments: [DiarizedSegment(startTime: 5, endTime: 10, speaker: 0)],
                embeddings: [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])]
            ),
            registry: SpeakerRegistry()
        )

        let results = await scheduler.processReadyWindows()
        let segment = results.first?.segments.first
        #expect(segment?.startTime == 5)
        #expect(segment?.endTime == 10)
    }

    @Test func stitchesSameSpeakerAcrossWindows() async {
        let registry = SpeakerRegistry()
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 105),
            diarizer: mockReturning(
                segments: [DiarizedSegment(startTime: 5, endTime: 10, speaker: 0)],
                embeddings: [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])]
            ),
            registry: registry
        )

        let results = await scheduler.processReadyWindows()
        #expect(results.count == 2)

        // Window 2's segment is offset onto the capture clock (45 + 5).
        #expect(results[1].segments.first?.startTime == 50)

        // The same voice in both windows resolves to one global speaker.
        let speaker0 = results[0].segments.first?.speaker
        let speaker1 = results[1].segments.first?.speaker
        #expect(speaker0 == speaker1)
        #expect(await registry.count == 1)
    }
}

private struct MockError: Error {}
