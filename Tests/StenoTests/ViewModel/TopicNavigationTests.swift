import Testing
import Foundation
@testable import Steno

@Suite("Topic Navigation Tests")
struct TopicNavigationTests {

    private func makeViewState(topicCount: Int = 3) -> ViewState {
        let state = ViewState(forTesting: true)
        state.topics = (0..<topicCount).map { i in
            Topic(
                title: "Topic \(i + 1)",
                summary: "Summary for topic \(i + 1).",
                segmentRange: (i * 3 + 1)...(i * 3 + 3)
            )
        }
        return state
    }

    @Test func moveDownIncrementsIndex() {
        let state = makeViewState()

        state.topicMoveDown()

        #expect(state.selectedTopicIndex == 1)
    }

    @Test func moveUpDecrementsIndex() {
        let state = makeViewState()
        state.selectedTopicIndex = 2

        state.topicMoveUp()

        #expect(state.selectedTopicIndex == 1)
    }

    @Test func moveUpClampsAtZero() {
        let state = makeViewState()
        state.selectedTopicIndex = 0

        state.topicMoveUp()

        #expect(state.selectedTopicIndex == 0)
    }

    @Test func moveDownClampsAtEnd() {
        let state = makeViewState()
        state.selectedTopicIndex = 2

        state.topicMoveDown()

        #expect(state.selectedTopicIndex == 2)
    }

    @Test func toggleExpansion() {
        let state = makeViewState()
        let topicId = state.topics[0].id

        state.toggleTopicExpansion()

        #expect(state.expandedTopicId == topicId)
    }

    @Test func toggleCollapse() {
        let state = makeViewState()
        let topicId = state.topics[0].id
        state.expandedTopicId = topicId

        state.toggleTopicExpansion()

        #expect(state.expandedTopicId == nil)
    }

    @Test func expandDifferentTopic() {
        let state = makeViewState()
        state.expandedTopicId = state.topics[0].id
        state.selectedTopicIndex = 1

        state.toggleTopicExpansion()

        #expect(state.expandedTopicId == state.topics[1].id)
    }

    @Test func emptyTopicsHandledGracefully() {
        let state = ViewState(forTesting: true)
        state.topics = []

        state.topicMoveUp()
        state.topicMoveDown()
        state.toggleTopicExpansion()

        #expect(state.selectedTopicIndex == 0)
        #expect(state.expandedTopicId == nil)
    }

    @Test func panelFocusToggle() {
        let state = ViewState(forTesting: true)

        #expect(state.focusedPanel == .topics)

        state.togglePanelFocus()
        #expect(state.focusedPanel == .transcript)

        state.togglePanelFocus()
        #expect(state.focusedPanel == .topics)
    }

    @Test func displayTopicLinesEmpty() {
        let state = ViewState(forTesting: true)
        state.topics = []

        let lines = state.displayTopicLines

        #expect(lines.count == 2)
        #expect(lines[0].contains("No topics"))
    }

    @Test func displayTopicLinesWithTopics() {
        let state = makeViewState()

        let lines = state.displayTopicLines

        #expect(lines.count == 3)
        #expect(lines[0].contains(">"))
        #expect(lines[0].contains("Topic 1"))
        #expect(lines[1].contains("Topic 2"))
        #expect(!lines[1].contains(">"))
    }

    @Test func displayTopicLinesExpanded() {
        let state = makeViewState()
        state.expandedTopicId = state.topics[0].id

        let lines = state.displayTopicLines

        // First topic title + summary lines + 2 more topics
        #expect(lines.count > 3)
        // Summary text appears in the lines after the first topic title
        let summaryLines = lines.dropFirst().prefix(while: { $0.hasPrefix("    ") })
        let fullSummary = summaryLines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        #expect(fullSummary.contains("Summary for topic 1"))
    }

    @Test func handleSummaryResultUpdatesTopics() {
        let state = ViewState(forTesting: true)
        let topics = [
            Topic(title: "Budget", summary: "Q2 approved.", segmentRange: 1...3),
        ]
        let result = SummaryResult(briefSummary: "Brief", meetingNotes: "Notes", topics: topics)

        state.handleSummaryResult(result)

        #expect(state.topics.count == 1)
        #expect(state.topics[0].title == "Budget")
    }

    @Test func handleSummaryResultPreservesTopicsOnEmpty() {
        let state = ViewState(forTesting: true)
        state.topics = [Topic(title: "Existing", summary: "Keep.", segmentRange: 1...2)]
        let result = SummaryResult(briefSummary: "Brief", meetingNotes: "Notes", topics: [])

        state.handleSummaryResult(result)

        #expect(state.topics.count == 1)
        #expect(state.topics[0].title == "Existing")
    }
}
