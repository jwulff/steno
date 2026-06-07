import Foundation
import Testing
@testable import StenoDaemon

@Suite("HealthPulse Tests")
struct HealthPulseTests {
    @Test func coordinatorPassesWithoutRecovery() async {
        let runner = ScriptedHealthPulseRunner(results: [
            HealthPulseRunResult(
                state: .passed,
                expectedText: "Steno health pulse token amber bravo cedar delta",
                observedText: "steno health pulse token amber bravo cedar delta",
                similarity: 1,
                threshold: 0.82,
                message: "passed"
            )
        ])
        let recoverer = RecordingHealthPulseRecoverer()
        let reporter = RecordingHealthPulseReporter()
        let coordinator = HealthPulseCoordinator(
            runner: runner,
            recoverer: recoverer,
            reporter: reporter,
            now: { Date(timeIntervalSince1970: 1_000) },
            logger: { _ in }
        )

        let report = await coordinator.run(trigger: .manual)

        #expect(report.ok)
        #expect(report.attempts.isEmpty)
        #expect(await recoverer.steps.isEmpty)
        #expect(await reporter.reports.count == 1)
    }

    @Test func coordinatorEscalatesCaptureRestartThenPasses() async {
        let runner = ScriptedHealthPulseRunner(results: [
            HealthPulseRunResult(
                state: .failed,
                expectedText: "Steno health pulse token amber bravo cedar delta",
                observedText: "unrelated words",
                similarity: 0.1,
                threshold: 0.82,
                message: "missed token"
            ),
            HealthPulseRunResult(
                state: .passed,
                expectedText: "Steno health pulse token amber bravo cedar delta",
                observedText: "steno health pulse token amber bravo cedar delta",
                similarity: 1,
                threshold: 0.82,
                message: "recovered"
            )
        ])
        let recoverer = RecordingHealthPulseRecoverer()
        let coordinator = HealthPulseCoordinator(
            runner: runner,
            recoverer: recoverer,
            now: { Date(timeIntervalSince1970: 1_000) },
            logger: { _ in }
        )

        let report = await coordinator.run(trigger: .startup)

        #expect(report.ok)
        #expect(report.attempts.map(\.step) == [.restartCaptureSubsystems])
        #expect(await runner.triggers == [.startup, .captureRecovery])
    }

    @Test func coordinatorSurfacesLoudFailureAfterEscalation() async {
        let runner = ScriptedHealthPulseRunner(results: [
            HealthPulseRunResult(state: .failed, expectedText: "token", threshold: 0.82, message: "first failure"),
            HealthPulseRunResult(state: .failed, expectedText: "token", threshold: 0.82, message: "second failure")
        ])
        let recoverer = RecordingHealthPulseRecoverer(failSteps: [.restartDaemon])
        let reporter = RecordingHealthPulseReporter()
        let coordinator = HealthPulseCoordinator(
            runner: runner,
            recoverer: recoverer,
            reporter: reporter,
            now: { Date(timeIntervalSince1970: 1_000) },
            logger: { _ in }
        )

        let report = await coordinator.run(trigger: .defaultInputChanged)

        #expect(!report.ok)
        #expect(report.attempts.map(\.step) == [.restartCaptureSubsystems, .restartDaemon])
        #expect(report.attempts.last?.ok == false)
        #expect(await reporter.reports.last?.ok == false)
    }

    @Test func realAudioFuzzySimilarityAllowsLossyAsr() {
        let score = RealAudioHealthPulseRunner.similarity(
            expected: "Steno health pulse token amber bravo cedar delta",
            observed: "stino health polls token amber bravo cedar deltas"
        )

        #expect(score >= 0.82)
    }

    @Test @MainActor func realAudioRunnerRequiresEveryConfiguredSource() async throws {
        let repo = MockTranscriptRepository()
        let permissions = MockPermissionService()
        let clock = HealthPulseTestClock()
        let phrase = "Steno health pulse token amber bravo cedar delta"
        let sessionId = UUID()
        try await repo.saveSegment(StoredSegment(
            sessionId: sessionId,
            text: phrase,
            startedAt: clock.start,
            endedAt: clock.start.addingTimeInterval(0.5),
            sequenceNumber: 1,
            source: .microphone
        ))

        let missingSystem = RealAudioHealthPulseRunner(
            repository: repo,
            permissionService: permissions,
            timeoutSeconds: 1,
            pollInterval: .milliseconds(1),
            now: { clock.now() },
            nonce: { "amber bravo cedar delta" },
            requiredSources: { [.microphone, .systemAudio] },
            speaker: { _ in },
            sleeper: { _ in }
        )
        let failed = await missingSystem.run(trigger: .manual)

        #expect(failed.state == .failed)
        #expect(failed.message.contains("systemAudio"))

        let passingRepo = MockTranscriptRepository()
        let passingClock = HealthPulseTestClock()
        try await passingRepo.saveSegment(StoredSegment(
            sessionId: sessionId,
            text: phrase,
            startedAt: passingClock.start,
            endedAt: passingClock.start.addingTimeInterval(0.5),
            sequenceNumber: 1,
            source: .microphone
        ))
        try await passingRepo.saveSegment(StoredSegment(
            sessionId: sessionId,
            text: phrase,
            startedAt: passingClock.start,
            endedAt: passingClock.start.addingTimeInterval(0.5),
            sequenceNumber: 2,
            source: .systemAudio
        ))
        let bothSources = RealAudioHealthPulseRunner(
            repository: passingRepo,
            permissionService: permissions,
            timeoutSeconds: 1,
            pollInterval: .milliseconds(1),
            now: { passingClock.now() },
            nonce: { "amber bravo cedar delta" },
            requiredSources: { [.microphone, .systemAudio] },
            speaker: { _ in },
            sleeper: { _ in }
        )
        let passed = await bothSources.run(trigger: .manual)

        #expect(passed.state == .passed)
    }
}

private final class HealthPulseTestClock: @unchecked Sendable {
    let start = Date(timeIntervalSince1970: 1_000)
    private let lock = NSLock()
    private var calls = 0

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if calls <= 3 {
            return start
        }
        return start.addingTimeInterval(2)
    }
}

private actor ScriptedHealthPulseRunner: HealthPulseRunning {
    private var results: [HealthPulseRunResult]
    private(set) var triggers: [HealthPulseTrigger] = []

    init(results: [HealthPulseRunResult]) {
        self.results = results
    }

    func run(trigger: HealthPulseTrigger) async -> HealthPulseRunResult {
        triggers.append(trigger)
        if results.isEmpty {
            return HealthPulseRunResult(state: .failed, expectedText: "token", threshold: 0.82, message: "no scripted result")
        }
        return results.removeFirst()
    }
}

private actor RecordingHealthPulseRecoverer: HealthPulseRecovering {
    private(set) var steps: [HealthPulseRecoveryStep] = []
    private let failSteps: Set<HealthPulseRecoveryStep>

    init(failSteps: Set<HealthPulseRecoveryStep> = []) {
        self.failSteps = failSteps
    }

    func recover(step: HealthPulseRecoveryStep, trigger: HealthPulseTrigger) async -> HealthPulseRecoveryAttempt {
        steps.append(step)
        let ok = !failSteps.contains(step)
        return HealthPulseRecoveryAttempt(step: step, ok: ok, message: ok ? "ok" : "failed")
    }
}

private actor RecordingHealthPulseReporter: HealthPulseReporting {
    private(set) var reports: [HealthPulseReport] = []

    func healthPulseDidFinish(_ report: HealthPulseReport) async {
        reports.append(report)
    }
}
