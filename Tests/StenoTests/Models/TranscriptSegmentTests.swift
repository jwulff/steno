import Testing
import Foundation
@testable import Steno

@Suite("TranscriptSegment Tests")
struct TranscriptSegmentTests {

    @Test func creation() {
        let timestamp = Date()
        let segment = TranscriptSegment(
            text: "hello world",
            timestamp: timestamp,
            duration: 1.5,
            confidence: 0.95
        )

        #expect(segment.text == "hello world")
        #expect(segment.timestamp == timestamp)
        #expect(segment.duration == 1.5)
        #expect(segment.confidence == 0.95)
    }

    @Test func equality() {
        let timestamp = Date()
        let segment1 = TranscriptSegment(
            text: "hello",
            timestamp: timestamp,
            duration: 1.0,
            confidence: 0.9
        )
        let segment2 = TranscriptSegment(
            text: "hello",
            timestamp: timestamp,
            duration: 1.0,
            confidence: 0.9
        )

        #expect(segment1 == segment2)
    }

    @Test func inequality() {
        let timestamp = Date()
        let segment1 = TranscriptSegment(
            text: "hello",
            timestamp: timestamp,
            duration: 1.0,
            confidence: 0.9
        )
        let segment2 = TranscriptSegment(
            text: "world",
            timestamp: timestamp,
            duration: 1.0,
            confidence: 0.9
        )

        #expect(segment1 != segment2)
    }

    @Test func codable() throws {
        let timestamp = Date()
        let segment = TranscriptSegment(
            text: "test transcription",
            timestamp: timestamp,
            duration: 2.5,
            confidence: 0.88
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(segment)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TranscriptSegment.self, from: data)

        #expect(decoded == segment)
    }

    @Test func optionalConfidence() {
        let segment = TranscriptSegment(
            text: "no confidence",
            timestamp: Date(),
            duration: 1.0,
            confidence: nil
        )

        #expect(segment.confidence == nil)
    }
}
