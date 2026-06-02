import Foundation

/// Locates and starts `steno-daemon`, mirroring the TUI's lifecycle manager:
/// resolve the binary (co-located → `$STENO_DAEMON_PATH` → `~/.local/bin` →
/// `PATH`), spawn it detached, and wait for the socket to accept connections.
public struct DaemonLauncher: Sendable {
    public enum LaunchError: Error, Sendable {
        case daemonNotFound
        case socketNeverReady
    }

    private let socketPath: String

    public init(socketPath: String = StenoPaths.socketPath) {
        self.socketPath = socketPath
    }

    // MARK: - Path resolution (pure + injectable for tests)

    /// Resolve the daemon binary path from the given inputs. Pure function:
    /// `env` supplies environment, `fileExists` reports whether a candidate
    /// path is an executable file, and `colocatedDir` is the directory holding
    /// the running app's executable (its embedded daemon, if any).
    ///
    /// Priority: co-located → `$STENO_DAEMON_PATH` → `~/.local/bin/steno-daemon`
    /// → each `PATH` entry.
    public static func resolveDaemonPath(
        env: [String: String],
        home: String,
        colocatedDir: String?,
        fileExists: (String) -> Bool
    ) -> String? {
        let binary = "steno-daemon"

        if let dir = colocatedDir {
            let candidate = (dir as NSString).appendingPathComponent(binary)
            if fileExists(candidate) { return candidate }
        }

        if let override = env["STENO_DAEMON_PATH"], fileExists(override) {
            return override
        }

        let localBin = (home as NSString)
            .appendingPathComponent(".local/bin/\(binary)")
        if fileExists(localBin) { return localBin }

        if let path = env["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent(binary)
                if fileExists(candidate) { return candidate }
            }
        }

        return nil
    }

    /// Resolve the daemon path in the live process environment.
    public func resolveDaemonPath() -> String? {
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent().path
        return Self.resolveDaemonPath(
            env: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            colocatedDir: exeDir,
            fileExists: { path in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                return exists && !isDir.boolValue
                    && FileManager.default.isExecutableFile(atPath: path)
            }
        )
    }

    // MARK: - Lifecycle

    /// Ensure the daemon is running and its socket is accepting connections.
    /// Returns quickly if it's already up; otherwise spawns it and waits.
    public func ensureRunning(timeout: TimeInterval = 30) async throws {
        if socketIsAlive() { return }

        guard let daemonPath = resolveDaemonPath() else {
            throw LaunchError.daemonNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonPath)
        process.arguments = ["run"]
        // Detach from the app's controlling terminal/process group so the
        // daemon survives the app quitting (always-on recording).
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Poll the socket until it's ready.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketIsAlive() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw LaunchError.socketNeverReady
    }

    /// True if a stream connection to the socket succeeds right now.
    public func socketIsAlive() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = b }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Foundation.connect(fd, sa, size)
            }
        }
        return result == 0
    }
}
