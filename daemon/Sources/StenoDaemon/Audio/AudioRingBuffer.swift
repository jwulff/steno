import Foundation

/// A fixed-duration slice of mono PCM audio, tagged with its position on a
/// frame-counted capture clock (seconds since the audio stream started).
///
/// Stores raw `Float` samples (a `Sendable` value) so it is safe to move
/// across actor/task boundaries and trivially testable without AVFoundation
/// buffers or audio hardware. Sample extraction from `AVAudioPCMBuffer` lives
/// in the capture path (`RecordingEngine`), keeping this type framework-free.
///
/// Mono only: channel 0, matching `RecordingEngine.peakLevel`. The deferred
/// diarization layer (epic #53) consumes mono samples; multichannel mixdown /
/// resampling is the diarizer front-end's concern, not this buffer's.
public struct PCMChunk: Sendable, Equatable {
    /// Seconds since capture start (frame-counted, monotonic). This is the
    /// join axis the diarization windower and — once #64 lands — transcript
    /// segments share.
    public let startTime: TimeInterval
    public let sampleRate: Double
    /// Channel-0 samples for this chunk.
    public let samples: [Float]

    public init(startTime: TimeInterval, sampleRate: Double, samples: [Float]) {
        self.startTime = startTime
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public var frameCount: Int { samples.count }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    public var endTime: TimeInterval { startTime + duration }
}

/// A bounded, time-indexed ring buffer of mono PCM audio for one capture
/// source. The audio tee appends chunks as they arrive; the rolling-window
/// scheduler (#58) reads fixed windows back out. Older audio is evicted once
/// it falls outside the retention horizon, so memory stays bounded regardless
/// of session length.
///
/// An `actor` because the writer (audio tee task) and reader (scheduler task)
/// touch it concurrently. Both already run in async contexts, so awaiting
/// `append` / `window` adds no thread-hopping beyond what the pipeline has.
///
/// Retention defaults to 90s: the diarization plan uses 60s windows sliding
/// every 45s, so a closing window needs ~60s of history still resident; 90s
/// leaves margin for scheduler lag.
public actor AudioRingBuffer {
    private let retention: TimeInterval
    /// Chunks in append order. Capture is monotonic, so this is also ascending
    /// by `startTime`.
    private var chunks: [PCMChunk] = []
    /// Highest `endTime` seen — the leading edge of the retention window.
    private var latestEnd: TimeInterval = 0

    public init(retention: TimeInterval = 90) {
        self.retention = retention
    }

    /// Append a chunk and evict anything that has aged out of the retention
    /// horizon. Out-of-order appends are tolerated (kept in arrival order);
    /// in practice capture is monotonic.
    public func append(_ chunk: PCMChunk) {
        chunks.append(chunk)
        latestEnd = max(latestEnd, chunk.endTime)
        prune()
    }

    /// Append raw mono samples at the buffer's current leading edge, assigning
    /// their start time from the internal capture clock — the running end of
    /// all audio appended since the last `reset`. This is the contiguous,
    /// frame-counted clock the diarization windower keys off; it advances by
    /// `samples.count / sampleRate` per call regardless of wall-clock gaps.
    /// No-op (returns the unchanged leading edge) for empty samples or a
    /// non-positive rate.
    @discardableResult
    public func append(samples: [Float], sampleRate: Double) -> TimeInterval {
        let start = latestEnd
        guard sampleRate > 0, !samples.isEmpty else { return start }
        append(PCMChunk(startTime: start, sampleRate: sampleRate, samples: samples))
        return start
    }

    /// Drop all retained audio and rewind the capture clock to 0. Called at
    /// each pipeline bring-up so the buffer's timeline is per-session.
    public func reset() {
        chunks.removeAll(keepingCapacity: true)
        latestEnd = 0
    }

    /// Chunks overlapping `[from, to)`, in arrival order. Boundary-straddling
    /// chunks are returned whole — the diarizer tolerates approximate window
    /// edges; callers may trim if they need sample-exact bounds. A half-open
    /// range means an empty `from == to` request returns nothing.
    public func window(from: TimeInterval, to: TimeInterval) -> [PCMChunk] {
        guard to > from else { return [] }
        return chunks.filter { $0.endTime > from && $0.startTime < to }
    }

    /// Exactly the samples falling in the half-open span `[from, to)`,
    /// concatenated in capture order. Unlike `window(from:to:)`, the first and
    /// last boundary-straddling chunks are **trimmed to sample boundaries**, so
    /// every returned frame lies in `[from, to)` and adjacent calls on abutting
    /// spans never re-emit a frame. This sample-exactness is what keeps a
    /// streaming diarizer's time base correct and its frame counter from being
    /// double-fed (each frame is handed to the diarizer exactly once).
    ///
    /// Returns `[]` for an empty/inverted range or when no retained audio falls
    /// in the span. The returned count is the number of frames actually present
    /// in `[from, to)`; a caller wanting a *fully resident* span must compare it
    /// against the expected width itself (the buffer cannot synthesize missing,
    /// pruned, or not-yet-captured frames).
    ///
    /// Trimming uses each chunk's own `sampleRate` for the time→frame
    /// conversion, rounding to the nearest frame so a boundary that lands
    /// mid-sample is resolved consistently on both sides.
    public func samples(from: TimeInterval, to: TimeInterval) -> [Float] {
        guard to > from else { return [] }
        var out: [Float] = []
        for chunk in chunks where chunk.endTime > from && chunk.startTime < to {
            let rate = chunk.sampleRate
            guard rate > 0 else { continue }
            let count = chunk.samples.count
            // Frame offsets of [from, to) within this chunk, clamped to it.
            let lo = max(0, Int(((from - chunk.startTime) * rate).rounded()))
            let hi = min(count, Int(((to - chunk.startTime) * rate).rounded()))
            guard lo < hi else { continue }
            out.append(contentsOf: chunk.samples[lo..<hi])
        }
        return out
    }

    /// Earliest retained sample time, or `nil` when empty. The scheduler uses
    /// this to know whether a window it wants is still fully resident.
    public func earliestTime() -> TimeInterval? { chunks.first?.startTime }

    /// Leading edge of captured audio (max `endTime` seen).
    public func latestTime() -> TimeInterval { latestEnd }

    public func isEmpty() -> Bool { chunks.isEmpty }

    private func prune() {
        let cutoff = latestEnd - retention
        // Drop leading chunks that have entirely aged out (endTime <= cutoff).
        guard let firstKeep = chunks.firstIndex(where: { $0.endTime > cutoff }) else {
            chunks.removeAll(keepingCapacity: true)
            return
        }
        if firstKeep > 0 {
            chunks.removeFirst(firstKeep)
        }
    }
}
