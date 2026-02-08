import Testing
import Foundation
@testable import StenoDaemon

@Suite("Transcript Tests")
struct TranscriptTests {

    @Test func fullTextConcatenation() {
        var transcript = Transcript()
        let timestamp = Date()

        transcript.addSegment(TranscriptSegment(
            text: "Hello",
            timestamp: timestamp,
            duration: 0.5,
            confidence: 0.9
        ))
        transcript.addSegment(TranscriptSegment(
            text: "world",
            timestamp: timestamp.addingTimeInterval(0.5),
            duration: 0.5,
            confidence: 0.95
        ))

        #expect(transcript.fullText == "Hello world")
    }

    @Test func emptyTranscript() {
        let transcript = Transcript()
        #expect(transcript.fullText == "")
        #expect(transcript.segments.isEmpty)
        #expect(transcript.duration == 0)
    }

    @Test func duration() {
        var transcript = Transcript()
        let timestamp = Date()

        transcript.addSegment(TranscriptSegment(
            text: "First",
            timestamp: timestamp,
            duration: 1.5,
            confidence: 0.9
        ))
        transcript.addSegment(TranscriptSegment(
            text: "Second",
            timestamp: timestamp.addingTimeInterval(1.5),
            duration: 2.0,
            confidence: 0.85
        ))

        #expect(transcript.duration == 3.5)
    }

    @Test func addSegment() {
        var transcript = Transcript()
        let segment = TranscriptSegment(
            text: "test",
            timestamp: Date(),
            duration: 1.0,
            confidence: 0.9
        )

        transcript.addSegment(segment)

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments.first == segment)
    }

    @Test func multipleSegmentsAccumulate() {
        var transcript = Transcript()
        let timestamp = Date()

        for i in 0..<5 {
            transcript.addSegment(TranscriptSegment(
                text: "word\(i)",
                timestamp: timestamp.addingTimeInterval(Double(i)),
                duration: 1.0,
                confidence: 0.9
            ))
        }

        #expect(transcript.segments.count == 5)
        #expect(transcript.fullText == "word0 word1 word2 word3 word4")
    }

    @Test func codable() throws {
        var transcript = Transcript()
        let timestamp = Date()

        transcript.addSegment(TranscriptSegment(
            text: "Hello",
            timestamp: timestamp,
            duration: 0.5,
            confidence: 0.9
        ))
        transcript.addSegment(TranscriptSegment(
            text: "world",
            timestamp: timestamp.addingTimeInterval(0.5),
            duration: 0.5,
            confidence: 0.95
        ))

        let encoder = JSONEncoder()
        let data = try encoder.encode(transcript)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Transcript.self, from: data)

        #expect(decoded.segments.count == 2)
        #expect(decoded.fullText == transcript.fullText)
        #expect(decoded.duration == transcript.duration)
    }

    @Test func createdAt() {
        let before = Date()
        let transcript = Transcript()
        let after = Date()

        #expect(transcript.createdAt >= before)
        #expect(transcript.createdAt <= after)
    }

    @Test func id() {
        let transcript1 = Transcript()
        let transcript2 = Transcript()

        #expect(transcript1.id != transcript2.id)
    }
}
