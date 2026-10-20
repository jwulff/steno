import Testing
import Foundation
@testable import StenoCore

struct DaemonControlTests {

    // MARK: - PID parsing

    @Test func parsesPlainPID() {
        #expect(DaemonController.parsePID("12345") == 12345)
    }

    @Test func parsesPIDWithTrailingNewline() {
        #expect(DaemonController.parsePID("12345\n") == 12345)
    }

    @Test func parsesFirstIntegerToken() {
        #expect(DaemonController.parsePID("12345 steno-daemon") == 12345)
    }

    @Test func returnsNilForNonNumeric() {
        #expect(DaemonController.parsePID("not-a-pid") == nil)
        #expect(DaemonController.parsePID("") == nil)
    }
}

@MainActor
struct DaemonHealthTests {
    typealias Health = DaemonHealth

    @Test func recordingIsHealthy() {
        #expect(AppModel.daemonHealth(status: .recording, processRunning: true, restarting: false) == .healthy)
    }

    /// #111 — `.idle` on an always-on daemon (#32) means capture is off
    /// and nobody asked for it: there is no user-facing stop, and the
    /// engine never leaves `.idle` on its own. Reporting that as
    /// `.healthy` is exactly what let a stopped daemon sit unnoticed.
    /// `.paused` is the state that legitimately means "not capturing, on
    /// purpose", and it already has its own case.
    @Test func idleIsNotHealthyOnAnAlwaysOnDaemon() {
        let health = AppModel.daemonHealth(
            status: .idle, processRunning: true, restarting: false
        )
        #expect(health != .healthy)
        #expect(health == .notCapturing)
        #expect(health.severity == .warn)
    }

    @Test func pausedIsPaused() {
        #expect(AppModel.daemonHealth(status: .paused, processRunning: true, restarting: false) == .paused)
    }

    @Test func engineErrorSurfaces() {
        #expect(AppModel.daemonHealth(status: .error, processRunning: true, restarting: false) == .error)
    }

    @Test func disconnectedWithProcessIsUnreachable() {
        #expect(AppModel.daemonHealth(status: .disconnected, processRunning: true, restarting: false) == .unreachable)
    }

    @Test func disconnectedWithoutProcessIsStopped() {
        #expect(AppModel.daemonHealth(status: .disconnected, processRunning: false, restarting: false) == .stopped)
    }

    @Test func restartingWinsOverEverything() {
        #expect(AppModel.daemonHealth(status: .recording, processRunning: true, restarting: true) == .restarting)
        #expect(AppModel.daemonHealth(status: .error, processRunning: false, restarting: true) == .restarting)
    }

    @Test func severityMapping() {
        #expect(Health.healthy.severity == .ok)
        #expect(Health.error.severity == .bad)
        #expect(Health.stopped.severity == .bad)
        #expect(Health.recovering.severity == .warn)
    }
}
