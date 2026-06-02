import SwiftUI
import StenoCore

/// Steno — a native macOS front-end to the steno-daemon.
///
/// A menu-bar resident with a main window. The app owns no capture logic: it
/// connects to the running daemon, streams its events, and renders them. The
/// model is created once and shared across the window and the menu bar.
@main
struct StenoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Steno", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
                .task { model.start() }
        }
        .defaultSize(width: 960, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("New Session") { model.demarcate() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(model.paused)
                Button(model.systemAudioEnabled ? "Turn Off System Audio" : "Turn On System Audio") {
                    model.toggleSystemAudio()
                }
                .keyboardShortcut("l", modifiers: [.command])
                Divider()
            }
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar glyph, reflecting engine state.
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch model.status {
        case .recording: return "waveform"
        case .paused: return "pause.circle"
        case .recovering, .starting: return "waveform.badge.exclamationmark"
        case .error: return "exclamationmark.triangle"
        case .disconnected, .connecting, .unknown, .idle, .stopping: return "waveform.slash"
        }
    }
}
