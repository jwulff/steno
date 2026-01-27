import Foundation
import Observation

/// Error types specific to the TranscriptionViewModel.
public enum TranscriptionViewModelError: Error, Equatable {
    case permissionDenied(String)
    case speechError(String)
}

/// ViewModel managing transcription state and coordinating services.
@Observable
@MainActor
public final class TranscriptionViewModel {
    // MARK: - Public State

    /// Whether transcription is currently active.
    public private(set) var isListening = false

    /// Accumulated transcript segments from final results.
    public private(set) var segments: [TranscriptSegment] = []

    /// Partial (in-progress) transcription text.
    public private(set) var partialText = ""

    /// Current error, if any.
    public private(set) var error: TranscriptionViewModelError?

    /// The full transcribed text from all segments.
    public var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    // MARK: - Private

    private let speechService: SpeechRecognitionService
    private let permissionService: PermissionService
    private var transcriptionTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(speechService: SpeechRecognitionService, permissionService: PermissionService) {
        self.speechService = speechService
        self.permissionService = permissionService
    }

    // MARK: - Public Methods

    /// Starts the transcription session.
    public func startListening() async {
        guard !isListening else { return }

        // Check permissions first
        let status = await permissionService.checkPermissions()
        guard status.allGranted else {
            error = .permissionDenied(status.errorMessage ?? "Permissions denied")
            return
        }

        error = nil
        isListening = true

        transcriptionTask = Task { [weak self] in
            await self?.runTranscription()
        }
    }

    /// Stops the current transcription session.
    public func stopListening() async {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        await speechService.stopTranscription()
        isListening = false
    }

    /// Clears the current error state.
    public func clearError() {
        error = nil
    }

    /// Clears all segments and resets state.
    public func clearTranscript() {
        segments.removeAll()
        partialText = ""
    }

    // MARK: - Private Methods

    private func runTranscription() async {
        let stream = speechService.startTranscription(locale: .current)

        do {
            for try await result in stream {
                guard !Task.isCancelled else { break }
                await handleResult(result)
            }
        } catch {
            await handleError(error)
        }

        isListening = false
    }

    private func handleResult(_ result: TranscriptionResult) async {
        if result.isFinal {
            // Create a segment from the final result
            let segment = TranscriptSegment(
                text: result.text,
                timestamp: result.timestamp,
                duration: 0, // Will be calculated from audio timing
                confidence: result.confidence
            )
            segments.append(segment)
            partialText = ""
        } else {
            partialText = result.text
        }
    }

    private func handleError(_ err: Error) async {
        if let speechError = err as? SpeechRecognitionError {
            switch speechError {
            case .notAuthorized:
                error = .permissionDenied("Speech recognition not authorized")
            case .audioInputUnavailable:
                error = .speechError("Audio input unavailable")
            case .recognitionFailed(let message):
                error = .speechError("Recognition failed: \(message)")
            case .localeNotSupported(let locale):
                error = .speechError("Locale not supported: \(locale.identifier)")
            }
        } else {
            error = .speechError(err.localizedDescription)
        }
        isListening = false
    }
}
