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

@Suite("SpeakerRegistry.assignStableIndex")
struct SpeakerRegistryStableIndexTests {

    private let model = "sortformer"
    private let version = "1.0"

    @Test func sameSourceAndIndexReturnsSameID() async {
        let registry = SpeakerRegistry()

        let first = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)
        let again = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)

        #expect(first == again)
        #expect(await registry.count == 1)
    }

    @Test func differentIndicesMintDistinctIDs() async {
        let registry = SpeakerRegistry()

        let zero = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)
        let one = await registry.assignStableIndex(
            speakerIndex: 1, sourceTag: "microphone", modelId: model, modelVersion: version)

        #expect(zero != one)
        #expect(await registry.count == 2)
    }

    @Test func sameIndexInDifferentSourcesMintsDistinctIDs() async {
        // Cross-source unification is the §9 dedup gate's job, not the index
        // aliasing's — two sources naming "speaker 0" are different people
        // until dedup proves otherwise.
        let registry = SpeakerRegistry()

        let micZero = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)
        let sysZero = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "systemAudio", modelId: model, modelVersion: version)

        #expect(micZero != sysZero)
        #expect(await registry.count == 2)
    }

    @Test func mintedSpeakersAreConfirmedAndAppearInSnapshot() async throws {
        let registry = SpeakerRegistry()

        let id = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)
        let speaker = try #require(await registry.speaker(id))

        #expect(speaker.state == .confirmed)
        #expect(speaker.centroid.isEmpty)
        #expect(speaker.modelId == model)
        #expect(speaker.modelVersion == version)
        #expect(await registry.snapshot().count == 1)
    }

    // Bug 1: tier-escalation speaker aliasing. When a source escalates
    // Sortformer → LS-EEND (or the model version changes), both diarizers can
    // emit speakerIndex 0 for *unrelated* speakers. Keying only by
    // (sourceTag, speakerIndex) would alias them into one global ID. The key
    // must also reflect model identity so they stay distinct.
    @Test func sameSourceAndIndexDifferentModelMintsDistinctIDs() async {
        let registry = SpeakerRegistry()

        let sortformer = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone",
            modelId: "sortformer", modelVersion: version)
        let lsEEND = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone",
            modelId: "lsEEND", modelVersion: version)

        #expect(sortformer != lsEEND)
        #expect(await registry.count == 2)
    }

    @Test func sameSourceAndIndexDifferentModelVersionMintsDistinctIDs() async {
        let registry = SpeakerRegistry()

        let v1 = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone",
            modelId: model, modelVersion: "1.0")
        let v2 = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone",
            modelId: model, modelVersion: "2.0")

        #expect(v1 != v2)
        #expect(await registry.count == 2)
    }

    // Bug 2: windowsSeen must reflect recurrence on stable-index hits, just
    // like the cosine path. A stable index observed N times → windowsSeen == N.
    @Test func windowsSeenIncrementsOnStableIndexRecurrence() async throws {
        let registry = SpeakerRegistry()

        let id = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)
        #expect(await registry.speaker(id)?.windowsSeen == 1)

        _ = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)
        _ = await registry.assignStableIndex(
            speakerIndex: 0, sourceTag: "microphone", modelId: model, modelVersion: version)

        #expect(await registry.speaker(id)?.windowsSeen == 3)
        #expect(await registry.count == 1)  // still one speaker, not re-minted
    }
}
