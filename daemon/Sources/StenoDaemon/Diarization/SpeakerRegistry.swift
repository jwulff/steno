import Foundation

/// Opaque, stable identifier for a speaker across windows (and, via #54,
/// across sessions). Deliberately NOT the "Speaker N" display string — display
/// is a separate concern derived from this ID plus an optional name, so a
/// persisted identity can carry a real name later (epic #53 §4).
public struct SpeakerID: Hashable, Sendable, Codable {
    public let raw: UUID

    public init(raw: UUID = UUID()) {
        self.raw = raw
    }
}

/// Whether a speaker identity is trusted enough to persist. A speaker is
/// `provisional` until it has recurred across enough windows; only `confirmed`
/// identities are eligible for the cross-session voiceprint DB (#54). The
/// dedup-survival half of the confirmation rule (#53 §9) is enforced by the
/// caller (#61), which only feeds surviving segments here.
public enum EnrollmentState: String, Sendable, Codable {
    case provisional
    case confirmed
}

/// A global speaker known to the registry: a running-average voice centroid
/// plus the bookkeeping needed to stitch, confirm, and (later) persist it.
/// `Codable` so the whole record is the persistence unit for #54 — no rework
/// needed when a SQLite-backed store lands.
public struct RegisteredSpeaker: Sendable, Codable, Equatable {
    public let id: SpeakerID
    /// Running-average embedding over all samples assigned to this speaker.
    public var centroid: [Float]
    /// Number of window embeddings folded into `centroid` (the averaging
    /// denominator).
    public var sampleCount: Int
    /// Distinct windows this speaker has appeared in (drives confirmation).
    public var windowsSeen: Int
    public var state: EnrollmentState
    /// Model provenance the centroid was produced under. Embeddings are only
    /// comparable within the same model id + version (#53 §4); a model upgrade
    /// invalidates the centroid.
    public let modelId: String
    public let modelVersion: String
    /// Optional human label (assigned via the UI; persisted by #54).
    public var name: String?

    public init(
        id: SpeakerID,
        centroid: [Float],
        sampleCount: Int,
        windowsSeen: Int,
        state: EnrollmentState,
        modelId: String,
        modelVersion: String,
        name: String? = nil
    ) {
        self.id = id
        self.centroid = centroid
        self.sampleCount = sampleCount
        self.windowsSeen = windowsSeen
        self.state = state
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.name = name
    }
}

