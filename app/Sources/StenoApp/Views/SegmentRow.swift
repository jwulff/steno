import Combine
import SwiftUI
import StenoCore

/// One finalized transcript line: a quiet timestamp gutter, an optional speaker
/// pill, and the text. The source is shown as a thin colored rail so mic vs.
/// system audio reads instantly without shouting.
struct SegmentRow: View {
    let entry: TranscriptEntry
    let speakerLabel: String?
    let speakerIndex: Int?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.timeFormatter.string(from: entry.startedAt))
                .font(Theme.mono)
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
                .monospacedDigit()

            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.sourceColor(entry.source))
                .frame(width: 3)
                .opacity(0.65)

            VStack(alignment: .leading, spacing: 3) {
                if let healMarker = entry.healMarker {
                    HealBadge(marker: healMarker)
                }
                if let label = speakerLabel {
                    Text(label)
                        .font(Theme.chip)
                        .foregroundStyle(Theme.speakerColor(speakerIndex ?? 1))
                }
                Text(entry.text)
                    .font(Theme.transcript)
                    .lineSpacing(Theme.transcriptLeading)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// A live, in-progress line — same shape as a segment but dimmed, with a
/// blinking caret to signal it's still being heard.
struct PartialRow: View {
    let source: AudioSource
    let text: String
    @State private var caretOn = true
    private let blinkTimer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(Theme.sourceColor(source))
                .frame(width: 62, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.sourceColor(source))
                .frame(width: 3)
                .opacity(0.35)

            Text(lineWithCaret)
                .font(Theme.transcript)
                .lineSpacing(Theme.transcriptLeading)
                .fixedSize(horizontal: false, vertical: true)
                .onReceive(blinkTimer) { _ in
                    withAnimation(.easeInOut(duration: 0.1)) { caretOn.toggle() }
                }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .transition(.opacity)
    }

    /// The partial text plus a colored, blinking caret, as a single styled run.
    private var lineWithCaret: AttributedString {
        var body = AttributedString(text)
        body.foregroundColor = .secondary
        var caret = AttributedString(caretOn ? " ▌" : "  ")
        caret.foregroundColor = Theme.sourceColor(source)
        body.append(caret)
        return body
    }
}

/// A horizontal rule marking a user-created session boundary.
struct SessionBoundaryRow: View {
    let date: Date
    private static let f: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    var body: some View {
        HStack(spacing: 10) {
            line
            Text("New session · \(Self.f.string(from: date))")
                .font(Theme.chip)
                .foregroundStyle(.tertiary)
                .fixedSize()
            line
        }
        .padding(.vertical, 8)
    }
    private var line: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
    }
}

private struct HealBadge: View {
    let marker: String
    var body: some View {
        Label(healText, systemImage: "bandage")
            .font(Theme.chip)
            .foregroundStyle(Theme.paused)
    }
    private var healText: String {
        // marker like "after_gap:12s"
        if let gap = marker.split(separator: ":").last { return "recovered after \(gap) gap" }
        return "recovered"
    }
}
