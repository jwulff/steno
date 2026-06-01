import Foundation

/// Which diarization model a window is run through. The tier controller (#60)
/// starts every source on `.sortformer` and escalates to `.lsEEND` only when a
/// stream's distinct-speaker count outgrows the cheaper model (epic #53 §5).
public enum DiarizationModel: String, Sendable, CaseIterable {
    /// Default tier: very stable IDs, strong on noise/overlap, hard cap at 4.
    case sortformer
    /// Escalated tier: handles many speakers + heavy crosstalk, less stable.
    case lsEEND

    /// Hard cap on simultaneously-tracked speakers for this model (#53 §5).
    public var maxSpeakers: Int {
        switch self {
        case .sortformer: return 4
        case .lsEEND: return 10
        }
    }
}

/// A contiguous span attributed to a single speaker within one diarized
/// window.
public struct DiarizedSegment: Sendable, Equatable {
    /// Window-relative start/end, in seconds. The scheduler (#58) offsets these
    /// by the window's capture-clock start before merging with transcript
    /// segments (#61); on their own they are not on the session timeline.
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// Window-local speaker index (0-based). Stitched to a stable global ID by
    /// the registry (#59); NOT comparable across windows on its own.
    public let speaker: Int

    public init(startTime: TimeInterval, endTime: TimeInterval, speaker: Int) {
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
    }

    public var duration: TimeInterval { max(0, endTime - startTime) }

    /// Whether this segment overlaps the half-open range `[from, to)`.
    public func overlaps(from: TimeInterval, to: TimeInterval) -> Bool {
        endTime > from && startTime < to
    }
}

/// A per-speaker voice embedding extracted from one window. Used by the
/// registry (#59) to stitch window-local speakers into stable global IDs via
/// cosine similarity.
public struct SpeakerEmbedding: Sendable, Equatable {
    /// Window-local speaker index this embedding represents (matches
    /// `DiarizedSegment.speaker`).
    public let speaker: Int
    /// Voice embedding vector; dimensionality is model-specific.
    public let vector: [Float]

    public init(speaker: Int, vector: [Float]) {
        self.speaker = speaker
        self.vector = vector
    }
}

/// Output of diarizing one window: speaker segments, one embedding per detected
/// speaker, and the model provenance the embeddings were produced under.
public struct DiarizationResult: Sendable, Equatable {
    public let segments: [DiarizedSegment]
    public let embeddings: [SpeakerEmbedding]
    /// Model identity + version. Embeddings are only comparable within the same
    /// model id + version — persisted voiceprints become invalid on a model
    /// upgrade (#53 §4 design-for-persistence). Stamped here so the registry
    /// (#59) and voiceprint DB (#54) can enforce that.
    public let modelId: String
    public let modelVersion: String

    public init(
        segments: [DiarizedSegment],
        embeddings: [SpeakerEmbedding],
        modelId: String,
        modelVersion: String
    ) {
        self.segments = segments
        self.embeddings = embeddings
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    /// Distinct window-local speakers observed in the segments. The tier
    /// controller (#60) compares this against the active model's `maxSpeakers`
    /// to decide whether to escalate.
    public var speakerCount: Int { Set(segments.map(\.speaker)).count }
}

/// Diarizes a window of mono PCM audio. The concrete implementation wraps
/// FluidAudio's `OfflineDiarizerManager` (added in a follow-up increment);
/// tests use `MockDiarizationService`. Swappable per the project's
/// protocol-first / DI conventions so the model tier (#60) is injectable.
public protocol DiarizationService: Sendable {
    /// Diarize a mono PCM window. Returns window-relative speaker segments plus
    /// one embedding per detected speaker, stamped with model provenance.
    /// `model` selects the tier (#60); the implementation resamples to whatever
    /// the model requires.
    func diarize(
        samples: [Float],
        sampleRate: Double,
        model: DiarizationModel
    ) async throws -> DiarizationResult
}
