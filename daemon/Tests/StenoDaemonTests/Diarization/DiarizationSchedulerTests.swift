import Testing
import Foundation
@testable import StenoDaemon

@Suite("DiarizationScheduler")
struct DiarizationSchedulerTests {

    /// Append `seconds` of synthetic audio as 1s @ 1 Hz chunks, so capture-clock
    /// time equals the number of appends — chunk math stays exact. Large
    /// retention keeps everything resident for boundary assertions.
    private func makeRing(seconds: Int) async -> AudioRingBuffer {
        let ring = AudioRingBuffer(retention: 100_000)
        for _ in 0..<seconds {
            await ring.append(samples: [0], sampleRate: 1)
        }
        return ring
    }

    private func mockReturning(segments: [DiarizedSegment]) -> MockDiarizationService {
        let mock = MockDiarizationService()
        mock.resultToReturn = DiarizationResult(
            segments: segments,
            embeddings: [],
            modelId: "sortformer",
            modelVersion: "1"
        )
        return mock
    }

    @Test func noChunkClosesBeforeFullLength() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 30),
            diarizer: MockDiarizationService(),
            registry: SpeakerRegistry(),
            sourceTag: "microphone"
        )

        #expect(await scheduler.processReadyWindows().isEmpty)
    }

    @Test func firstChunkClosesAtFullLength() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 45),
            diarizer: MockDiarizationService(),
            registry: SpeakerRegistry(),
            sourceTag: "microphone"
        )

        let results = await scheduler.processReadyWindows()
        #expect(results.count == 1)
        #expect(results.first?.windowStart == 0)
        #expect(results.first?.windowEnd == 45)
        #expect(results.first?.model == .sortformer)
    }

    @Test func chunksAreNonOverlapping() async {
        // Streaming diarizers must see each frame once — consecutive chunks
        // must abut, not overlap.
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 90),
            diarizer: MockDiarizationService(),
            registry: SpeakerRegistry(),
            sourceTag: "microphone"
        )

        let results = await scheduler.processReadyWindows()
        #expect(results.map(\.windowStart) == [0, 45])
        #expect(results.map(\.windowEnd) == [45, 90])
    }

    @Test func diarizerErrorSkipsChunkButAdvancesCursor() async {
        let ring = await makeRing(seconds: 45)
        let mock = MockDiarizationService()
        mock.errorToThrow = MockError()
        let scheduler = DiarizationScheduler(
            ringBuffer: ring,
            diarizer: mock,
            registry: SpeakerRegistry(),
            sourceTag: "microphone"
        )

        // First chunk [0,45] errors → no result, but the cursor advances.
        #expect(await scheduler.processReadyWindows().isEmpty)

        // Recover and extend audio to 90s; the next closed chunk must be
        // [45,90], proving [0,45] was not retried.
        mock.errorToThrow = nil
        for _ in 0..<45 { await ring.append(samples: [0], sampleRate: 1) }

        let results = await scheduler.processReadyWindows()
        #expect(results.map(\.windowStart) == [45])
    }

    @Test func labelsSegmentsOnTheCaptureClock() async {
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 45),
            diarizer: mockReturning(
                segments: [DiarizedSegment(startTime: 5, endTime: 10, speaker: 0)]
            ),
            registry: SpeakerRegistry(),
            sourceTag: "microphone"
        )

        let results = await scheduler.processReadyWindows()
        let segment = results.first?.segments.first
        #expect(segment?.startTime == 5)
        #expect(segment?.endTime == 10)
    }

    @Test func stitchesSameSpeakerAcrossChunks() async {
        let registry = SpeakerRegistry()
        let scheduler = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 90),
            diarizer: mockReturning(
                segments: [DiarizedSegment(startTime: 5, endTime: 10, speaker: 0)]
            ),
            registry: registry,
            sourceTag: "microphone"
        )

        let results = await scheduler.processReadyWindows()
        #expect(results.count == 2)

        // Chunk 2's segment is offset onto the capture clock (45 + 5).
        #expect(results[1].segments.first?.startTime == 50)

        // FluidAudio's `speakerIndex` is stable across chunks, so the
        // stable-index stitching resolves both chunks to one global speaker.
        let speaker0 = results[0].segments.first?.speaker
        let speaker1 = results[1].segments.first?.speaker
        #expect(speaker0 == speaker1)
        #expect(await registry.count == 1)
    }

    @Test func separatesSpeakersBySourceTag() async {
        // Two sources naming "speaker 0" are different people — cross-source
        // unification is the §9 dedup gate's job, not index aliasing.
        let registry = SpeakerRegistry()

        let mic = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 45),
            diarizer: mockReturning(
                segments: [DiarizedSegment(startTime: 0, endTime: 5, speaker: 0)]
            ),
            registry: registry,
            sourceTag: "microphone"
        )
        let sys = DiarizationScheduler(
            ringBuffer: await makeRing(seconds: 45),
            diarizer: mockReturning(
                segments: [DiarizedSegment(startTime: 0, endTime: 5, speaker: 0)]
            ),
            registry: registry,
            sourceTag: "systemAudio"
        )

        let micResults = await mic.processReadyWindows()
        let sysResults = await sys.processReadyWindows()

        #expect(micResults.first?.segments.first?.speaker != sysResults.first?.segments.first?.speaker)
        #expect(await registry.count == 2)
    }
}

private struct MockError: Error {}
