import Foundation

private func logSummary(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date())
    let logMessage = "[\(timestamp)] [Summary] \(message)\n"

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

/// Result of summary generation containing both brief summary and detailed notes.
public struct SummaryResult: Sendable {
    public let briefSummary: String
    public let meetingNotes: String
}

/// Coordinates automatic rolling summary generation.
///
/// This coordinator monitors segment saves and triggers summary generation
/// when either:
/// - A threshold number of new segments have accumulated, OR
/// - Any new segment exists and it's been longer than the time threshold since last summary
public actor RollingSummaryCoordinator {
    private let repository: TranscriptRepository
    private let summarizer: SummarizationService
    private let triggerCount: Int
    private let timeThreshold: TimeInterval
    private var lastSummaryTime: [UUID: Date] = [:]
    private var onSummaryGenerated: ((SummaryResult) -> Void)?

    /// Create a new rolling summary coordinator.
    ///
    /// - Parameters:
    ///   - repository: The repository for accessing segments and saving summaries.
    ///   - summarizer: The service to use for generating summaries.
    ///   - triggerCount: Number of new segments to trigger a summary (default: 10).
    ///   - timeThreshold: Seconds since last summary to trigger with any new segment (default: 30).
    ///   - onSummaryGenerated: Callback when new summary is generated.
    public init(
        repository: TranscriptRepository,
        summarizer: SummarizationService,
        triggerCount: Int = 10,
        timeThreshold: TimeInterval = 30,
        onSummaryGenerated: ((SummaryResult) -> Void)? = nil
    ) {
        self.repository = repository
        self.summarizer = summarizer
        self.triggerCount = triggerCount
        self.timeThreshold = timeThreshold
        self.onSummaryGenerated = onSummaryGenerated
    }

    /// Set the callback for when summaries are generated.
    public func setOnSummaryGenerated(_ callback: @escaping (SummaryResult) -> Void) {
        self.onSummaryGenerated = callback
    }

    /// Called after a segment is saved to check if summarization should trigger.
    ///
    /// - Parameter sessionId: The session that received a new segment.
    /// - Returns: The generated summary result if summarization was triggered, nil otherwise.
    @discardableResult
    public func onSegmentSaved(sessionId: UUID) async -> SummaryResult? {
        do {
            let count = try await repository.segmentCount(for: sessionId)
            let lastSummary = try await repository.latestSummary(for: sessionId)
            let lastSummarizedSequence = lastSummary?.segmentRangeEnd ?? 0

            let newSegmentCount = count - lastSummarizedSequence

            // Check time since last summary
            let now = Date()
            let lastTime = lastSummaryTime[sessionId]
            let timeSinceLastSummary = lastTime.map { now.timeIntervalSince($0) }

            let shouldTriggerByCount = newSegmentCount >= triggerCount
            // Time-based trigger requires at least 3 segments to avoid summarizing too little content
            let minSegmentsForTimeTrigger = 3
            let shouldTriggerByTime = newSegmentCount >= minSegmentsForTimeTrigger && (lastTime == nil || timeSinceLastSummary! >= timeThreshold)

            logSummary("Segments: \(count), new: \(newSegmentCount), time since last: \(timeSinceLastSummary.map { String(format: "%.0fs", $0) } ?? "never")")

            if shouldTriggerByCount || shouldTriggerByTime {
                let reason = shouldTriggerByCount ? "count threshold" : "time threshold"
                logSummary("Triggering summary (\(reason))...")
                let result = try await generateRollingSummary(
                    sessionId: sessionId,
                    fromSequence: lastSummarizedSequence + 1
                )
                lastSummaryTime[sessionId] = Date()
                return result
            }
            return nil
        } catch {
            // Log error but don't propagate - summarization is non-critical
            logSummary("Rolling summary failed: \(error)")
            return nil
        }
    }

    private func generateRollingSummary(sessionId: UUID, fromSequence: Int) async throws -> SummaryResult? {
        let allSegments = try await repository.segments(for: sessionId)
        let segments = allSegments.filter { $0.sequenceNumber >= fromSequence }

        guard let lastSegment = segments.last else {
            logSummary("No segments to summarize")
            return nil
        }

        let available = await summarizer.isAvailable
        logSummary("Model available: \(available)")
        guard available else {
            logSummary("Model not available, skipping summary")
            return nil
        }

        logSummary("Generating summary for \(segments.count) segments...")
        let lastSummary = try await repository.latestSummary(for: sessionId)

        // Generate both brief summary and detailed meeting notes
        async let briefSummaryTask = summarizer.summarize(
            segments: allSegments,  // Use all segments for context
            previousSummary: lastSummary?.content
        )
        async let meetingNotesTask = summarizer.generateMeetingNotes(
            segments: allSegments,  // Use all segments for complete notes
            previousNotes: nil
        )

        let briefSummary = try await briefSummaryTask
        let meetingNotes = try await meetingNotesTask

        let summary = Summary(
            sessionId: sessionId,
            content: briefSummary,
            segmentRangeStart: fromSequence,
            segmentRangeEnd: lastSegment.sequenceNumber,
            modelId: "apple-foundation-model"
        )

        try await repository.saveSummary(summary)
        logSummary("Summary saved: \(briefSummary.prefix(50))...")

        let result = SummaryResult(briefSummary: briefSummary, meetingNotes: meetingNotes)

        // Notify callback if set (for backwards compatibility)
        if let callback = onSummaryGenerated {
            callback(result)
        }

        return result
    }
}
