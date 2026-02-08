import SwiftTUI

/// Top header showing app name, microphone selector, and AI status.
struct HeaderView: View {
    @ObservedObject var state: ViewState

    var body: some View {
        Group {
            // Title
            HStack {
                Text("Steno")
                    .bold()
                Text("- Speech to Text (SpeechAnalyzer)")
                    .foregroundColor(.gray)
            }

            // Microphone selector
            HStack {
                Text("Mic:")
                    .foregroundColor(.gray)
                Button("[ < ]") {
                    state.selectPreviousDevice()
                }
                Text(truncateName(state.selectedDevice?.name ?? "No devices", max: 30))
                    .foregroundColor(.cyan)
                Button("[ > ]") {
                    state.selectNextDevice()
                }
            }

            // AI status line
            HStack {
                Text("AI:")
                    .foregroundColor(.gray)
                Text(state.settings.summarizationProvider.displayName)
                    .foregroundColor(.magenta)

                if state.settings.summarizationProvider == .anthropic {
                    Text("│")
                        .foregroundColor(.gray)
                    if state.isModelProcessing {
                        Text("⟳")
                            .foregroundColor(.yellow)
                    }
                    Text(formatModelName(state.settings.anthropicModel))
                        .foregroundColor(state.isModelProcessing ? .yellow : .gray)
                    if state.totalTokensUsed > 0 {
                        Text("\(formatTokenCount(state.totalTokensUsed))")
                            .foregroundColor(.cyan)
                    }
                    if state.settings.effectiveAnthropicAPIKey != nil {
                        Text("✓")
                            .foregroundColor(.green)
                    } else {
                        Text("⚠ no key")
                            .foregroundColor(.red)
                    }
                }

                Text("│")
                    .foregroundColor(.gray)
                Button("[ Settings ]") {
                    state.openSettings()
                }
            }
        }
    }

    private func truncateName(_ name: String, max: Int) -> String {
        if name.count <= max {
            return name
        }
        return String(name.prefix(max - 3)) + "..."
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private func formatModelName(_ model: String) -> String {
        let modelLower = model.lowercased()
        let family: String
        if modelLower.contains("haiku") {
            family = "haiku"
        } else if modelLower.contains("sonnet") {
            family = "sonnet"
        } else if modelLower.contains("opus") {
            family = "opus"
        } else {
            return model.split(separator: "-").last.map(String.init) ?? model
        }

        let parts = model.split(separator: "-").map(String.init)
        var major: Int?
        var minor: Int?

        for part in parts {
            guard let num = Int(part), part.count <= 2 else { continue }
            if major == nil {
                major = num
            } else if minor == nil {
                minor = num
                break
            }
        }

        if let maj = major {
            if let min = minor {
                return "\(family)-\(maj).\(min)"
            }
            return "\(family)-\(maj)"
        }

        return family
    }
}
