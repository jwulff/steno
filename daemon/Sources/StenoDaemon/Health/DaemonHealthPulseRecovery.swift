import Foundation

public struct DaemonHealthPulseRecovery: HealthPulseRecovering {
    private let engine: RecordingEngine
    private let daemonRestarter: @Sendable () async throws -> Void

    public init(
        engine: RecordingEngine,
        daemonRestarter: @Sendable @escaping () async throws -> Void = DaemonHealthPulseRecovery.defaultDaemonRestart
    ) {
        self.engine = engine
        self.daemonRestarter = daemonRestarter
    }

    public func recover(step: HealthPulseRecoveryStep, trigger: HealthPulseTrigger) async -> HealthPulseRecoveryAttempt {
        do {
            switch step {
            case .restartCaptureSubsystems:
                try await engine.restartCaptureForHealthPulse(reason: "health-pulse:\(trigger.rawValue)")
            case .restartDaemon:
                try await daemonRestarter()
            }
            return HealthPulseRecoveryAttempt(step: step, ok: true, message: "\(step.rawValue) completed")
        } catch {
            return HealthPulseRecoveryAttempt(step: step, ok: false, message: error.localizedDescription)
        }
    }

    /// Conservative default: emit a clear failure instead of unexpectedly
    /// killing the daemon from inside a socket command. Launchd/full restart can
    /// be wired by a future supervisor without changing the coordinator tests.
    public static func defaultDaemonRestart() async throws {
        throw NSError(
            domain: "StenoHealthPulse",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Full daemon restart requires launchd/supervisor handoff; leaving loud failure surfaced"]
        )
    }
}
