import SwiftUI
import StenoCore

/// The main reading surface: finalized segments, live partials at the bottom,
/// auto-scroll that follows the conversation, and a "jump to live" affordance
/// when the reader scrolls back through history.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @State private var following = true
    @State private var lastCount = 0

    private let bottomAnchor = "steno.transcript.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                    if model.entries.isEmpty && model.orderedPartials.isEmpty {
                        emptyState
                    }

                    ForEach(model.entries) { entry in
                        row(for: entry)
                            .id(entry.id)
                    }

                    ForEach(model.orderedPartials, id: \.source) { partial in
                        PartialRow(source: partial.source, text: partial.text)
                    }

                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, Theme.pad + 6)
                .padding(.vertical, Theme.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    jumpToLive(proxy)
                }
            }
            .onChange(of: model.entries.count) { _, newCount in
                if following { scrollToBottom(proxy) }
                lastCount = newCount
            }
            .onChange(of: model.orderedPartials.count) { _, _ in
                if following { scrollToBottom(proxy) }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .sessionBoundary:
            SessionBoundaryRow(date: entry.startedAt)
        case .segment, .partial:
            let label = entry.speakerId.map { model.speakerLabel(for: $0) }
            let index = label.flatMap { Int($0.replacingOccurrences(of: "Speaker ", with: "")) }
            SegmentRow(entry: entry, speakerLabel: label, speakerIndex: index)
        }
    }

    private var emptyState: some View {
        let copy = emptyCopy
        return VStack(spacing: 14) {
            Image(systemName: copy.icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(copy.tint)
            Text(copy.title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(copy.detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if model.status == .error {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var emptyCopy: (icon: String, tint: Color, title: String, detail: String) {
        switch model.status {
        case .connecting, .starting:
            return ("waveform.badge.magnifyingglass", Theme.accent.opacity(0.7),
                    "Connecting", "Starting Steno and connecting to the recorder…")
        case .disconnected:
            return ("waveform.slash", Theme.idle,
                    "Disconnected", "Lost contact with the recorder. Reconnecting…")
        case .error:
            return ("exclamationmark.triangle", Theme.recording,
                    "Recording stopped",
                    "Steno can't capture audio. Grant Microphone and Screen\nRecording access in System Settings, then try again.")
        case .paused:
            return ("pause.circle", Theme.accent.opacity(0.7),
                    "Paused", "Recording is paused. Resume to keep transcribing.")
        default:
            return ("waveform.badge.mic", Theme.accent.opacity(0.7),
                    "Listening",
                    "Speak and your words appear here.\nPress Space to mark a new session, or pause anytime.")
        }
    }

    private func jumpToLive(_ proxy: ScrollViewProxy) -> some View {
        Button {
            following = true
            scrollToBottom(proxy)
        } label: {
            Label("Jump to live", systemImage: "arrow.down.to.line")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Theme.accent, in: Capsule())
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(Theme.pad)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}
