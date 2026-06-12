import SwiftUI
import StenoCore

/// The single glanceable indicator of engine state: a colored dot + label,
/// with a gentle pulse while recording and a live countdown while paused.
struct StatusPill: View {
    let status: EngineStatus
    var pauseExpiresAt: Date?
    var pausedIndefinitely: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            Dot(color: color, pulsing: status == .recording)
            Group {
                if status == .paused {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(pauseText(now: ctx.date))
                    }
                } else {
                    Text(label)
                }
            }
            .font(Theme.statusLabel)
            .foregroundStyle(color)
            .contentTransition(.opacity)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var color: Color {
        switch status {
        case .recording: return Theme.recording
        case .paused: return Theme.accent
        case .recovering, .starting, .stopping: return Theme.recovering
        case .error: return Theme.recording
        case .connecting, .disconnected, .unknown, .idle: return Theme.idle
        }
    }

    private var label: String {
        switch status {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .recovering: return "Reconnecting"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .error: return "Stopped"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .idle: return "Idle"
        case .unknown: return "—"
        }
    }

    private func pauseText(now: Date) -> String {
        if pausedIndefinitely { return "Paused" }
        guard let expires = pauseExpiresAt else { return "Paused" }
        let remaining = max(0, Int(expires.timeIntervalSince(now)))
        let m = remaining / 60, s = remaining % 60
        return String(format: "Paused · %d:%02d", m, s)
    }
}

/// A status dot that softly pulses when live.
private struct Dot: View {
    let color: Color
    let pulsing: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color, lineWidth: 2)
                    .scaleEffect(animate ? 2.2 : 1)
                    .opacity(animate ? 0 : 0.7)
            )
            .onAppear { if pulsing { startPulse() } }
            .onChange(of: pulsing) { _, now in
                if now { startPulse() } else { animate = false }
            }
    }

    private func startPulse() {
        animate = false
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            animate = true
        }
    }
}
