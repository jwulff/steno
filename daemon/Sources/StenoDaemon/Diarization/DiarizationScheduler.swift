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

/// Per-source rolling-window scheduler (epic #53 §3). Closes a `windowLength`
/// window every `slide` seconds — consecutive windows share
/// `windowLength - slide` of overlap (15s by default) — runs each closed
/// window through the diarizer, stitches window-local speakers to global IDs
/// via the shared registry, and returns capture-clock-labeled segments.
///
/// Pull-driven for determinism and to stay off the audio/render threads:
/// `processReadyWindows()` is invoked on a tick (e.g. the engine's existing
/// 10 Hz level cadence) and only closes windows whose audio is fully resident
/// in the ring buffer. Diarization is awaited on this actor, so windows for a
/// source are processed one at a time — no overlapping runs, natural
/// backpressure.
///
/// The 15s window overlap is the cross-window identity anchor: the same
/// speaker appears in the tail of window N and the head of window N+1, so the
/// registry's cosine match (#59) ties them to one `SpeakerID`. No separate
/// overlap-stitching code is needed — the cadence + registry achieve it.
public actor DiarizationScheduler {
    private let ringBuffer: AudioRingBuffer
    private let diarizer: DiarizationService
    private let registry: SpeakerRegistry
    private let windowLength: TimeInterval
    private let slide: TimeInterval
    /// Supplies the model tier per window. Defaults to `.sortformer`; the tier
    /// controller (#60) injects per-source escalation logic here.
    private let modelProvider: @Sendable () async -> DiarizationModel

    /// Start of the next window to close. Advances by `slide` per processed
    /// window, including windows skipped on diarizer error (lossy by design).
    private var nextWindowStart: TimeInterval = 0

    public init(
        ringBuffer: AudioRingBuffer,
        diarizer: DiarizationService,
        registry: SpeakerRegistry,
        windowLength: TimeInterval = 60,
        slide: TimeInterval = 45,
        modelProvider: @escaping @Sendable () async -> DiarizationModel = { .sortformer }
    ) {
        self.ringBuffer = ringBuffer
        self.diarizer = diarizer
        self.registry = registry
        self.windowLength = windowLength
        self.slide = slide
        self.modelProvider = modelProvider
    }

    /// Close and diarize every window now fully captured, advancing the slide
    /// cursor past each. Returns the results produced (possibly empty). Safe to
    /// call repeatedly on a tick — only fully-resident windows are closed.
    @discardableResult
    public func processReadyWindows() async -> [DiarizationWindowResult] {
        var results: [DiarizationWindowResult] = []
        while await ringBuffer.latestTime() >= nextWindowStart + windowLength {
            let from = nextWindowStart
            let to = from + windowLength
            nextWindowStart += slide
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
        let chunks = await ringBuffer.window(from: from, to: to)
        guard let sampleRate = chunks.first?.sampleRate, sampleRate > 0 else {
            return nil
        }
        let samples = chunks.flatMap(\.samples)
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
            // Lossy by design (#53 §8): drop this window, keep the cursor
            // advanced so we don't wedge on a persistently failing window.
            return nil
        }

        let assignment = await registry.assign(
            diarization.embeddings,
            modelId: diarization.modelId,
            modelVersion: diarization.modelVersion
        )

        // Offset window-relative segment times onto the capture clock and
        // attach the stitched global speaker.
        let labeled = diarization.segments.compactMap { segment -> LabeledSegment? in
            guard let speaker = assignment[segment.speaker] else { return nil }
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
