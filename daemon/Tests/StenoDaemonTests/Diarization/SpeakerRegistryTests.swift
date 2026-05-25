import Testing
import Foundation
@testable import StenoDaemon

@Suite("SpeakerRegistry.cosineSimilarity")
struct CosineSimilarityTests {

    @Test func identicalVectorsScoreOne() {
        #expect(SpeakerRegistry.cosineSimilarity([1, 0, 0], [1, 0, 0]) == 1)
    }

    @Test func orthogonalVectorsScoreZero() {
        #expect(SpeakerRegistry.cosineSimilarity([1, 0], [0, 1]) == 0)
    }

    @Test func oppositeVectorsScoreMinusOne() {
        #expect(SpeakerRegistry.cosineSimilarity([1, 0, 0], [-1, 0, 0]) == -1)
    }

    @Test func mismatchedLengthsScoreZero() {
        #expect(SpeakerRegistry.cosineSimilarity([1, 0, 0], [1, 0]) == 0)
    }

    @Test func emptyOrZeroMagnitudeScoreZero() {
        #expect(SpeakerRegistry.cosineSimilarity([], []) == 0)
        #expect(SpeakerRegistry.cosineSimilarity([0, 0], [1, 1]) == 0)
    }
}

@Suite("SpeakerRegistry.assign")
struct SpeakerRegistryAssignTests {

    private let model = "sortformer"
    private let version = "1.0"

    @Test func emptyRegistryMintsDistinctProvisionalSpeakers() async throws {
        let registry = SpeakerRegistry()
        let assignment = await registry.assign(
            [
                SpeakerEmbedding(speaker: 0, vector: [1, 0, 0]),
                SpeakerEmbedding(speaker: 1, vector: [0, 1, 0]),
            ],
            modelId: model,
            modelVersion: version
        )

        #expect(Set(assignment.values).count == 2)
        #expect(await registry.count == 2)
        let id = try #require(assignment[0])
        let speaker = try #require(await registry.speaker(id))
        #expect(speaker.state == .provisional)
        #expect(speaker.centroid == [1, 0, 0])
    }

    @Test func reusesIdAndConfirmsAfterThreshold() async throws {
        let registry = SpeakerRegistry(confirmAfterWindows: 2)

        let first = await registry.assign(
            [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])],
            modelId: model,
            modelVersion: version
        )
        let id = try #require(first[0])
        #expect(await registry.speaker(id)?.state == .provisional)

        let second = await registry.assign(
            [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])],
            modelId: model,
            modelVersion: version
        )

        #expect(second[0] == id)  // same global speaker reused
        #expect(await registry.count == 1)  // not minted again
        #expect(await registry.speaker(id)?.state == .confirmed)
        #expect(await registry.speaker(id)?.windowsSeen == 2)
    }

    @Test func dissimilarEmbeddingMintsNew() async {
        let registry = SpeakerRegistry()
        _ = await registry.assign(
            [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])],
            modelId: model,
            modelVersion: version
        )

        _ = await registry.assign(
            [SpeakerEmbedding(speaker: 0, vector: [0, 1, 0])],  // orthogonal → sim 0
            modelId: model,
            modelVersion: version
        )

        #expect(await registry.count == 2)
    }

    @Test func twoSimilarWindowSpeakersGetDistinctIds() async {
        let registry = SpeakerRegistry()
        let id = await registry.enroll(embedding: [1, 0, 0], modelId: model, modelVersion: version)

        // Both embeddings are similar to the enrolled speaker, but only one may
        // claim it — the other must mint a fresh ID.
        let assignment = await registry.assign(
            [
                SpeakerEmbedding(speaker: 0, vector: [1, 0, 0]),
                SpeakerEmbedding(speaker: 1, vector: [0.95, 0.05, 0]),
            ],
            modelId: model,
            modelVersion: version
        )

        #expect(Set(assignment.values).count == 2)
        #expect(assignment.values.contains(id))
        #expect(await registry.count == 2)
    }

    @Test func differentModelDoesNotMatch() async {
        let registry = SpeakerRegistry()
        _ = await registry.enroll(embedding: [1, 0, 0], modelId: model, modelVersion: version)

        _ = await registry.assign(
            [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])],  // identical vector...
            modelId: "lsEEND",  // ...but different model → not comparable
            modelVersion: version
        )

        #expect(await registry.count == 2)
    }

    @Test func enrolledSpeakerIsConfirmedAndMatchable() async {
        let registry = SpeakerRegistry()
        let id = await registry.enroll(embedding: [1, 0, 0], modelId: model, modelVersion: version)

        #expect(await registry.speaker(id)?.state == .confirmed)

        let assignment = await registry.assign(
            [SpeakerEmbedding(speaker: 0, vector: [1, 0, 0])],
            modelId: model,
            modelVersion: version
        )

        #expect(assignment[0] == id)
        #expect(await registry.count == 1)
    }

    @Test func snapshotSeedsAFreshRegistry() async {
        let original = SpeakerRegistry()
        let id = await original.enroll(embedding: [1, 0, 0], modelId: model, modelVersion: version)
        let snapshot = await original.snapshot()

        let seeded = SpeakerRegistry(seed: snapshot)

        #expect(await seeded.count == 1)
        #expect(await seeded.speaker(id)?.state == .confirmed)
    }
}
