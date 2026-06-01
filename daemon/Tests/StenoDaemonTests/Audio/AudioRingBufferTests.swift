import Testing
import Foundation
@testable import StenoDaemon

@Suite("PCMChunk")
struct PCMChunkTests {

    @Test func computesDurationAndEndTime() {
        let chunk = PCMChunk(
            startTime: 10,
            sampleRate: 16000,
            samples: [Float](repeating: 0, count: 8000)
        )

        #expect(chunk.frameCount == 8000)
        #expect(chunk.duration == 0.5)
        #expect(chunk.endTime == 10.5)
    }

    @Test func zeroSampleRateHasZeroDuration() {
        let chunk = PCMChunk(startTime: 0, sampleRate: 0, samples: [1, 2, 3])

        #expect(chunk.duration == 0)
        #expect(chunk.endTime == 0)
    }
}

@Suite("AudioRingBuffer")
struct AudioRingBufferTests {

    /// 1-second-per-`seconds` mono chunk at 16 kHz starting at `start`.
    private func chunk(start: Double, seconds: Double = 1) -> PCMChunk {
        PCMChunk(
            startTime: start,
            sampleRate: 16000,
            samples: [Float](repeating: 0, count: Int(seconds * 16000))
        )
    }

    @Test func emptyBufferReportsEmpty() async {
        let buffer = AudioRingBuffer()

        #expect(await buffer.isEmpty())
        #expect(await buffer.earliestTime() == nil)
        #expect(await buffer.latestTime() == 0)
        #expect(await buffer.window(from: 0, to: 10).isEmpty)
    }

    @Test func appendTracksEarliestAndLatest() async {
        let buffer = AudioRingBuffer()
        await buffer.append(chunk(start: 3))

        #expect(await buffer.isEmpty() == false)
        #expect(await buffer.earliestTime() == 3)
        #expect(await buffer.latestTime() == 4)
    }

    @Test func windowReturnsOverlappingChunks() async {
        let buffer = AudioRingBuffer()
        for i in 0..<5 {
            await buffer.append(chunk(start: Double(i)))
        }

        // Chunks at start 2,3,4 overlap [2.5, 4.5); 0 and 1 do not.
        let result = await buffer.window(from: 2.5, to: 4.5)
        #expect(result.map(\.startTime) == [2, 3, 4])
    }

    @Test func windowFullyBeforeOrAfterIsEmpty() async {
        let buffer = AudioRingBuffer()
        await buffer.append(chunk(start: 5))

        #expect(await buffer.window(from: 0, to: 5).isEmpty)  // ends exactly at chunk start
        #expect(await buffer.window(from: 6, to: 10).isEmpty)  // starts exactly at chunk end
    }

    @Test func emptyOrInvertedRangeReturnsNothing() async {
        let buffer = AudioRingBuffer()
        await buffer.append(chunk(start: 0, seconds: 10))

        #expect(await buffer.window(from: 5, to: 5).isEmpty)
        #expect(await buffer.window(from: 8, to: 2).isEmpty)
    }

    @Test func evictsAudioBeyondRetention() async {
        let buffer = AudioRingBuffer(retention: 5)
        for i in 0..<10 {
            await buffer.append(chunk(start: Double(i)))
        }

        // latestEnd == 10, cutoff == 5 → chunks ending at/<=5 (starts 0..4) drop.
        #expect(await buffer.earliestTime() == 5)
        #expect(await buffer.window(from: 0, to: 5).isEmpty)
        #expect(await buffer.window(from: 5, to: 6).count == 1)
    }

    @Test func retainsFullWindowWithinHorizon() async {
        // The diarization invariant: with default 90s retention a closing 60s
        // window is still fully resident.
        let buffer = AudioRingBuffer()
        for i in 0..<60 {
            await buffer.append(chunk(start: Double(i)))
        }

        #expect(await buffer.earliestTime() == 0)
        #expect(await buffer.window(from: 0, to: 60).count == 60)
    }

    @Test func appendSamplesChainsOnTheCaptureClock() async {
        let buffer = AudioRingBuffer()
        let half = [Float](repeating: 0, count: 8000)  // 0.5s @ 16kHz
        let full = [Float](repeating: 0, count: 16000)  // 1.0s @ 16kHz

        let start0 = await buffer.append(samples: half, sampleRate: 16000)
        let start1 = await buffer.append(samples: full, sampleRate: 16000)

        #expect(start0 == 0)
        #expect(start1 == 0.5)
        #expect(await buffer.latestTime() == 1.5)
        #expect(await buffer.window(from: 0, to: 2).map(\.startTime) == [0, 0.5])
    }

