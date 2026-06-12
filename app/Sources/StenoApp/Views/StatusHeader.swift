import SwiftUI
import StenoCore

/// The top bar: app identity, the status pill, an AI-processing shimmer, and
/// any banners that need the reader's attention (model unavailable, errors).
struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Steno")
                        .font(Theme.appTitle)
                }

                Spacer()

                EngineHealthChip()

                if model.modelProcessing {
                    Label("Thinking", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .transition(.opacity)
                }

                if model.diarization.state == .preparing {
                    Text("Preparing speaker labels…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                StatusPill(
                    status: model.status,
                    pauseExpiresAt: model.pauseExpiresAt,
                    pausedIndefinitely: model.pausedIndefinitely
                )
            }
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 12)
            .background(.bar)

            banners
        }
        .animation(.easeInOut(duration: 0.25), value: model.modelProcessing)
    }

    @ViewBuilder
    private var banners: some View {
        if model.transcription.state == .unavailable {
            Banner(
                icon: "exclamationmark.triangle.fill",
                tint: Theme.recording,
                title: "Transcription unavailable",
                detail: model.transcription.reason ?? "This Mac can't transcribe."
            )
        }
        if let error = model.lastError {
            Banner(
                icon: "exclamationmark.circle.fill",
                tint: Theme.recording,
                title: "Error",
                detail: error
            )
        }
        if model.systemAudioParkedNoDisplay {
            Banner(
                icon: "display",
                tint: Theme.paused,
                title: "System audio paused",
                detail: "Waiting for an external display. Microphone continues."
            )
        }
    }
}

private struct Banner: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
