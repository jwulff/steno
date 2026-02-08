import SwiftTUI

/// Status line showing recording state, audio sources, and level meters.
struct StatusBarView: View {
    @ObservedObject var state: ViewState

    var body: some View {
        HStack {
            if state.isListening {
                Text("●")
                    .foregroundColor(.red)
            } else if state.isDownloadingModel {
                Text("↓")
                    .foregroundColor(.yellow)
            } else {
                Text("○")
                    .foregroundColor(.gray)
            }
            Text(state.statusMessage)
                .foregroundColor(state.isListening ? .green : (state.isDownloadingModel ? .yellow : .gray))

            if state.isListening && state.isSystemAudioEnabled {
                Text("MIC + SYS")
                    .foregroundColor(.cyan)
            } else if state.isListening {
                Text("MIC")
                    .foregroundColor(.gray)
            }

            if state.isListening {
                Text(" MIC")
                    .foregroundColor(.gray)
                let levelBars = min(20, Int(state.audioLevel * 100))
                Text(String(repeating: "█", count: levelBars) + String(repeating: "░", count: 20 - levelBars))
                    .foregroundColor(levelBars > 10 ? .green : (levelBars > 5 ? .yellow : .gray))

                if state.isSystemAudioEnabled {
                    Text(" SYS")
                        .foregroundColor(.gray)
                    let sysLevel = min(20, Int(state.systemAudioLevel * 100))
                    Text(String(repeating: "█", count: sysLevel) + String(repeating: "░", count: 20 - sysLevel))
                        .foregroundColor(sysLevel > 10 ? .green : (sysLevel > 5 ? .yellow : .gray))
                }
            }
        }
    }
}
