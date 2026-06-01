import Testing
import Foundation
@testable import StenoDaemon

@Suite("DiarizationModel")
struct DiarizationModelTests {

    @Test func maxSpeakersPerTier() {
        #expect(DiarizationModel.sortformer.maxSpeakers == 4)
        #expect(DiarizationModel.lsEEND.maxSpeakers == 10)
    }
}

@Suite("DiarizedSegment")
struct DiarizedSegmentTests {

    @Test func durationIsNonNegative() {
        #expect(DiarizedSegment(startTime: 2, endTime: 4, speaker: 0).duration == 2)
        // Inverted span clamps to 0 rather than going negative.
        #expect(DiarizedSegment(startTime: 4, endTime: 2, speaker: 0).duration == 0)
    }

    @Test func overlapsIsHalfOpen() {
        let segment = DiarizedSegment(startTime: 2, endTime: 4, speaker: 0)

        #expect(segment.overlaps(from: 3, to: 5))
        #expect(segment.overlaps(from: 0, to: 3))
        // Touching exactly at a boundary does not count (half-open).
        #expect(segment.overlaps(from: 0, to: 2) == false)
        #expect(segment.overlaps(from: 4, to: 6) == false)
    }
}

@Suite("DiarizationResult")
struct DiarizationResultTests {

    @Test func speakerCountIsDistinct() {
        let result = DiarizationResult(
            segments: [
                DiarizedSegment(startTime: 0, endTime: 1, speaker: 0),
                DiarizedSegment(startTime: 1, endTime: 2, speaker: 0),
                DiarizedSegment(startTime: 2, endTime: 3, speaker: 1),
                DiarizedSegment(startTime: 3, endTime: 4, speaker: 2),
            ],
            embeddings: [],
            modelId: "m",
            modelVersion: "1"
        )

        #expect(result.speakerCount == 3)
    }
}

@Suite("MockDiarizationService")
struct MockDiarizationServiceTests {

    private struct StubError: Error {}

    @Test func recordsCallAndReturnsCannedResult() async throws {
        let service = MockDiarizationService()
        service.resultToReturn = DiarizationResult(
            segments: [DiarizedSegment(startTime: 0, endTime: 1, speaker: 0)],
            embeddings: [SpeakerEmbedding(speaker: 0, vector: [0.1, 0.2])],
            modelId: "mock",
            modelVersion: "0"
        )

        let result = try await service.diarize(
            samples: [Float](repeating: 0, count: 100),
            sampleRate: 16000,
            model: .sortformer
        )

        #expect(service.calls == [.init(sampleCount: 100, sampleRate: 16000, model: .sortformer)])
        #expect(result.segments.count == 1)
        #expect(result.speakerCount == 1)
    }

    @Test func throwsWhenConfigured() async {
        let service = MockDiarizationService()
        service.errorToThrow = StubError()

        await #expect(throws: StubError.self) {
            _ = try await service.diarize(samples: [0], sampleRate: 16000, model: .lsEEND)
        }
    }
}
