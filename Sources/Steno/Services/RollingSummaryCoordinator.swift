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

/// Result of summary generation containing brief summary, detailed notes, and topics.
public struct SummaryResult: Sendable {
    public let briefSummary: String
    public let meetingNotes: String
    public let topics: [Topic]
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
    private var isGenerating = false

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
        // Prevent re-entrance: if already generating, skip
        guard !isGenerating else {
            return nil
        }

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
                isGenerating = true
                defer { isGenerating = false }
                let result = try await generateRollingSummary(
                    sessionId: sessionId,
                    fromSequence: lastSummarizedSequence + 1
                )
                lastSummaryTime[sessionId] = Date()
                return result
            }
            return nil
        } catch {
            isGenerating = false
            // Log error but don't propagate - summarization is non-critical
            logSummary("Rolling summary FAILED: \(error) [\(type(of: error))]")
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

        logSummary("Generating for \(segments.count) segments (from=\(fromSequence))...")

        // Generate summary, notes, and topics using a single detached task with timeout.
        // The Foundation Model can hang indefinitely, so we enforce a hard deadline.
        let summarizer = self.summarizer
        let repository = self.repository
        let lastSummaryContent = try await repository.latestSummary(for: sessionId)?.content

        // Load existing topics from DB — these are immutable once persisted
        let existingTopics = try await repository.topics(for: sessionId)
        logSummary("Found \(existingTopics.count) existing topics")

        // Determine uncovered segments
        let highestCovered = existingTopics.map(\.segmentRange.upperBound).max() ?? 0
        let uncoveredSegments = allSegments.filter { $0.sequenceNumber > highestCovered }

        // Run all LLM calls in a detached task with a hard timeout
        let llmTimeout: TimeInterval = 45
        logSummary("Starting LLM generation (timeout: \(Int(llmTimeout))s)...")

        struct LLMResults: Sendable {
            var briefSummary: String = ""
            var meetingNotes: String = ""
            var newTopics: [Topic] = []
        }

        let results: LLMResults = await {
            let task = Task.detached { () -> LLMResults in
                var r = LLMResults()

                // Brief summary
                do {
                    logSummary("LLM: starting summarize...")
                    r.briefSummary = try await summarizer.summarize(
                        segments: allSegments,
                        previousSummary: lastSummaryContent
                    )
                    logSummary("LLM: summarize done (\(r.briefSummary.count) chars)")
                } catch {
                    logSummary("LLM: summarize failed: \(error)")
                }

                // Meeting notes
                do {
                    logSummary("LLM: starting meeting notes...")
                    r.meetingNotes = try await summarizer.generateMeetingNotes(
                        segments: allSegments,
                        previousNotes: nil
                    )
                    logSummary("LLM: meeting notes done (\(r.meetingNotes.count) chars)")
                } catch {
                    logSummary("LLM: meeting notes failed: \(error)")
                }

                // Topic extraction
                if !uncoveredSegments.isEmpty {
                    do {
                        logSummary("LLM: extracting topics from \(uncoveredSegments.count) segments...")
                        r.newTopics = try await summarizer.extractTopics(
                            segments: uncoveredSegments,
                            previousTopics: existingTopics,
                            sessionId: sessionId
                        )
                        logSummary("LLM: extracted \(r.newTopics.count) topics")
                    } catch {
                        logSummary("LLM: topic extraction failed: \(error)")
                    }
                }

                return r
            }

            // Hard timeout: cancel the detached task after deadline
            let timeoutTask = Task.detached {
                try? await Task.sleep(for: .seconds(llmTimeout))
                task.cancel()
                logSummary("LLM: CANCELLED after \(Int(llmTimeout))s timeout")
            }

            let result = await task.value
            timeoutTask.cancel()
            return result
        }()

        logSummary("LLM generation complete: summary=\(results.briefSummary.count)ch, notes=\(results.meetingNotes.count)ch, topics=\(results.newTopics.count)")

        // Persist new topics
        for topic in results.newTopics {
            try await repository.saveTopic(topic)
        }

        let allTopics = existingTopics + results.newTopics

        let briefSummary = results.briefSummary.isEmpty ? "Processing..." : results.briefSummary

        let summary = Summary(
            sessionId: sessionId,
            content: briefSummary,
            segmentRangeStart: fromSequence,
            segmentRangeEnd: lastSegment.sequenceNumber,
            modelId: "apple-foundation-model"
        )

        try await repository.saveSummary(summary)
        logSummary("Summary saved: \(briefSummary.prefix(50))...")

        let result = SummaryResult(briefSummary: briefSummary, meetingNotes: results.meetingNotes, topics: allTopics)

        // Notify callback if set (for backwards compatibility)
        if let callback = onSummaryGenerated {
            callback(result)
        }

        return result
    }
}
