import SwiftUI
import StenoCore

/// The bottom transport: pause/resume as the primary action, live level meters,
/// and quick toggles for a new session and system-audio capture.
struct TransportBar: View {
    @Environment(AppModel.self) private var model

    private var isLive: Bool {
        model.status == .recording || model.status == .recovering
    }
    private var disabled: Bool {
        model.status == .disconnected || model.status == .connecting
    }

    var body: some View {
        HStack(spacing: 14) {
            pauseButton

            Divider().frame(height: 26)

            // Level meters
            VStack(alignment: .leading, spacing: 4) {
                LevelMeter(label: "MIC", level: model.micLevel,
                           tint: Theme.sourceColor(.microphone), active: isLive && !model.paused)
                if model.systemAudioEnabled {
                    LevelMeter(label: "SYS", level: model.sysLevel,
                               tint: Theme.sourceColor(.systemAudio), active: isLive && !model.paused)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer()

            if let device = model.device {
                Label(device, systemImage: "mic")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }

            controlButton(
                "New session", systemImage: "scissors",
                help: "Mark a session boundary (Space)"
            ) { model.demarcate() }
                .disabled(model.paused || disabled)

            controlButton(
                model.systemAudioEnabled ? "System audio on" : "System audio off",
                systemImage: model.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash",
                help: "Toggle system-audio capture",
                tint: model.systemAudioEnabled ? Theme.sourceColor(.systemAudio) : .secondary
            ) { model.toggleSystemAudio() }
                .disabled(model.paused || disabled)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var pauseButton: some View {
        Button {
            model.togglePause()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(model.paused ? "Resume" : "Pause")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .frame(minWidth: 96)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(model.paused ? Theme.accent : Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
            .foregroundStyle(model.paused ? .white : .primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Pause for 30 minutes") { model.pauseTimed() }
            Button("Pause indefinitely") { model.pauseIndefinite() }
            if model.paused { Button("Resume") { model.resume() } }
        }
        .disabled(disabled)
        .help(model.paused ? "Resume recording" : "Pause (right-click for options)")
    }

    private func controlButton(
        _ title: String, systemImage: String, help: String,
        tint: Color = .secondary, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 30)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