    @Test func appendSamplesIgnoresEmptyOrInvalidInput() async {
        let buffer = AudioRingBuffer()

        #expect(await buffer.append(samples: [], sampleRate: 16000) == 0)
        #expect(await buffer.append(samples: [1, 2, 3], sampleRate: 0) == 0)
        #expect(await buffer.isEmpty())
    }

    /// A ramp chunk where sample `i` holds value `Float(i)` — lets a test assert
    /// exactly which frames a sample-exact window returned, by value.
    private func rampChunk(start: Double, count: Int, sampleRate: Double = 16000) -> PCMChunk {
        PCMChunk(
            startTime: start,
            sampleRate: sampleRate,
            samples: (0..<count).map { Float($0) }
        )
    }

    @Test func samplesReturnsExactlyTheRequestedSpan() async {
        // One 1s @ 16 kHz ramp chunk [0,1). Request [0.25, 0.75) → frames
        // [4000, 12000), i.e. values 4000..<12000.
        let buffer = AudioRingBuffer()
        await buffer.append(rampChunk(start: 0, count: 16000))

        let span = await buffer.samples(from: 0.25, to: 0.75)
        #expect(span.count == 8000)
        #expect(span.first == 4000)
        #expect(span.last == 11999)
    }

    @Test func samplesTrimsBothStraddlingBoundaryChunks() async {
        // Two abutting 1s ramp chunks: [0,1) and [1,2). Request [0.5, 1.5)
        // straddles both — must trim the tail of chunk 0 and the head of
        // chunk 1, yielding exactly 16000 samples (8000 from each).
        let buffer = AudioRingBuffer()
        await buffer.append(rampChunk(start: 0, count: 16000))
        await buffer.append(rampChunk(start: 1, count: 16000))

        let span = await buffer.samples(from: 0.5, to: 1.5)
        #expect(span.count == 16000)
        // Last 8000 of chunk 0 are values 8000..<16000, then first 8000 of
        // chunk 1 are values 0..<8000.
        #expect(span.first == 8000)
        #expect(span[7999] == 15999)
        #expect(span[8000] == 0)
        #expect(span.last == 7999)
    }

    @Test func samplesCoversFullWidthWhenWindowSpansManyChunks() async {
        // 1s-per-chunk @ 1 Hz so frame count == seconds. 90 chunks; a 45s
        // window must return exactly 45 samples with no double-counting.
        let buffer = AudioRingBuffer(retention: 100_000)
        for _ in 0..<90 { await buffer.append(samples: [0], sampleRate: 1) }

        let span = await buffer.samples(from: 0, to: 45)
        #expect(span.count == 45)
        let span2 = await buffer.samples(from: 45, to: 90)
        #expect(span2.count == 45)
    }

    @Test func samplesEmptyForInvertedOrEmptyRange() async {
        let buffer = AudioRingBuffer()
        await buffer.append(rampChunk(start: 0, count: 16000))

        #expect(await buffer.samples(from: 5, to: 5).isEmpty)
        #expect(await buffer.samples(from: 8, to: 2).isEmpty)
    }

    @Test func samplesEmptyWhenSpanFullyOutsideRetainedAudio() async {
        let buffer = AudioRingBuffer()
        await buffer.append(rampChunk(start: 0, count: 16000))

        #expect(await buffer.samples(from: 2, to: 3).isEmpty)
    }

    @Test func resetClearsAudioAndRewindsClock() async {
        let buffer = AudioRingBuffer()
        _ = await buffer.append(
            samples: [Float](repeating: 0, count: 16000),
            sampleRate: 16000
        )

        await buffer.reset()

        #expect(await buffer.isEmpty())
        #expect(await buffer.earliestTime() == nil)
        #expect(await buffer.latestTime() == 0)
        // Clock rewound: the next append starts at 0 again.
        let restart = await buffer.append(
            samples: [Float](repeating: 0, count: 8000),
            sampleRate: 16000
        )
        #expect(restart == 0)
    }
}
