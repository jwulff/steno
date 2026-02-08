import SwiftTUI

/// Right panel showing live transcript with timestamps and scroll controls.
struct TranscriptPanelView: View {
    @ObservedObject var state: ViewState

    var body: some View {
        VStack(alignment: .leading) {
            // Header with scroll controls
            HStack {
                Text("TRANSCRIPT")
                    .foregroundColor(.cyan)
                    .bold()
                if state.transcriptIsLiveMode {
                    Text("LIVE")
                        .foregroundColor(.green)
                } else {
                    Text("SCROLL")
                        .foregroundColor(.yellow)
                }
                Spacer()
                Button("[↑]") { state.transcriptScrollUp() }
                Button("[↓]") { state.transcriptScrollDown() }
                if !state.transcriptIsLiveMode {
                    Button("[L]") { state.transcriptJumpToLive() }
                }
            }

            if state.entries.isEmpty && state.partialText.isEmpty {
                Text("Starting transcription...")
                    .foregroundColor(.gray)
                    .italic()
            } else {
                let lines = state.visibleDisplayLines
                ForEach(0..<lines.count, id: \.self) { i in
                    Text(lines[i])
                        .foregroundColor(lines[i].hasSuffix(" ▌") ? .yellow : .white)
                }
            }
            Spacer()
        }
    }
}
