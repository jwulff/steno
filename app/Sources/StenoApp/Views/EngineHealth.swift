import SwiftUI
import StenoCore

/// A compact engine-health chip for the status header. Click to open a popover
/// with process/socket/engine detail and a restart control.
struct EngineHealthChip: View {
    @Environment(AppModel.self) private var model
    @State private var showPopover = false

    var body: some View {
        let health = model.daemonHealth
        let color = Theme.healthColor(health.severity)

        Button { showPopover.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: health.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .symbolEffect(.rotate, options: .repeating,
                                  isActive: health == .restarting || health == .recovering)
                Text(shortTitle(health))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Engine health — click for details and restart")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            EnginePopover()
        }
        .animation(.easeInOut(duration: 0.25), value: health)
    }

    private func shortTitle(_ h: DaemonHealth) -> String {
        switch h {
        case .healthy: return "Healthy"
        case .paused: return "Paused"
        case .recovering: return "Recovering"
        case .error: return "Error"
        case .unreachable: return "Unreachable"
        case .stopped: return "Stopped"
        case .restarting: return "Restarting"
        case .connecting: return "Connecting"
        }
    }
}

/// Detail + control surface for the daemon process.
struct EnginePopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let health = model.daemonHealth
        let color = Theme.healthColor(health.severity)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: health.symbol)
                    .foregroundStyle(color)
                    .font(.system(size: 14, weight: .semibold))
                Text(health.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
            }
            .padding(.bottom, 12)

            VStack(spacing: 7) {
                DetailRow(label: "Process",
                          value: model.daemonProcessRunning
                            ? "running" + (model.daemonPID.map { " · pid \($0)" } ?? "")
                            : "not running",
                          ok: model.daemonProcessRunning)
                DetailRow(label: "Engine", value: engineStatusText, ok: model.status == .recording)
                if let device = model.device, !device.isEmpty {
                    DetailRow(label: "Input", value: device, ok: true, neutral: true)
                }
                if let error = model.lastError {
                    DetailRow(label: "Last error", value: error, ok: false)
                }
            }
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                Button {
                    model.restartDaemon()
                } label: {
                    HStack(spacing: 6) {
                        if model.daemonRestarting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(model.daemonRestarting ? "Restarting…" : "Restart Engine")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.daemonRestarting)

                if model.status == .error {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "lock.shield")
                    }
                    .help("Open Privacy Settings")
                }
            }

            Text("Restarting brings the recorder down and back up. macOS attributes microphone access to whoever launches it — relaunching from Steno can also fix permission prompts.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var engineStatusText: String {
        switch model.status {
        case .recording: return "recording"
        case .idle: return "idle"
        case .paused: return model.pausedIndefinitely ? "paused (manual)" : "paused"
        case .recovering: return "recovering"
        case .starting: return "starting"
        case .stopping: return "stopping"
        case .error: return "error — check permissions"
        case .connecting: return "connecting"
        case .disconnected: return "socket unreachable"
        case .unknown: return "unknown"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var ok: Bool
    var neutral: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(neutral ? .secondary : (ok ? .primary : Theme.recording))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
