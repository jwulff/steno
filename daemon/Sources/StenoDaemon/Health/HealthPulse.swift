import Foundation

/// End-to-end audio health triggers. The on-demand trigger is always available;
/// automatic triggers are debounced by `HealthPulseCoordinator` so noisy device
/// notifications collapse to one real speaker→air→mic pulse.
public enum HealthPulseTrigger: String, Codable, Sendable, CaseIterable, Hashable {
    case manual
    case startup
    case defaultInputChanged
    case defaultOutputChanged
    case wakeFromSleep
    case captureRecovery
    case permissionStateChanged
}

/// Escalating recovery steps applied after a failed real-audio pulse.
public enum HealthPulseRecoveryStep: String, Codable, Sendable, CaseIterable, Hashable {
    /// Rebuild the in-process capture/transcription graph first: mic tap,
    /// SCStream/system-audio capture when enabled, and SpeechAnalyzer sessions.
    case restartCaptureSubsystems
    /// Last resort: ask the supervising launch path to restart the daemon.
    case restartDaemon
}

public enum HealthPulseRunState: String, Codable, Sendable, Hashable {
    case passed
    case failed
    case cannotRun
}

/// Result of a single real-audio attempt, before any escalation is applied.
public struct HealthPulseRunResult: Codable, Sendable, Equatable {
    public var state: HealthPulseRunState
    public var expectedText: String
    public var observedText: String?
    public var similarity: Double?
    public var threshold: Double
    public var message: String

    public init(
        state: HealthPulseRunState,
        expectedText: String,
        observedText: String? = nil,
        similarity: Double? = nil,
        threshold: Double,
        message: String
    ) {
        self.state = state
        self.expectedText = expectedText
        self.observedText = observedText
        self.similarity = similarity
        self.threshold = threshold
        self.message = message
    }
}

public struct HealthPulseRecoveryAttempt: Codable, Sendable, Equatable {
    public var step: HealthPulseRecoveryStep
    public var ok: Bool
    public var message: String

    public init(step: HealthPulseRecoveryStep, ok: Bool, message: String) {
        self.step = step
        self.ok = ok
        self.message = message
    }
}

/// Queryable final state for a health pulse. This is returned over the socket,
/// logged as JSON, and surfaced as a TUI/MCP-visible health event.
public struct HealthPulseReport: Codable, Sendable, Equatable {
    public var ok: Bool
    public var trigger: HealthPulseTrigger
    public var startedAt: Date
    public var endedAt: Date
    public var finalState: HealthPulseRunState
    public var expectedText: String
    public var observedText: String?
    public var similarity: Double?
    public var threshold: Double
    public var attempts: [HealthPulseRecoveryAttempt]
    public var message: String

    public init(
        ok: Bool,
        trigger: HealthPulseTrigger,
        startedAt: Date,
        endedAt: Date,
        finalState: HealthPulseRunState,
        expectedText: String,
        observedText: String? = nil,
        similarity: Double? = nil,
        threshold: Double,
        attempts: [HealthPulseRecoveryAttempt] = [],
        message: String
    ) {
        self.ok = ok
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.finalState = finalState
        self.expectedText = expectedText
        self.observedText = observedText
        self.similarity = similarity
        self.threshold = threshold
        self.attempts = attempts
        self.message = message
    }
}

public protocol HealthPulseRunning: Sendable {
    func run(trigger: HealthPulseTrigger) async -> HealthPulseRunResult
}

public protocol HealthPulseRecovering: Sendable {
    func recover(step: HealthPulseRecoveryStep, trigger: HealthPulseTrigger) async -> HealthPulseRecoveryAttempt
}

public protocol HealthPulseReporting: Sendable {
    func healthPulseDidFinish(_ report: HealthPulseReport) async
}

/// Coordinates one real-audio pulse plus the escalation ladder from issue #76.
/// It deliberately owns no audio mocks: tests inject a runner, while production
/// uses `RealAudioHealthPulseRunner` to play TTS through the default output and
/// poll persisted transcript segments for the nonce.
public actor HealthPulseCoordinator {
    private let runner: any HealthPulseRunning
    private let recoverer: any HealthPulseRecovering
    private let reporter: (any HealthPulseReporting)?
    private let now: @Sendable () -> Date
    private let debounce: Duration
    private let logger: @Sendable (String) -> Void
    private var scheduled: Task<Void, Never>?
    private var running = false
    private var lastReport: HealthPulseReport?

    public init(
        runner: any HealthPulseRunning,
        recoverer: any HealthPulseRecovering,
        reporter: (any HealthPulseReporting)? = nil,
        debounce: Duration = .seconds(3),
        now: @Sendable @escaping () -> Date = { Date() },
        logger: @Sendable @escaping (String) -> Void = { print($0) }
    ) {
        self.runner = runner
        self.recoverer = recoverer
        self.reporter = reporter
        self.debounce = debounce
        self.now = now
        self.logger = logger
    }

    public func latestReport() -> HealthPulseReport? {
        lastReport
    }

    public func schedule(trigger: HealthPulseTrigger) {
        let delay = debounce
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.run(trigger: trigger)
        }
    }

    @discardableResult
    public func run(trigger: HealthPulseTrigger) async -> HealthPulseReport {
        if running, let lastReport {
            return lastReport
        }
        running = true
        defer { running = false }

        let started = now()
        var recoveryAttempts: [HealthPulseRecoveryAttempt] = []
        var result = await runner.run(trigger: trigger)

        if result.state == .failed {
            for step in HealthPulseRecoveryStep.allCases {
                let attempt = await recoverer.recover(step: step, trigger: trigger)
                recoveryAttempts.append(attempt)
                if !attempt.ok { continue }

                result = await runner.run(trigger: .captureRecovery)
                if result.state != .failed { break }
            }
        }

        let report = HealthPulseReport(
            ok: result.state == .passed,
            trigger: trigger,
            startedAt: started,
            endedAt: now(),
            finalState: result.state,
            expectedText: result.expectedText,
            observedText: result.observedText,
            similarity: result.similarity,
            threshold: result.threshold,
            attempts: recoveryAttempts,
            message: result.message
        )
        lastReport = report
        log(report)
        await reporter?.healthPulseDidFinish(report)
        return report
    }

    private func log(_ report: HealthPulseReport) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report),
              let json = String(data: data, encoding: .utf8) else {
            logger("STENO_HEALTH_PULSE_LOG encode_failed ok=\(report.ok) trigger=\(report.trigger.rawValue)")
            return
        }
        logger("STENO_HEALTH_PULSE_LOG \(json)")
    }
}

/// Small wiring relay used during daemon boot: `RecordingEngine` needs a trigger
/// sink before the coordinator can be built (the coordinator's recovery path
/// itself needs the engine). The relay breaks that construction cycle and gates
/// automatic pulses behind settings.
public actor HealthPulseTriggerRelay {
    private var coordinator: HealthPulseCoordinator?
    private let automaticEnabled: Bool

    public init(automaticEnabled: Bool) {
        self.automaticEnabled = automaticEnabled
    }

    public func setCoordinator(_ coordinator: HealthPulseCoordinator) {
        self.coordinator = coordinator
    }

    public func schedule(_ trigger: HealthPulseTrigger) async {
        guard automaticEnabled else { return }
        await coordinator?.schedule(trigger: trigger)
    }
}