/// Session-level registry that stitches per-window, window-local speakers into
/// stable global `SpeakerID`s by matching voice embeddings via cosine
/// similarity (epic #53 §4). Shared across both audio sources, so a physical
/// person resolves to one ID regardless of which stream they appear in.
///
/// An `actor`: the per-source diarization tasks (#58) feed it concurrently.
/// State is a plain dictionary of `Codable` records, so `snapshot()` / the
/// seed initializer are the seam the persistent voiceprint DB (#54) plugs into
/// without changing this logic.
public actor SpeakerRegistry {
    /// Minimum cosine similarity to treat a window speaker as an existing
    /// global speaker. Needs empirical calibration (#54 lists this as an open
    /// tradeoff); too low merges distinct people, too high splits one person.
    private let similarityThreshold: Float
    /// Windows a speaker must appear in before being promoted to `confirmed`.
    private let confirmAfterWindows: Int
    private var speakers: [SpeakerID: RegisteredSpeaker]

    /// `(sourceTag, FluidAudio speakerIndex) → SpeakerID` cache for the
    /// stable-index stitching path. FluidAudio's tier diarizers (Sortformer /
    /// LS-EEND) maintain stable per-source speaker indices across streamed
    /// chunks, so within-source stitching is identity-based, not cosine — we
    /// just map the (source, index) pair to a stable global `SpeakerID`. The
    /// cosine-embedding path stays available for future use (#54 voiceprints,
    /// alternative diarizers that expose embeddings).
    private struct SourceIndexKey: Hashable, Sendable {
        let sourceTag: String
        let speakerIndex: Int
    }
    private var stableIndexMap: [SourceIndexKey: SpeakerID] = [:]

    public init(
        similarityThreshold: Float = 0.7,
        confirmAfterWindows: Int = 2,
        seed: [RegisteredSpeaker] = []
    ) {
        self.similarityThreshold = similarityThreshold
        self.confirmAfterWindows = confirmAfterWindows
        self.speakers = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    public var count: Int { speakers.count }

    public func speaker(_ id: SpeakerID) -> RegisteredSpeaker? { speakers[id] }

    /// All known speakers — the unit the voiceprint DB (#54) persists.
    public func snapshot() -> [RegisteredSpeaker] { Array(speakers.values) }

    /// Pre-enroll a known speaker as `confirmed` (e.g. seeding from the
    /// voiceprint DB at session start, #53 §4.5). Returns its ID.
    @discardableResult
    public func enroll(
        embedding: [Float],
        modelId: String,
        modelVersion: String,
        name: String? = nil
    ) -> SpeakerID {
        let id = SpeakerID()
        speakers[id] = RegisteredSpeaker(
            id: id,
            centroid: embedding,
            sampleCount: 1,
            windowsSeen: 1,
            state: .confirmed,
            modelId: modelId,
            modelVersion: modelVersion,
            name: name
        )
        return id
    }

    /// Map a diarizer's stable per-source speaker index to a global `SpeakerID`,
    /// minting one the first time the `(sourceTag, speakerIndex)` pair is seen
    /// and returning the same ID on every subsequent call. This is the
    /// within-source stitching path used with FluidAudio's tier diarizers
    /// (Sortformer / LS-EEND), which keep `speakerIndex` stable across streamed
    /// chunks themselves. The cross-source unification still happens here: two
    /// sources naming "speaker 1" map to different global IDs (different
    /// `sourceTag`), exactly as intended — cross-source overlap is resolved by
    /// the §9 dedup gate, not by index aliasing.
    ///
    /// Minted speakers are stamped `.confirmed` because the diarizer's own
    /// across-chunk stability is the confirmation signal; the
    /// `confirmAfterWindows` threshold belongs to the cosine path. No centroid
    /// is recorded (`[]`) — embedding-based identity is a separate concern.
    public func assignStableIndex(
        speakerIndex: Int,
        sourceTag: String,
        modelId: String,
        modelVersion: String
    ) -> SpeakerID {
        let key = SourceIndexKey(sourceTag: sourceTag, speakerIndex: speakerIndex)
        if let existing = stableIndexMap[key] {
            return existing
        }
        let id = SpeakerID()
        stableIndexMap[key] = id
        speakers[id] = RegisteredSpeaker(
            id: id,
            centroid: [],
            sampleCount: 0,
            windowsSeen: 1,
            state: .confirmed,
            modelId: modelId,
            modelVersion: modelVersion
        )
        return id
    }

    /// Stitch one window's per-speaker embeddings to global IDs: match each to
    /// the best comparable existing speaker (same model, similarity ≥
    /// threshold, one-to-one within the window), updating that speaker's
    /// centroid; mint a new provisional speaker for anything unmatched.
    /// Returns window-local speaker index → global `SpeakerID`.
    @discardableResult
    public func assign(
        _ embeddings: [SpeakerEmbedding],
        modelId: String,
        modelVersion: String
    ) -> [Int: SpeakerID] {
        // Candidates must be comparable: same model + same dimensionality.
        let candidates = speakers.values.filter {
            $0.modelId == modelId && $0.modelVersion == modelVersion
        }

        // Score every (window speaker, candidate) pair above threshold, then
        // assign greedily by descending similarity so the strongest matches
        // win and each side is claimed at most once per window.
        struct Match {
            let local: Int
            let id: SpeakerID
            let similarity: Float
        }
        var matches: [Match] = []
        for embedding in embeddings {
            for candidate in candidates
            where candidate.centroid.count == embedding.vector.count {
                let similarity = Self.cosineSimilarity(embedding.vector, candidate.centroid)
                if similarity >= similarityThreshold {
                    matches.append(
                        Match(local: embedding.speaker, id: candidate.id, similarity: similarity)
                    )
                }
            }
        }
        matches.sort { $0.similarity > $1.similarity }

        var assignment: [Int: SpeakerID] = [:]
        var claimedIDs: Set<SpeakerID> = []
        var assignedLocals: Set<Int> = []
        for match in matches {
            if assignedLocals.contains(match.local) || claimedIDs.contains(match.id) {
                continue
            }
            assignment[match.local] = match.id
            assignedLocals.insert(match.local)
            claimedIDs.insert(match.id)
        }

        // Apply: update matched centroids, mint new speakers for the rest.
        for embedding in embeddings {
            if let id = assignment[embedding.speaker], var matched = speakers[id] {
                matched.centroid = Self.updatedCentroid(
                    matched.centroid,
                    count: matched.sampleCount,
                    adding: embedding.vector
                )
                matched.sampleCount += 1
                matched.windowsSeen += 1
                if matched.windowsSeen >= confirmAfterWindows {
                    matched.state = .confirmed
                }
                speakers[id] = matched
            } else {
                let id = SpeakerID()
                speakers[id] = RegisteredSpeaker(
                    id: id,
                    centroid: embedding.vector,
                    sampleCount: 1,
                    windowsSeen: 1,
                    state: confirmAfterWindows <= 1 ? .confirmed : .provisional,
                    modelId: modelId,
                    modelVersion: modelVersion
                )
                assignment[embedding.speaker] = id
            }
        }
        return assignment
    }

    /// Cosine similarity of two equal-length vectors in [-1, 1]. Returns 0 for
    /// mismatched lengths, empty input, or a zero-magnitude vector.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Incremental running average: fold `addition` into a centroid that
    /// currently averages `count` samples. No-op on dimension mismatch.
    private static func updatedCentroid(
        _ centroid: [Float],
        count: Int,
        adding addition: [Float]
    ) -> [Float] {
        guard centroid.count == addition.count else { return centroid }
        let n = Float(count)
        var result = centroid
        for i in result.indices {
            result[i] = (result[i] * n + addition[i]) / (n + 1)
        }
        return result
    }
}
