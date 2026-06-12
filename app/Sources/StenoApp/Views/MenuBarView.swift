import SwiftUI
import StenoCore

/// The menu-bar popover: a glanceable status line and the two actions you reach
/// for most — pause/resume and a new session — plus a way back to the window.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                StatusPill(
                    status: model.status,
                    pauseExpiresAt: model.pauseExpiresAt,
                    pausedIndefinitely: model.pausedIndefinitely
                )
                Spacer()
            }
            .padding(12)

            Divider()

            // Engine health line + restart.
            HStack(spacing: 8) {
                Image(systemName: model.daemonHealth.symbol)
                    .foregroundStyle(Theme.healthColor(model.daemonHealth.severity))
                    .font(.system(size: 12, weight: .semibold))
                Text(model.daemonHealth.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if model.daemonPID != nil {
                    Text("pid \(model.daemonPID!)")
                        .font(Theme.mono)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            VStack(spacing: 2) {
                MenuButton(model.daemonRestarting ? "Restarting…" : "Restart engine",
                           systemImage: "arrow.triangle.2.circlepath") {
                    model.restartDaemon()
                }
                .disabled(model.daemonRestarting)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)

            Divider()

            VStack(spacing: 2) {
                MenuButton(model.paused ? "Resume" : "Pause for 30 min",
                           systemImage: model.paused ? "play.fill" : "pause.fill") {
                    model.togglePause()
                }
                if !model.paused {
                    MenuButton("Pause indefinitely", systemImage: "moon.fill") {
                        model.pauseIndefinite()
                    }
                }
                MenuButton("New session", systemImage: "scissors") {
                    model.demarcate()
                }
                .disabled(model.paused)
            }
            .padding(6)

            Divider()

            VStack(spacing: 2) {
                MenuButton("Open Steno", systemImage: "macwindow") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuButton("Quit Steno", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 248)
    }
}

private struct MenuButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).frame(width: 16)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
