import SwiftUI
import StenoCore

/// A compact, smoothly-animated audio level meter — a labeled row of bars that
/// fill with the source's level and tint toward warning as they peak.
struct LevelMeter: View {
    let label: String
    let level: Double          // 0...1
    let tint: Color
    var active: Bool = true

    private let segments = 12

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.chip)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)

            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    let threshold = Double(i) / Double(segments)
                    let on = active && level > threshold
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(on ? barColor(threshold) : Color.primary.opacity(0.08))
                        .frame(width: 4, height: 12)
                }
            }
            .animation(.easeOut(duration: 0.12), value: level)
            .animation(.easeOut(duration: 0.2), value: active)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func barColor(_ threshold: Double) -> Color {
        if threshold > 0.85 { return Theme.recording }
        if threshold > 0.6 { return Theme.paused }
        return tint
    }
}
