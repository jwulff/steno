import Foundation
import Darwin

/// Inspects and controls the daemon *process* (as opposed to `DaemonClient`,
/// which talks to it over the socket). Reads the PID file, checks liveness,
/// and can stop/restart the daemon — but only ever signals a PID it can
/// confirm is actually `steno-daemon`, so a reused PID is never killed.
public struct DaemonController: Sendable {
    private let launcher: DaemonLauncher
    private let socketPath: String
    private let pidFilePath: String

    public init(
        socketPath: String = StenoPaths.socketPath,
        pidFilePath: String = StenoPaths.pidFilePath
    ) {
        self.socketPath = socketPath
        self.pidFilePath = pidFilePath
        self.launcher = DaemonLauncher(socketPath: socketPath)
    }

    // MARK: - Inspection

    /// Parse a PID from raw PID-file contents (pure, testable). Takes the first
    /// integer token so trailing metadata is tolerated.
    public static func parsePID(_ contents: String) -> Int? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.split(whereSeparator: { !$0.isNumber }).first.map(String.init)
        return token.flatMap(Int.init)
    }

    public func readPID() -> Int? {
        guard let s = try? String(contentsOfFile: pidFilePath, encoding: .utf8) else { return nil }
        return Self.parsePID(s)
    }

    /// True if a process with this PID exists (owned by us or not).
    public func processAlive(_ pid: Int) -> Bool {
        let r = kill(pid_t(pid), 0)
        return r == 0 || (r == -1 && errno == EPERM)
    }

    /// The executable path backing a PID, via libproc.
    public func executablePath(_ pid: Int) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<Int(n)], as: UTF8.self)
    }

    /// Confirms a PID is the steno-daemon binary — the guard before any signal.
    public func isDaemonProcess(_ pid: Int) -> Bool {
        guard let path = executablePath(pid) else { return false }
        return (path as NSString).lastPathComponent == "steno-daemon"
    }

    public var socketIsAlive: Bool { launcher.socketIsAlive() }

    /// PID iff a confirmed, live steno-daemon process is recorded; else nil.
    public func runningDaemonPID() -> Int? {
        guard let pid = readPID(), processAlive(pid), isDaemonProcess(pid) else { return nil }
        return pid
    }

    // MARK: - Control

    /// Stop the running daemon. Graceful SIGTERM, escalating to SIGKILL if it
    /// doesn't exit within `gracePeriod`. No-op (but still clears a stale
    /// socket) if no confirmed daemon process is found.
    public func stop(gracePeriod: Duration = .seconds(3)) async {
        if let pid = runningDaemonPID() {
            kill(pid_t(pid), SIGTERM)
            let steps = max(1, Int(gracePeriod / .milliseconds(100)))
            for _ in 0..<steps {
                if !processAlive(pid) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if processAlive(pid) { kill(pid_t(pid), SIGKILL) }
        }
        // Clear a stale socket so the next launch binds cleanly.
        if !socketIsAlive {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    /// Stop the daemon, then start a fresh one and wait for its socket.
    public func restart(timeout: TimeInterval = 30) async throws {
        await stop()
        try await launcher.ensureRunning(timeout: timeout)
    }
}
