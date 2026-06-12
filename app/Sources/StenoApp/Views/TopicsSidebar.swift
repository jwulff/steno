import SwiftUI
import StenoCore

/// The left rail: topics the daemon extracts as you speak, each expandable to
/// its summary. Quiet by default, informative on demand.
struct TopicsSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TOPICS")
                    .font(Theme.sectionLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.topics.isEmpty {
                    Text("\(model.topics.count)")
                        .font(Theme.chip)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, Theme.pad)
            .padding(.top, Theme.pad)
            .padding(.bottom, 8)

            if model.topics.isEmpty {
                placeholder
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.topics) { topic in
                            TopicRow(
                                topic: topic,
                                isExpanded: expanded.contains(topic.id)
                            ) { toggle(topic.id) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, Theme.pad)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text("Topics appear as you speak.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 8)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

private struct TopicRow: View {
    let topic: Topic
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(topic.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(topic.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 17)
                Text("segments \(topic.rangeStart)–\(topic.rangeEnd)")
                    .font(Theme.mono)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous)
                .fill(isExpanded ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
    }
}
