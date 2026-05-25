import FluidAudio
import Foundation

/// Errors specific to the FluidAudio-backed diarization service.
public enum DefaultDiarizationServiceError: Error, Equatable {
    /// `prepareModels()` was not awaited (or it failed) before `diarize` was
    /// called for this tier.
    case notInitialized(DiarizationModel)
}

/// FluidAudio-backed `DiarizationService` for the diarization epic (#53,
/// work item §6.3). Wraps a long-lived `SortformerDiarizer` and `LSEENDDiarizer`
/// — the two models the tier controller (#60) switches between — and presents
/// them through our per-chunk `diarize` contract.
///
/// FluidAudio's tier diarizers are streaming: each instance maintains its own
/// stable `speakerIndex` across consecutive chunks fed to it, which is exactly
/// the within-source identity stitching we used to do with cosine over
/// embeddings. So this wrapper:
///
/// - Keeps each diarizer instance alive for the session and feeds it
///   non-overlapping chunks (the scheduler #58 enforces non-overlap).
/// - Returns **no** `SpeakerEmbedding`s — FluidAudio's Sortformer / LS-EEND
///   don't expose per-speaker embeddings in 0.x; the cosine path in #59
///   stays available for future use (#54 voiceprints via a different
///   embedding extractor), but the within-source stitching now goes through
///   `SpeakerRegistry.assignStableIndex(...)`.
/// - Tracks per-tier cumulative audio time so it can translate FluidAudio's
///   cumulative-timeline segment times back to chunk-relative times (the
///   contract `DiarizationScheduler` consumes).
///
/// **Per source.** A `DefaultDiarizationService` instance is per audio source
/// (mic / system audio). Both sources still share a single `SpeakerRegistry`;
/// the `sourceTag` lives on the scheduler, not here. Tier switches are sticky
/// (#60), so in practice each instance settles on one diarizer.
public actor DefaultDiarizationService: DiarizationService {

    private var sortformer: SortformerDiarizer?
    private var lseend: LSEENDDiarizer?

    /// Sample-rate the FluidAudio diarizers want for `sourceSampleRate` to be
    /// ignored — both target 16 kHz. We pass the source rate as-is and let
    /// FluidAudio resample internally.
    private let lseendVariant: LSEENDVariant

    /// Cumulative seconds of audio fed to each tier's diarizer. Used to
    /// translate FluidAudio's cumulative timeline back to chunk-relative
    /// times for the scheduler.
    private var cumulativeSeconds: [DiarizationModel: TimeInterval] = [:]

    public init(lseendVariant: LSEENDVariant = .dihard3) {
        self.lseendVariant = lseendVariant
    }

    /// Download (cached) and initialize both tier diarizers. Network on first
    /// run; idempotent on subsequent calls — already-initialized diarizers are
    /// left alone.
    public func prepareModels() async throws {
        if sortformer == nil {
            let diarizer = SortformerDiarizer()
            let models = try await SortformerModels.loadFromHuggingFace(
                config: diarizer.config
            )
            diarizer.initialize(models: models)
            sortformer = diarizer
        }
        if lseend == nil {
            let diarizer = LSEENDDiarizer()
            try await diarizer.initialize(variant: lseendVariant)
            lseend = diarizer
        }
    }

    public func diarize(
        samples: [Float],
        sampleRate: Double,
        model: DiarizationModel
    ) async throws -> DiarizationResult {
        guard let diarizer = activeDiarizer(for: model) else {
            throw DefaultDiarizationServiceError.notInitialized(model)
        }

        let cumBefore = cumulativeSeconds[model] ?? 0
        try diarizer.addAudio(samples, sourceSampleRate: sampleRate)

        // Track how much we've fed. Use the source sample rate (FluidAudio
        // resamples internally but the *wall-clock duration* of the audio is
        // what the chunk-relative translation cares about).
        let chunkDuration =
            sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        cumulativeSeconds[model] = cumBefore + chunkDuration

        let update = try diarizer.process()
        let segments = (update?.finalizedSegments ?? []).map { segment in
            // FluidAudio reports frame indices on the diarizer's cumulative
            // timeline; convert to seconds, then offset back to chunk-relative
            // so the scheduler can apply its standard `from + offset` to put
            // segments on the capture clock.
            let cumStart = Double(segment.startFrame) * Double(segment.frameDurationSeconds)
            let cumEnd = Double(segment.endFrame) * Double(segment.frameDurationSeconds)
            return DiarizedSegment(
                startTime: cumStart - cumBefore,
                endTime: cumEnd - cumBefore,
                speaker: segment.speakerIndex
            )
        }

        return DiarizationResult(
            segments: segments,
            embeddings: [],
            modelId: modelId(for: model),
            modelVersion: modelVersion(for: model)
        )
    }

    private func activeDiarizer(for model: DiarizationModel) -> (any Diarizer)? {
        switch model {
        case .sortformer: return sortformer
        case .lsEEND: return lseend
        }
    }

    private func modelId(for model: DiarizationModel) -> String {
        switch model {
        case .sortformer: return "fluidaudio.sortformer"
        case .lsEEND: return "fluidaudio.lseend.\(lseendVariant)"
        }
    }

    /// Pinned FluidAudio package version; the actual model artifact version is
    /// implicit in the HuggingFace download cache and surfaces here as a
    /// coarse identifier sufficient to refuse cross-version embedding
    /// comparison (#53 §4 design-for-persistence). Update when the
    /// FluidAudio dependency is bumped.
    private func modelVersion(for model: DiarizationModel) -> String {
        "fluidaudio-0.14"
    }
}
