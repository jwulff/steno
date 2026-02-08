import AVFoundation
import Foundation

/// Errors from the recording engine.
public enum RecordingEngineError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case permissionDenied(String)
    case audioSourceFailed(String)
    case recognizerFailed(String)
}

/// The core orchestrator for recording, transcription, and summarization.
///
/// Manages audio capture + speech recognition + segment persistence + summary coordination.
/// Fully testable through protocol-driven dependency injection.
public actor RecordingEngine {
    // MARK: - Read-only state

    public private(set) var status: EngineStatus = .idle
    public private(set) var currentSession: Session?
    public private(set) var currentDevice: String?
    public private(set) var isSystemAudioEnabled: Bool = false
    public private(set) var segmentCount: Int = 0

    // MARK: - Dependencies

    private let repository: TranscriptRepository
    private let permissionService: PermissionService
    private let summaryCoordinator: RollingSummaryCoordinator
    private let audioSourceFactory: AudioSourceFactory
    private let speechRecognizerFactory: SpeechRecognizerFactory
    private var delegate: (any RecordingEngineDelegate)?

    // MARK: - Internal state

    private var micRecognizerHandle: (any SpeechRecognizerHandle)?
    private var micStopClosure: (@Sendable () async -> Void)?
    private var systemAudioSource: AudioSource?
    private var sysRecognizerHandle: (any SpeechRecognizerHandle)?
    private var recognizerTask: Task<Void, Never>?
    private var systemRecognizerTask: Task<Void, Never>?
    private var levelThrottleTask: Task<Void, Never>?
    private var currentSequenceNumber: Int = 0
    private var lastLevelEmitTime: Date = .distantPast
    private var pendingMicLevel: Float = 0
    private var pendingSystemLevel: Float = 0

    /// Minimum interval between audio level events (10Hz = 100ms).
    private let levelInterval: TimeInterval = 0.1

    // MARK: - Init

    public init(
        repository: TranscriptRepository,
        permissionService: PermissionService,
        summaryCoordinator: RollingSummaryCoordinator,
        audioSourceFactory: AudioSourceFactory,
        speechRecognizerFactory: SpeechRecognizerFactory,
        delegate: (any RecordingEngineDelegate)? = nil
    ) {
        self.repository = repository
        self.permissionService = permissionService
        self.summaryCoordinator = summaryCoordinator
        self.audioSourceFactory = audioSourceFactory
        self.speechRecognizerFactory = speechRecognizerFactory
        self.delegate = delegate
    }

    // MARK: - Public Commands

    /// Set or replace the delegate.
    public func setDelegate(_ delegate: any RecordingEngineDelegate) {
        self.delegate = delegate
    }

    /// Start recording with the given configuration.
    ///
    /// - Parameters:
    ///   - locale: Locale for speech recognition.
    ///   - device: Optional audio device identifier.
    ///   - systemAudio: Whether to also capture system audio.
    /// - Returns: The created session.
    @discardableResult
    public func start(
        locale: Locale = .current,
        device: String? = nil,
        systemAudio: Bool = false
    ) async throws -> Session {
        guard status == .idle || status == .error else {
            throw RecordingEngineError.alreadyRecording
        }

        await setStatus(.starting)

        // Check permissions
        let permissions = await permissionService.checkPermissions()
        guard permissions.allGranted else {
            await setStatus(.error)
            let message = permissions.errorMessage ?? "Permissions denied"
            await emit(.error(message, isTransient: false))
            throw RecordingEngineError.permissionDenied(message)
        }

        // Create session
        let session: Session
        do {
            session = try await repository.createSession(locale: locale)
        } catch {
            await setStatus(.error)
            await emit(.error("Failed to create session: \(error)", isTransient: false))
            throw error
        }

        currentSession = session
        currentDevice = device
        currentSequenceNumber = 0
        segmentCount = 0

        // Start microphone
        do {
            let (buffers, format, stopMic) = try await audioSourceFactory.makeMicrophoneSource(device: device)
            micStopClosure = stopMic

            let recognizer = try await speechRecognizerFactory.makeRecognizer(locale: locale, format: format)
            micRecognizerHandle = recognizer

            let results = recognizer.transcribe(buffers: buffers)
            recognizerTask = Task { [weak self] in
                do {
                    for try await result in results {
                        await self?.handleRecognizerResult(result)
                    }
                } catch {
                    await self?.handleRecognizerError(error)
                }
            }
        } catch {
            await cleanup()
            await setStatus(.error)
            throw RecordingEngineError.audioSourceFailed(error.localizedDescription)
        }

        // Start system audio if requested
        if systemAudio {
            await startSystemAudio(locale: locale)
        }
        isSystemAudioEnabled = systemAudio

        await setStatus(.recording)
        return session
    }

    /// Stop recording and finalize the session.
    public func stop() async {
        guard status == .recording || status == .starting else { return }

        await setStatus(.stopping)

        // Stop recognizers
        recognizerTask?.cancel()
        recognizerTask = nil
        await micRecognizerHandle?.stop()
        micRecognizerHandle = nil

        // Stop microphone
        await micStopClosure?()
        micStopClosure = nil

        // Stop system audio
        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil
        await sysRecognizerHandle?.stop()
        sysRecognizerHandle = nil
        await systemAudioSource?.stop()
        systemAudioSource = nil

        // Stop level throttling
        levelThrottleTask?.cancel()
        levelThrottleTask = nil

        // End session
        if let session = currentSession {
            try? await repository.endSession(session.id)
        }
        currentSession = nil
        isSystemAudioEnabled = false

        await setStatus(.idle)
    }

    /// List available audio devices.
    public func availableDevices() async -> [AudioDevice] {
        // Placeholder — real implementation queries Core Audio
        []
    }

    // MARK: - Private

    private func setStatus(_ newStatus: EngineStatus) async {
        status = newStatus
        await emit(.statusChanged(newStatus))
    }

    private func emit(_ event: EngineEvent) async {
        await delegate?.engine(self, didEmit: event)
    }

    private func handleRecognizerResult(_ result: RecognizerResult) async {
        guard let session = currentSession else { return }

        if result.isFinal {
            guard !result.text.isEmpty else { return }

            currentSequenceNumber += 1
            segmentCount = currentSequenceNumber

            let segment = StoredSegment(
                sessionId: session.id,
                text: result.text,
                startedAt: result.timestamp,
                endedAt: Date(),
                confidence: result.confidence,
                sequenceNumber: currentSequenceNumber,
                source: result.source
            )

            // Persist
            do {
                try await repository.saveSegment(segment)
            } catch {
                await emit(.error("Failed to save segment: \(error)", isTransient: true))
                return
            }

            await emit(.segmentFinalized(segment))

            // Trigger summary
            await emit(.modelProcessing(true))
            let summaryResult = await summaryCoordinator.onSegmentSaved(sessionId: session.id)
            await emit(.modelProcessing(false))

            if let summaryResult {
                await emit(.topicsUpdated(summaryResult.topics))
            }
        } else {
            await emit(.partialText(result.text, result.source))
        }
    }

    private func handleRecognizerError(_ error: Error) async {
        let message = error.localizedDescription
        let isCancellation = message.lowercased().contains("cancel")
        if !isCancellation {
            await emit(.error(message, isTransient: true))
        }
    }

    private func startSystemAudio(locale: Locale) async {
        let source = audioSourceFactory.makeSystemAudioSource()
        systemAudioSource = source

        do {
            let (buffers, format) = try await source.start()
            let recognizer = try await speechRecognizerFactory.makeRecognizer(locale: locale, format: format)
            sysRecognizerHandle = recognizer

            let results = recognizer.transcribe(buffers: buffers)
            systemRecognizerTask = Task { [weak self] in
                do {
                    for try await result in results {
                        await self?.handleRecognizerResult(result)
                    }
                } catch {
                    await self?.handleRecognizerError(error)
                }
            }
        } catch {
            await emit(.error("System audio failed: \(error)", isTransient: true))
        }
    }

    private func cleanup() async {
        recognizerTask?.cancel()
        recognizerTask = nil
        await micRecognizerHandle?.stop()
        micRecognizerHandle = nil
        await micStopClosure?()
        micStopClosure = nil
        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil
        await sysRecognizerHandle?.stop()
        sysRecognizerHandle = nil
        await systemAudioSource?.stop()
        systemAudioSource = nil
        levelThrottleTask?.cancel()
        levelThrottleTask = nil
        currentSession = nil
    }
}
