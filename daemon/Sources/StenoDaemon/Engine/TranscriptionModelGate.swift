import Foundation
import Speech

/// Outcome of preparing the Layer-A (Apple) transcription pipeline for a locale
/// (#62). "Unsupported" and "download failed" are **returned values, not
/// thrown errors**, so the engine degrades to an explicit state instead of
/// crash-looping the recognizer on hardware that can never satisfy it.
public enum TranscriptionGateOutcome: Sendable, Equatable {
    /// Hardware supports `SpeechTranscriber`, the locale is supported, and its
    /// model asset is installed (or was just downloaded).
    case ready
    /// Transcription can't run for `locale` on this machine. The reason is
    /// human-readable and surfaced to the UI.
    case unavailable(reason: String)
}

/// Gate that decides whether on-device transcription can run, and prepares its
/// model assets, before the engine brings up a recognizer (#62 §Layer A).
///
/// Injected into `RecordingEngine` so tests can drive each branch (ready /
/// unavailable / download-failed) without touching real hardware. Production
/// uses `DefaultTranscriptionModelGate`; the engine's default is the permissive
/// `ReadyTranscriptionModelGate` so existing tests stay hermetic.
public protocol TranscriptionModelGate: Sendable {
    /// Check hardware + locale support and ensure the ASR model asset is
    /// installed, downloading it if needed. Long-running on first install.
    /// Never throws — returns `.unavailable` for any blocking condition.
    func prepare(locale: Locale) async -> TranscriptionGateOutcome
}

/// Permissive default: assumes transcription is available without touching the
/// Speech framework. Used as the engine's injection default so the large
/// existing test suite keeps its current (already-mocked-recognizer) behavior.
/// Production injects `DefaultTranscriptionModelGate` instead.
public struct ReadyTranscriptionModelGate: TranscriptionModelGate {
    public init() {}
    public func prepare(locale: Locale) async -> TranscriptionGateOutcome { .ready }
}

/// Real gate backed by the macOS 26 Speech availability + asset-management APIs
/// (#62). Order of checks, cheapest-and-most-permanent first:
///
/// 1. `SpeechTranscriber.isAvailable` — false on devices without a 16-core
///    Neural Engine and in the Simulator. Permanent for the machine.
/// 2. `SpeechTranscriber.supportedLocale(equivalentTo:)` — the locale must map
///    to a supported one.
/// 3. `SpeechTranscriber.installedLocales` — if the model asset isn't installed,
///    request it via `AssetInventory.assetInstallationRequest(supporting:)` and
///    `downloadAndInstall()` (the network step, slow on first run).
public struct DefaultTranscriptionModelGate: TranscriptionModelGate {
    public init() {}

    public func prepare(locale: Locale) async -> TranscriptionGateOutcome {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable(reason:
                "On-device transcription isn't available on this Mac. It requires "
                + "Apple silicon with a 16-core (or larger) Neural Engine.")
        }

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unavailable(reason:
                "The locale \(locale.identifier(.bcp47)) isn't supported for on-device transcription.")
        }

        let installed = await SpeechTranscriber.installedLocales
        let alreadyInstalled = installed.contains {
            $0.identifier(.bcp47) == supported.identifier(.bcp47)
        }

        if !alreadyInstalled {
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) {
                    try await request.downloadAndInstall()
                }
            } catch {
                return .unavailable(reason:
                    "Couldn't download the \(supported.identifier(.bcp47)) speech model: "
                    + "\(error.localizedDescription)")
            }
        }

        return .ready
    }
}
