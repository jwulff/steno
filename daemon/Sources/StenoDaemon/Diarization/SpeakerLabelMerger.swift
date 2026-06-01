import Foundation

/// Pure merge logic that maps diarized window results onto transcript segments
/// by audio-clock timestamp intersection (epic #53 §3), and propagates labels
/// to dedup'd segments per the dedup gate (§9). Stateless — the engine (#61
/// wiring) supplies segments and persists the returned assignments.
public enum SpeakerLabelMerger {

    /// Overlap in seconds of `[aStart, aEnd)` and `[bStart, bEnd)`; 0 if
    /// disjoint or either span is empty/inverted.
    static func overlap(
        _ aStart: TimeInterval,
        _ aEnd: TimeInterval,
        _ bStart: TimeInterval,
        _ bEnd: TimeInterval
    ) -> TimeInterval {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// Assign a speaker to each **canonical** (non-duplicate) transcript segment
    /// by maximum temporal overlap with the window's labeled segments, on the
    /// audio capture clock. Returns `segmentId → speaker UUID`.
    ///
    /// Skipped (omitted from the result):
    /// - duplicates (`duplicateOf != nil`) — handled by `inheritedLabels` per
    ///   the §9 dedup gate, never labeled directly;
    /// - segments without audio time (`audioStart`/`audioEnd` nil — pre-#64 or
    ///   no valid range);
    /// - segments that overlap no labeled segment (a later window may cover
    ///   them; labels backfill).
    public static func assign(
        window: DiarizationWindowResult,
        segments: [StoredSegment]
    ) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for segment in segments {
            guard segment.duplicateOf == nil,
                let start = segment.audioStart,
                let end = segment.audioEnd
            else { continue }

            var best: (speaker: UUID, overlap: TimeInterval)?
            for labeled in window.segments {
                let amount = overlap(start, end, labeled.startTime, labeled.endTime)
                if amount > 0, best == nil || amount > best!.overlap {
                    best = (labeled.speaker.raw, amount)
                }
            }
            if let best {
                result[segment.id] = best.speaker
            }
        }
        return result
    }

    /// Dedup gate (#53 §9): each segment marked `duplicateOf` inherits the
    /// speaker of the canonical segment it duplicates, rather than being
    /// diarized itself — so mic bleed-through of system audio never mints or
    /// pollutes a speaker. Returns `segmentId → speaker UUID` for the duplicates
    /// whose canonical target already has a speaker in `canonicalSpeaker`.
    public static func inheritedLabels(
        duplicates: [StoredSegment],
        canonicalSpeaker: [UUID: UUID]
    ) -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for segment in duplicates {
            guard let target = segment.duplicateOf,
                let speaker = canonicalSpeaker[target]
            else { continue }
            result[segment.id] = speaker
        }
        return result
    }
}
