import Foundation

/// A complete transcription containing multiple segments.
public struct Transcript: Sendable, Codable, Identifiable {
    /// Unique identifier for this transcript.
    public let id: UUID

    /// When this transcript was created.
    public let createdAt: Date

    /// The ordered segments of transcribed speech.
    public private(set) var segments: [TranscriptSegment]

    /// The full transcribed text, joining all segments with spaces.
    public var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    /// Total duration of all segments in seconds.
    public var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    public init(id: UUID = UUID(), createdAt: Date = Date(), segments: [TranscriptSegment] = []) {
        self.id = id
        self.createdAt = createdAt
        self.segments = segments
    }

    /// Appends a new segment to the transcript.
    public mutating func addSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
    }
}
