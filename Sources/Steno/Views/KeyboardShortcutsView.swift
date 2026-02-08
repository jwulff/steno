import SwiftTUI

/// Footer bar showing available keyboard shortcuts.
struct KeyboardShortcutsView: View {
    @ObservedObject var state: ViewState

    var body: some View {
        HStack {
            Group {
                Text("[Space]")
                    .foregroundColor(.cyan)
                Text(state.isListening ? "stop" : "start")
                    .foregroundColor(.gray)
                Text("[a]")
                    .foregroundColor(.cyan)
                Text(state.isSystemAudioEnabled ? "sys off" : "sys on")
                    .foregroundColor(.gray)
                Text("[j/k]")
                    .foregroundColor(.cyan)
                Text("topics")
                    .foregroundColor(.gray)
            }
            Group {
                Text("[Enter]")
                    .foregroundColor(.cyan)
                Text("expand")
                    .foregroundColor(.gray)
                Text("[Tab]")
                    .foregroundColor(.cyan)
                Text("focus")
                    .foregroundColor(.gray)
                Text("[q]")
                    .foregroundColor(.cyan)
                Text("quit")
                    .foregroundColor(.gray)
            }
        }
    }
}
