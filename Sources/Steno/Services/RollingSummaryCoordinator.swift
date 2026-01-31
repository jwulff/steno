import Foundation

/// Coordinates automatic rolling summary generation.
///
/// This coordinator monitors segment saves and triggers summary generation
/// when a threshold number of new segments have accumulated since the
/// last summary.
public actor RollingSummaryCoordinator {
    private let repository: TranscriptRepository
    private let summarizer: SummarizationService
    private let triggerCount: Int

    /// Create a new rolling summary coordinator.
    ///
    /// - Parameters:
    ///   - repository: The repository for accessing segments and saving summaries.
    ///   - summarizer: The service to use for generating summaries.
    ///   - triggerCount: Number of new segments to trigger a summary (default: 10).
    public init(
        repository: TranscriptRepository,
        summarizer: SummarizationService,
        triggerCount: Int = 10
    ) {
        self.repository = repository
        self.summarizer = summarizer
        self.triggerCount = triggerCount
    }

    /// Called after a segment is saved to check if summarization should trigger.
    ///
    /// - Parameter sessionId: The session that received a new segment.
    public func onSegmentSaved(sessionId: UUID) async {
        do {
            let count = try await repository.segmentCount(for: sessionId)
            let lastSummary = try await repository.latestSummary(for: sessionId)
            let lastSummarizedSequence = lastSummary?.segmentRangeEnd ?? 0

            let newSegmentCount = count - lastSummarizedSequence

            if newSegmentCount >= triggerCount {
                try await generateRollingSummary(
                    sessionId: sessionId,
                    fromSequence: lastSummarizedSequence + 1
                )
            }
        } catch {
            // Log error but don't propagate - summarization is non-critical
            print("Rolling summary failed: \(error)")
        }
    }

    private func generateRollingSummary(sessionId: UUID, fromSequence: Int) async throws {
        let allSegments = try await repository.segments(for: sessionId)
        let segments = allSegments.filter { $0.sequenceNumber >= fromSequence }

        guard let lastSegment = segments.last else { return }

        guard await summarizer.isAvailable else { return }

        let lastSummary = try await repository.latestSummary(for: sessionId)

        let summaryText = try await summarizer.summarize(
            segments: segments,
            previousSummary: lastSummary?.content
        )

        let summary = Summary(
            sessionId: sessionId,
            content: summaryText,
            segmentRangeStart: fromSequence,
            segmentRangeEnd: lastSegment.sequenceNumber,
            modelId: "apple-foundation-model"
        )

        try await repository.saveSummary(summary)
    }
}
