import SwiftTUI

/// Left panel showing navigable topic outline with expandable summaries.
struct TopicPanelView: View {
    @ObservedObject var state: ViewState

    var body: some View {
        VStack(alignment: .leading) {
            // Header
            HStack {
                Text("TOPICS")
                    .foregroundColor(.cyan)
                    .bold()
                if state.isModelProcessing {
                    Text("⟳")
                        .foregroundColor(.yellow)
                }
                Text("(\(state.topics.count))")
                    .foregroundColor(.gray)
            }

            // Topic list
            if state.topics.isEmpty {
                Text("  No topics yet...")
                    .foregroundColor(.gray)
                    .italic()
                Text("  Topics appear as you speak")
                    .foregroundColor(.gray)
            } else {
                let lines = state.visibleTopicLines
                ForEach(0..<lines.count, id: \.self) { i in
                    let line = lines[i]
                    if line.hasPrefix(">") {
                        Text(line)
                            .foregroundColor(.white)
                            .bold()
                    } else if line.hasPrefix("    ") {
                        // Expanded summary text
                        Text(line)
                            .foregroundColor(.cyan)
                    } else {
                        Text(line)
                            .foregroundColor(.gray)
                    }
                }
            }

            // Expanded topic detail (shown below the list when a topic is selected)
            if let expandedId = state.expandedTopicId,
               let topic = state.topics.first(where: { $0.id == expandedId }) {
                Text(String(repeating: "─", count: max(10, state.topicPanelWidth - 2)))
                    .foregroundColor(.gray)
                HStack {
                    Text("▸")
                        .foregroundColor(.cyan)
                    Text(topic.title)
                        .foregroundColor(.cyan)
                        .bold()
                }
            }

            Spacer()
        }
    }
}
