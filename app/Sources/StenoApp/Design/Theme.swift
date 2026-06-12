import SwiftUI
import StenoCore

/// The app's visual language. One place for color, type, and metrics so the
/// whole surface stays coherent — calm, focused, and unmistakably native.
enum Theme {

    // MARK: - Color

    /// Primary accent — a refined indigo used for chrome, focus, and the
    /// transport's "live" affordances.
    static let accent = Color(red: 0.36, green: 0.40, blue: 0.92)

    /// The recording dot is always the universal red.
    static let recording = Color(red: 0.93, green: 0.27, blue: 0.31)
    static let paused = Color(red: 0.95, green: 0.66, blue: 0.20)
    static let recovering = Color(red: 0.95, green: 0.66, blue: 0.20)
    static let healthy = Color(red: 0.27, green: 0.72, blue: 0.46)
    static let idle = Color.secondary

    /// Color for a daemon-health severity.
    static func healthColor(_ severity: DaemonHealth.Severity) -> Color {
        switch severity {
        case .ok: return healthy
        case .warn: return paused
        case .bad: return recording
        case .neutral: return idle
        }
    }

    /// Distinct, gentle hues per audio source so mic vs. system reads at a glance.
    static func sourceColor(_ source: AudioSource?) -> Color {
        switch source {
        case .microphone: return Color(red: 0.30, green: 0.70, blue: 0.58) // teal
        case .systemAudio: return Color(red: 0.55, green: 0.50, blue: 0.95) // periwinkle
        case nil: return .secondary
        }
    }

    /// A stable, pleasant color for a given speaker label index.
    static func speakerColor(_ index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.36, green: 0.40, blue: 0.92),
            Color(red: 0.30, green: 0.70, blue: 0.58),
            Color(red: 0.90, green: 0.49, blue: 0.30),
            Color(red: 0.78, green: 0.36, blue: 0.66),
            Color(red: 0.36, green: 0.62, blue: 0.86),
            Color(red: 0.60, green: 0.56, blue: 0.30),
        ]
        return palette[((index - 1) % palette.count + palette.count) % palette.count]
    }

    // MARK: - Type

    static let appTitle = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let sectionLabel = Font.system(size: 11, weight: .semibold).width(.expanded)
    static let transcript = Font.system(size: 15, weight: .regular)
    static let transcriptLeading: CGFloat = 5
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let chip = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let statusLabel = Font.system(size: 12, weight: .semibold, design: .rounded)

    // MARK: - Metrics

    static let corner: CGFloat = 12
    static let smallCorner: CGFloat = 7
    static let pad: CGFloat = 16
    static let rowSpacing: CGFloat = 14
}

extension View {
    /// A soft inset card on a material background.
    func stenoCard(_ corner: CGFloat = Theme.corner) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
