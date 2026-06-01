import Foundation

/// One diarized segment placed on the capture clock and tagged with a stable
/// global speaker (post-registry stitching). This is what the timestamp merge
/// (#61) joins against transcript segments.
public struct LabeledSegment: Sendable, Equatable {
    /// Capture-clock start/end, in seconds (window-relative time + the window's
    /// start offset).
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speaker: SpeakerID

    public init(startTime: TimeInterval, endTime: TimeInterval, speaker: SpeakerID) {
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
    }
}

/// The result of diarizing one closed window: its span, the model it ran
/// through, and the globally-labeled segments within it.
public struct DiarizationWindowResult: Sendable, Equatable {
    public let windowStart: TimeInterval
    public let windowEnd: TimeInterval
    public let model: DiarizationModel
    public let segments: [LabeledSegment]

    public init(
        windowStart: TimeInterval,
        windowEnd: TimeInterval,
        model: DiarizationModel,
        segments: [LabeledSegment]
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.model = model
        self.segments = segments
    }
}

/// Per-source streaming-window scheduler (epic #53 §3). Closes a `windowLength`
/// chunk every `windowLength` seconds — **non-overlapping** by default — and
/// feeds each closed chunk to a long-lived diarizer that maintains its own
/// within-source speaker identity across chunks (FluidAudio's Sortformer /
/// LS-EEND). Returns capture-clock-labeled segments via the shared registry's
/// stable-index path.
///
/// Pull-driven for determinism and to stay off the audio/render threads:
/// `processReadyWindows()` is invoked on a tick (e.g. the engine's existing
/// 10 Hz level cadence) and only closes chunks whose audio is fully resident
/// in the ring buffer. Diarization is awaited on this actor, so chunks for a
/// source are processed one at a time — no overlapping runs, natural
/// backpressure.
///
/// Non-overlapping is load-bearing: streaming diarizers see each frame once,
/// so an overlap-fed scheme would double-count audio and corrupt the
/// diarizer's internal frame counter. Cross-chunk speaker continuity is the
/// diarizer's job (its `speakerIndex` is stable across chunks), so no overlap
/// is needed for stitching — the registry just maps each `(sourceTag,
/// speakerIndex)` to a stable global `SpeakerID`.
public actor DiarizationScheduler {
    private let ringBuffer: AudioRingBuffer
    private let diarizer: DiarizationService
    private let registry: SpeakerRegistry
    private let sourceTag: String
    private let windowLength: TimeInterval
    /// Supplies the model tier per chunk. Defaults to `.sortformer`; the tier
    /// controller (#60) injects per-source escalation logic here.
    private let modelProvider: @Sendable () async -> DiarizationModel

    /// Start of the next chunk to close. Advances by `windowLength` per
    /// processed chunk, including chunks skipped on diarizer error (lossy by
    /// design).
    private var nextWindowStart: TimeInterval = 0

    public init(
        ringBuffer: AudioRingBuffer,
        diarizer: DiarizationService,
        registry: SpeakerRegistry,
        sourceTag: String,
        windowLength: TimeInterval = 45,
        modelProvider: @escaping @Sendable () async -> DiarizationModel = { .sortformer }
    ) {
        self.ringBuffer = ringBuffer
        self.diarizer = diarizer
        self.registry = registry
        self.sourceTag = sourceTag
        self.windowLength = windowLength
        self.modelProvider = modelProvider
    }

    /// Close and diarize every chunk now fully captured, advancing the cursor
    /// past each. Returns the results produced (possibly empty). Safe to call
    /// repeatedly on a tick — only fully-resident chunks are closed.
    ///
    /// Before diarizing a `[from, to)` window the scheduler verifies the **full
    /// span is still resident**. If the tick stalled long enough for retention
    /// to prune past `from` (notably while the diarization models are still
    /// downloading on first run), the window can no longer be reconstructed
    /// faithfully; diarizing the truncated remainder as if it were `[from, to)`
    /// would mislabel every segment's timestamp. In that case the cursor is
    /// fast-forwarded to the earliest still-retained time (dropping the partial
    /// audio, logged) rather than feeding partial audio to the diarizer.
    @discardableResult
    public func processReadyWindows() async -> [DiarizationWindowResult] {
        var results: [DiarizationWindowResult] = []
        while await ringBuffer.latestTime() >= nextWindowStart + windowLength {
            let from = nextWindowStart
            let to = from + windowLength

            // Residency gate: the window's start must still be retained. If
            // retention has advanced past `from`, fast-forward the cursor to the
            // earliest retained time and drop the partial window. (`earliestTime`
            // is nil only if the buffer emptied out from under us, which the
            // latestTime() loop guard already precludes here, but handle it.)
            if let earliest = await ringBuffer.earliestTime(), earliest > from {
                DaemonLogger.diarization.warning(
                    "Dropping partial diarization window [\(from, privacy: .public), \(to, privacy: .public)) for source \(self.sourceTag, privacy: .public): start pruned by retention (earliest=\(earliest, privacy: .public)); fast-forwarding cursor."
                )
                nextWindowStart = earliest
                continue
            }

            nextWindowStart = to
            if let result = await processWindow(from: from, to: to) {
                results.append(result)
            }
        }
        return results
    }

    private func processWindow(
        from: TimeInterval,
        to: TimeInterval
    ) async -> DiarizationWindowResult? {
        // Sample-rate provenance comes from the chunks overlapping the span;
        // the actual audio is pulled sample-exact (boundary chunks trimmed) so
        // each frame is fed to the streaming diarizer exactly once and the
        // window's time base starts precisely at `from`.
        let chunks = await ringBuffer.window(from: from, to: to)
        guard let sampleRate = chunks.first?.sampleRate, sampleRate > 0 else {
            return nil
        }
        let samples = await ringBuffer.samples(from: from, to: to)
        guard !samples.isEmpty else { return nil }

        let model = await modelProvider()
        let diarization: DiarizationResult
        do {
            diarization = try await diarizer.diarize(
                samples: samples,
                sampleRate: sampleRate,
                model: model
            )
        } catch {
            // Lossy by design (#53 §8): drop this chunk, keep the cursor
            // advanced so we don't wedge on a persistently failing chunk.
            return nil
        }

        // Map each distinct window-local speaker index to a stable global ID.
        // FluidAudio's tier diarizers keep the index stable across chunks, so
        // the registry just remembers `(sourceTag, speakerIndex) → SpeakerID`.
        var indexToSpeaker: [Int: SpeakerID] = [:]
        for segment in diarization.segments where indexToSpeaker[segment.speaker] == nil {
            indexToSpeaker[segment.speaker] = await registry.assignStableIndex(
                speakerIndex: segment.speaker,
                sourceTag: sourceTag,
                modelId: diarization.modelId,
                modelVersion: diarization.modelVersion
            )
        }

        // Offset window-relative segment times onto the capture clock.
        let labeled = diarization.segments.compactMap { segment -> LabeledSegment? in
            guard let speaker = indexToSpeaker[segment.speaker] else { return nil }
            return LabeledSegment(
                startTime: from + segment.startTime,
                endTime: from + segment.endTime,
                speaker: speaker
            )
        }

        return DiarizationWindowResult(
            windowStart: from,
            windowEnd: to,
            model: model,
            segments: labeled
        )
    }
}
