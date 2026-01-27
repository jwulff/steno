import SwiftTUI

/// State container for the view, safe for SwiftTUI.
struct TranscriptionState {
    var isListening: Bool = false
    var segments: [TranscriptSegment] = []
    var partialText: String = ""
    var errorMessage: String? = nil

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }
}

/// Main TUI view for the Steno application.
struct MainView: View {
    @State var state = TranscriptionState()

    var body: some View {
        VStack(alignment: .leading) {
            // Header
            headerView

            // Status line
            statusView

            // Divider
            Text(String(repeating: "─", count: 60))
                .foregroundColor(.gray)

            // Transcript display
            transcriptView

            // Partial text (in-progress)
            if !state.partialText.isEmpty {
                Text(state.partialText)
                    .foregroundColor(.yellow)
                    .italic()
            }

            // Error display
            if let errorMessage = state.errorMessage {
                errorView(errorMessage)
            }

            // Footer with controls
            Spacer()
            controlsView
        }
        .padding(1)
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text("Steno")
                .bold()
            Text("- Speech to Text")
                .foregroundColor(.gray)
        }
    }

    private var statusView: some View {
        HStack {
            if state.isListening {
                Text("●")
                    .foregroundColor(.red)
                Text("Recording...")
                    .foregroundColor(.green)
            } else {
                Text("○")
                    .foregroundColor(.gray)
                Text("Ready")
                    .foregroundColor(.gray)
            }
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading) {
            if state.segments.isEmpty && state.partialText.isEmpty {
                Text("Start speaking to see transcription...")
                    .foregroundColor(.gray)
                    .italic()
            } else {
                Text(state.fullText)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack {
            Text("Error:")
                .foregroundColor(.red)
                .bold()
            Text(message)
                .foregroundColor(.red)
        }
    }

    private var controlsView: some View {
        HStack {
            Text("[Space]")
                .foregroundColor(.cyan)
            Text(state.isListening ? "Stop" : "Start")

            Text(" | ")
                .foregroundColor(.gray)

            Text("[c]")
                .foregroundColor(.cyan)
            Text("Clear")

            Text(" | ")
                .foregroundColor(.gray)

            Text("[q]")
                .foregroundColor(.cyan)
            Text("Quit")
        }
    }
}
