import Foundation

/// How a duplicate match was scored. Maps to the storage-layer
/// `segments.dedup_method` CHECK-constrained string column.
public enum DedupMethod: String, Sendable, Codable, Equatable {
    /// `a == b` byte-for-byte.
    case exact
    /// Equal after lowercase + punctuation strip + whitespace collapse.
    case normalized
    /// Edit-distance ratio (`1 - levenshtein / max(|a|, |b|)`) above threshold.
    case fuzzy
}

/// Counts returned by a single `runPass` invocation, useful for logging /
/// asserting in tests. Internal to the coordinator's API surface — the
/// engine ignores the value.
public struct DedupOutcome: Sendable, Equatable {
    /// Number of mic segments inspected this pass (cursor moved over them).
    public let evaluated: Int
    /// Number of mic segments newly marked `duplicate_of=<sys.id>`.
    public let marked: Int
    /// Number of mic segments inspected but NOT marked (no overlapping sys
    /// match, score below threshold, or audio-level guard rejected).
    public let skipped: Int

    public init(evaluated: Int, marked: Int, skipped: Int) {
        self.evaluated = evaluated
        self.marked = marked
        self.skipped = skipped
    }

    public static let empty = DedupOutcome(evaluated: 0, marked: 0, skipped: 0)
}

private func logDedup(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date())
    let logMessage = "[\(timestamp)] [Dedup] \(message)\n"

    let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".steno.log")

    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

