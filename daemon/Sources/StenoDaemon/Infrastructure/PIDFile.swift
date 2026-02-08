import Foundation

/// Manages a PID file for single-instance daemon enforcement.
public struct PIDFile: Sendable {
    public let path: String

    public init(path: String = DaemonPaths.pidFilePath) {
        self.path = path
    }

    /// Acquire the PID file. Returns false if another instance is running.
    public func acquire() throws -> Bool {
        // Check for existing PID file
        if FileManager.default.fileExists(atPath: path) {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
               let existingPID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                // Check if process is still running
                if kill(existingPID, 0) == 0 {
                    return false // Another instance is running
                }
                // Stale PID file — process is gone
            }
        }

        // Write our PID
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    /// Release the PID file.
    public func release() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Check if another daemon instance is running (without acquiring).
    public func isRunning() -> (running: Bool, pid: Int32?) {
        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let existingPID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (false, nil)
        }

        if kill(existingPID, 0) == 0 {
            return (true, existingPID)
        }

        return (false, nil)
    }
}
