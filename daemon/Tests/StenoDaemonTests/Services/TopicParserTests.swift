import Testing
import Foundation
@testable import StenoDaemon

@Suite("TopicParser Tests")
struct TopicParserTests {

    private let testSessionId = UUID()

    @Test func validJSON() {
        let json = """
        [
            {"title": "Project timeline", "summary": "Deadline is March 15th.", "startSegment": 1, "endSegment": 5},
            {"title": "Budget review", "summary": "Q2 budget approved.", "startSegment": 6, "endSegment": 10}
        ]
        """

        let topics = TopicParser.parse(json, sessionId: testSessionId)

        #expect(topics.count == 2)
        #expect(topics[0].title == "Project timeline")
        #expect(topics[0].summary == "Deadline is March 15th.")
        #expect(topics[0].segmentRange == 1...5)
        #expect(topics[0].sessionId == testSessionId)
        #expect(topics[1].title == "Budget review")
        #expect(topics[1].segmentRange == 6...10)
        #expect(topics[1].sessionId == testSessionId)
    }

    @Test func jsonWithCodeFences() {
        let json = """
        ```json
        [
            {"title": "API migration", "summary": "Moving to v3.", "startSegment": 1, "endSegment": 3}
        ]
        ```
        """

        let topics = TopicParser.parse(json, sessionId: testSessionId)

        #expect(topics.count == 1)
        #expect(topics[0].title == "API migration")
    }

    @Test func codeFencesWithoutLanguage() {
        let json = """
        ```
        [
            {"title": "Hiring update", "summary": "Need 2 engineers.", "startSegment": 1, "endSegment": 2}
        ]
        ```
        """

        let topics = TopicParser.parse(json, sessionId: testSessionId)

        #expect(topics.count == 1)
        #expect(topics[0].title == "Hiring update")
    }

    @Test func malformedJSONReturnsEmpty() {
        let json = "this is not json at all"

        let topics = TopicParser.parse(json, sessionId: testSessionId)

        #expect(topics.isEmpty)
    }

    @Test func emptyStringReturnsEmpty() {
        let topics = TopicParser.parse("", sessionId: testSessionId)

        #expect(topics.isEmpty)
    }

    @Test func emptyArrayReturnsEmpty() {
        let topics = TopicParser.parse("[]", sessionId: testSessionId)

        #expect(topics.isEmpty)
    }

    @Test func invalidSegmentRangeSkipped() {
        let json = """
        [
            {"title": "Valid", "summary": "OK.", "startSegment": 1, "endSegment": 3},
            {"title": "Invalid", "summary": "Bad range.", "startSegment": 5, "endSegment": 2}
        ]
        """

        let topics = TopicParser.parse(json, sessionId: testSessionId)

        #expect(topics.count == 1)
        #expect(topics[0].title == "Valid")
    }

    @Test func stripCodeFencesPreservesContent() {
        let input = """
        ```json
        [{"key": "value"}]
        ```
        """

        let result = TopicParser.stripCodeFences(input)

        #expect(result == "[{\"key\": \"value\"}]")
    }

    @Test func stripCodeFencesNoFences() {
        let input = "[{\"key\": \"value\"}]"

        let result = TopicParser.stripCodeFences(input)

        #expect(result == input)
    }
}
