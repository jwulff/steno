import Testing
import Foundation
@testable import StenoDaemon

@Suite("SpeakerLabelMerger.overlap")
struct SpeakerLabelOverlapTests {

    @Test func overlapCases() {
        #expect(SpeakerLabelMerger.overlap(0, 10, 5, 15) == 5)  // partial
        #expect(SpeakerLabelMerger.overlap(0, 10, 2, 8) == 6)  // containment
        #expect(SpeakerLabelMerger.overlap(0, 5, 10, 15) == 0)  // disjoint
        #expect(SpeakerLabelMerger.overlap(0, 10, 10, 20) == 0)  // touching (half-open)
    }
}

@Suite("SpeakerLabelMerger.assign")
struct SpeakerLabelAssignTests {

    private func seg(
        audioStart: TimeInterval?,
        audioEnd: TimeInterval?,
        duplicateOf: UUID? = nil
    ) -> StoredSegment {
        StoredSegment(
            sessionId: UUID(),
            text: "x",
            startedAt: Date(),
            endedAt: Date(),
            sequenceNumber: 0,
            duplicateOf: duplicateOf,
            audioStart: audioStart,
            audioEnd: audioEnd
        )
    }

    private func window(_ labeled: [LabeledSegment]) -> DiarizationWindowResult {
        DiarizationWindowResult(
            windowStart: 0,
            windowEnd: 60,
            model: .sortformer,
            segments: labeled
        )
    }

    @Test func assignsByOverlap() {
        let speaker = SpeakerID()
        let w = window([LabeledSegment(startTime: 10, endTime: 20, speaker: speaker)])
        let s = seg(audioStart: 12, audioEnd: 18)

        #expect(SpeakerLabelMerger.assign(window: w, segments: [s]) == [s.id: speaker.raw])
    }

    @Test func maxOverlapWins() {
        let a = SpeakerID()
        let b = SpeakerID()
        let w = window([
            LabeledSegment(startTime: 10, endTime: 15, speaker: a),
            LabeledSegment(startTime: 15, endTime: 25, speaker: b),
        ])
        let s = seg(audioStart: 12, audioEnd: 20)  // 3s with A, 5s with B

        #expect(SpeakerLabelMerger.assign(window: w, segments: [s]) == [s.id: b.raw])
    }

    @Test func skipsDuplicatesAndMissingTime() {
        let w = window([LabeledSegment(startTime: 10, endTime: 20, speaker: SpeakerID())])
        let duplicate = seg(audioStart: 12, audioEnd: 18, duplicateOf: UUID())
        let noTime = seg(audioStart: nil, audioEnd: nil)
        let noOverlap = seg(audioStart: 100, audioEnd: 110)

        #expect(
            SpeakerLabelMerger.assign(
                window: w,
                segments: [duplicate, noTime, noOverlap]
            ).isEmpty
        )
    }
}

@Suite("SpeakerLabelMerger.inheritedLabels")
struct SpeakerLabelInheritanceTests {

    private func seg(duplicateOf: UUID?) -> StoredSegment {
        StoredSegment(
            sessionId: UUID(),
            text: "x",
            startedAt: Date(),
            endedAt: Date(),
            sequenceNumber: 0,
            duplicateOf: duplicateOf
        )
    }

    @Test func duplicateInheritsCanonicalSpeaker() {
        let target = UUID()
        let speaker = UUID()
        let duplicate = seg(duplicateOf: target)

        let result = SpeakerLabelMerger.inheritedLabels(
            duplicates: [duplicate],
            canonicalSpeaker: [target: speaker]
        )
        #expect(result == [duplicate.id: speaker])
    }

    @Test func omitsWhenCanonicalUnlabeled() {
        let duplicate = seg(duplicateOf: UUID())
        #expect(
            SpeakerLabelMerger.inheritedLabels(
                duplicates: [duplicate],
                canonicalSpeaker: [:]
            ).isEmpty
        )
    }

    @Test func ignoresNonDuplicates() {
        let canonical = seg(duplicateOf: nil)
        #expect(
            SpeakerLabelMerger.inheritedLabels(
                duplicates: [canonical],
                canonicalSpeaker: [UUID(): UUID()]
            ).isEmpty
        )
    }
}