/// Background coordinator that finds time-overlapping mic/sys segment pairs
/// and marks high-confidence mic matches as `duplicate_of` the matching sys
/// segment.
///
/// Pattern: shape mirrors `RollingSummaryCoordinator` — load → filter
/// uncovered → process → persist with cursor advance, with a
/// reentrance guard. The cursor is the U2-added `sessions.last_deduped_segment_seq`
/// column (per the plan's "new column-based cursor pattern" refinement).
///
/// Tier ladder for similarity scoring (highest first):
///   1. **exact**: `a == b` → score 1.0.
///   2. **normalized**: lowercase, strip punctuation, collapse whitespace,
///      then `==` → score 1.0.
///   3. **fuzzy**: `1 - (levenshtein(a, b) / max(|a|, |b|))`.
///
/// Audio-level guard (R10 user-repeats-speaker safety): a mic segment whose
/// `micPeakDb` is at or above the passive-pickup threshold (default `-25
/// dBFS`) is KEPT even if its score crosses the dedup threshold —
/// loud-mic segments are assumed to be the user actively speaking the same
/// words as the speaker. `micPeakDb == nil` (not measured) → SKIP the
/// guard (treat as eligible). Borderline scores → KEEP.
public actor DedupCoordinator {
    private let repository: TranscriptRepository
    private let overlapSeconds: TimeInterval
    private let scoreThreshold: Double
    private let micPeakThresholdDb: Double

    /// Reentrance guard keyed by sessionId. Concurrent triggers for the
    /// same session collapse to a single in-flight pass; cross-session
    /// passes can run in parallel.
    private var isProcessing: [UUID: Bool] = [:]

    /// - Parameters:
    ///   - repository: The repository used for reads + dedup writes.
    ///   - overlapSeconds: Half-window around a mic segment's start for
    ///     matching sys candidates (default 3.0 — see plan).
    ///   - scoreThreshold: Minimum similarity score to mark a duplicate
    ///     (default 0.92 — borderline-keep policy).
    ///   - micPeakThresholdDb: Mic must be quieter than this to be
    ///     considered "passive pickup" (default -25.0 dBFS).
    public init(
        repository: TranscriptRepository,
        overlapSeconds: TimeInterval = 3.0,
        scoreThreshold: Double = 0.92,
        micPeakThresholdDb: Double = -25.0
    ) {
        self.repository = repository
        self.overlapSeconds = overlapSeconds
        self.scoreThreshold = scoreThreshold
        self.micPeakThresholdDb = micPeakThresholdDb
    }

    /// Run a dedup pass for `sessionId`. Idempotent across runs:
    /// the per-session cursor is persisted at the end and only advances
    /// over mic segments actually evaluated.
    ///
    /// **Reentrance:** if a pass for the same session is already running,
    /// returns `.empty` without scheduling another. Cross-session passes
    /// can run concurrently.
    ///
    /// **Failure-safe:** if any repository call throws partway through,
    /// the cursor is NOT advanced — the next pass picks up from the same
    /// segment. Already-marked duplicates are committed as the `markDuplicate`
    /// calls succeed; a partial pass is acceptable because the next pass
    /// re-reads them as already-marked (filtered by `duplicate_of IS NULL`)
    /// and skips them.
    @discardableResult
    public func runPass(sessionId: UUID) async -> DedupOutcome {
        if isProcessing[sessionId] == true {
            return .empty
        }
        isProcessing[sessionId] = true
        defer { isProcessing[sessionId] = false }

        do {
            // 1. Load mic segments past the cursor that aren't already marked.
            let micSegments = try await repository.segmentsAfterDedupCursor(
                sessionId: sessionId,
                source: .microphone
            )

            guard !micSegments.isEmpty else {
                logDedup("Session \(sessionId) — no new mic segments past cursor")
                return .empty
            }

            var marked = 0
            var skipped = 0
            var maxEvaluatedSeq = 0

            for mic in micSegments {
                maxEvaluatedSeq = max(maxEvaluatedSeq, mic.sequenceNumber)

                // 2. Find time-overlapping sys candidates.
                let from = mic.startedAt.addingTimeInterval(-overlapSeconds)
                let to = mic.startedAt.addingTimeInterval(overlapSeconds)
                let candidates = try await repository.overlappingSegments(
                    sessionId: sessionId,
                    source: .systemAudio,
                    from: from,
                    to: to
                )

                if candidates.isEmpty {
                    skipped += 1
                    continue
                }

                // 3. Score and pick the best.
                var best: (segment: StoredSegment, score: Double, method: DedupMethod)?
                for sys in candidates {
                    let result = similarityScore(mic.text, sys.text)
                    if best == nil || result.score > best!.score {
                        best = (sys, result.score, result.method)
                    }
                }

                guard let pick = best, pick.score >= scoreThreshold else {
                    skipped += 1
                    continue
                }

                // 4. Audio-level guard. NULL mic_peak_db → treat as eligible
                // (not enough signal to reject; future segments will carry
                // a measured value once the engine plumbs it).
                if let peakDb = mic.micPeakDb, peakDb >= micPeakThresholdDb {
                    // Loud mic — likely the user speaking the same words.
                    skipped += 1
                    continue
                }

                // 5. Mark.
                try await repository.markDuplicate(
                    micSegmentId: mic.id,
                    sysSegmentId: pick.segment.id,
                    method: pick.method
                )
                marked += 1
            }

            // 6. Cursor advance — last step. Per-mic-seq, NOT per-pass-max:
            // we advance to the highest mic-seq we EVALUATED, not the highest
            // segment-seq across all sources, so an out-of-order mic segment
            // arriving later isn't skipped.
            try await repository.advanceDedupCursor(
                sessionId: sessionId,
                toSequence: maxEvaluatedSeq
            )

            let outcome = DedupOutcome(
                evaluated: micSegments.count,
                marked: marked,
                skipped: skipped
            )
            logDedup("Session \(sessionId) — pass complete: \(outcome.evaluated) evaluated, \(outcome.marked) marked, \(outcome.skipped) skipped")
            return outcome
        } catch {
            // Non-critical: log and surrender. Cursor was not advanced
            // because the UPDATE is the last step in the do-block.
            logDedup("Session \(sessionId) — pass FAILED: \(error) [\(type(of: error))]")
            return .empty
        }
    }

    // MARK: - Similarity (private)

    /// Tiered match: exact → normalized → edit-distance ratio. Returns the
    /// highest-tier method that produced a non-zero score.
    ///
    /// Both-empty inputs return `(0.0, .fuzzy)` — neither tier 1 nor tier 2
    /// is meaningful (empty strings are also CHECK-constrained out by the
    /// schema's `length(text) > 0`). The dedup pass treats this as below
    /// threshold and KEEPs both segments.
    func similarityScore(_ a: String, _ b: String) -> (score: Double, method: DedupMethod) {
        if a.isEmpty && b.isEmpty {
            return (0.0, .fuzzy)
        }

        if a == b {
            return (1.0, .exact)
        }

        let na = Self.normalize(a)
        let nb = Self.normalize(b)
        if !na.isEmpty && na == nb {
            return (1.0, .normalized)
        }

        // Fuzzy: edit-distance ratio over the longer normalized form so
        // capitalization / punctuation differences don't tank the score.
        let distance = Self.levenshtein(na, nb)
        let denom = max(na.count, nb.count)
        guard denom > 0 else {
            return (0.0, .fuzzy)
        }
        let score = 1.0 - (Double(distance) / Double(denom))
        return (max(0.0, score), .fuzzy)
    }

    /// Lowercase, strip ASCII punctuation, collapse whitespace runs to a
    /// single space, trim leading/trailing whitespace. Pure function.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        // Strip punctuation. Use Unicode `.punctuationCharacters` so smart
        // quotes / em-dashes are removed too.
        let punctuationStripped = lowered.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
        }
        var result = String(String.UnicodeScalarView(punctuationStripped))
        // Collapse whitespace runs.
        let components = result
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        result = components.joined(separator: " ")
        return result
    }

    /// Plain DP Levenshtein distance over `Character` arrays. Schema caps
    /// segment text at 10000 chars, but in practice mic/sys utterances run
    /// well under that — O(n*m) is fine here without SIMD or rolling rows.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count

        if n == 0 { return m }
        if m == 0 { return n }

        // Rolling two-row implementation to keep memory bounded at O(min(n,m)).
        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[m]
    }
}
