import Testing
import Foundation
@testable import StenoDaemon

@Suite("Topic Tests")
struct TopicTests {

    private let testSessionId = UUID()

    @Test func creation() {
        let now = Date()
        let topic = Topic(
            sessionId: testSessionId,
            title: "API migration",
            summary: "Moving to v3 endpoints first, then deprecate v1 by April.",
            segmentRange: 1...5,
            createdAt: now
        )

        #expect(topic.sessionId == testSessionId)
        #expect(topic.title == "API migration")
        #expect(topic.summary == "Moving to v3 endpoints first, then deprecate v1 by April.")
        #expect(topic.segmentRange == 1...5)
        #expect(topic.createdAt == now)
    }

    @Test func equality() {
        let id = UUID()
        let now = Date()
        let topic1 = Topic(id: id, sessionId: testSessionId, title: "Budget", summary: "Review Q2.", segmentRange: 1...3, createdAt: now)
        let topic2 = Topic(id: id, sessionId: testSessionId, title: "Budget", summary: "Review Q2.", segmentRange: 1...3, createdAt: now)

        #expect(topic1 == topic2)
    }

    @Test func inequality() {
        let now = Date()
        let topic1 = Topic(sessionId: testSessionId, title: "Budget", summary: "Review Q2.", segmentRange: 1...3, createdAt: now)
        let topic2 = Topic(sessionId: testSessionId, title: "Hiring", summary: "Need 2 engineers.", segmentRange: 4...6, createdAt: now)

        #expect(topic1 != topic2)
    }

    @Test func codableRoundTrip() throws {
        let topic = Topic(
            sessionId: testSessionId,
            title: "Project timeline",
            summary: "Deadline is March 15th with QA buffer.",
            segmentRange: 1...10,
            createdAt: Date()
        )

        let data = try JSONEncoder().encode(topic)
        let decoded = try JSONDecoder().decode(Topic.self, from: data)

        #expect(decoded == topic)
    }

    @Test func identifiable() {
        let topic = Topic(sessionId: testSessionId, title: "Test", summary: "A test topic.", segmentRange: 1...1)
        #expect(topic.id == topic.id)
    }
}
