import Foundation
@testable import Steno

/// Mock implementation of SummarizationService for testing.
actor MockSummarizationService: SummarizationService {
    var available = true
    var summaryToReturn = "Mock summary"
    var shouldThrow: SummarizationError?
    private(set) var summarizeCallCount = 0
    private(set) var lastSegments: [StoredSegment]?
    private(set) var lastPreviousSummary: String?

    nonisolated var isAvailable: Bool {
        get async {
            await available
        }
    }

    func summarize(segments: [StoredSegment], previousSummary: String?) async throws -> String {
        summarizeCallCount += 1
        lastSegments = segments
        lastPreviousSummary = previousSummary
        if let error = shouldThrow { throw error }
        return summaryToReturn
    }

    func generateMeetingNotes(segments: [StoredSegment], previousNotes: String?) async throws -> String {
        if let error = shouldThrow { throw error }
        return "Mock meeting notes"
    }

    var topicsToReturn: [Topic] = []
    var extractTopicsShouldThrow: SummarizationError?
    private(set) var extractTopicsCallCount = 0
    private(set) var lastExtractTopicsSegments: [StoredSegment]?
    private(set) var lastExtractTopicsPreviousTopics: [Topic]?

    func extractTopics(segments: [StoredSegment], previousTopics: [Topic], sessionId: UUID) async throws -> [Topic] {
        extractTopicsCallCount += 1
        lastExtractTopicsSegments = segments
        lastExtractTopicsPreviousTopics = previousTopics
        if let error = extractTopicsShouldThrow { throw error }
        if let error = shouldThrow { throw error }
        return topicsToReturn
    }

    func setTopicsToReturn(_ value: [Topic]) {
        topicsToReturn = value
    }

    func setAvailable(_ value: Bool) {
        available = value
    }

    func setSummaryToReturn(_ value: String) {
        summaryToReturn = value
    }

    func setShouldThrow(_ error: SummarizationError?) {
        shouldThrow = error
    }

    func setExtractTopicsShouldThrow(_ error: SummarizationError?) {
        extractTopicsShouldThrow = error
    }
}
