import AVFoundation
import Foundation

/// A fixed-duration slice of mono PCM audio, tagged with its position on a
/// frame-counted capture clock (seconds since the audio stream started).
///
/// Stores raw `Float` samples rather than an `AVAudioPCMBuffer` reference so
/// the type is a `Sendable` value: safe to move across actor/task boundaries
/// and trivially testable without AVFoundation buffers or audio hardware.
///
/// Mono only: we keep channel 0, matching `RecordingEngine.peakLevel`. The
/// deferred diarization layer (epic #53) consumes mono samples; multichannel
/// mixdown / resampling is the diarizer front-end's concern, not this buffer's.
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

    /// Extract channel 0 of an `AVAudioPCMBuffer` into a value-type chunk.
    /// Returns `nil` for a non-float or empty buffer.
    public static func from(
        buffer: AVAudioPCMBuffer,
        startTime: TimeInterval
    ) -> PCMChunk? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
        return PCMChunk(
            startTime: startTime,
            sampleRate: buffer.format.sampleRate,
            samples: samples
        )
    }
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

    /// Chunks overlapping `[from, to)`, in arrival order. Boundary-straddling
    /// chunks are returned whole — the diarizer tolerates approximate window
    /// edges; callers may trim if they need sample-exact bounds. A half-open
    /// range means an empty `from == to` request returns nothing.
    public func window(from: TimeInterval, to: TimeInterval) -> [PCMChunk] {
        guard to > from else { return [] }
        return chunks.filter { $0.endTime > from && $0.startTime < to }
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
