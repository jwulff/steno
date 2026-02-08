import Foundation

/// Standard file system paths for the daemon.
public enum DaemonPaths {
    /// Base directory: ~/Library/Application Support/Steno/
    public static var baseDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("Steno", isDirectory: true)
    }

    /// Database path: ~/Library/Application Support/Steno/steno.sqlite
    public static var databaseURL: URL {
        baseDirectory.appendingPathComponent("steno.sqlite")
    }

    /// Socket path: ~/Library/Application Support/Steno/steno.sock
    public static var socketPath: String {
        baseDirectory.appendingPathComponent("steno.sock").path
    }

    /// PID file path: ~/Library/Application Support/Steno/steno.pid
    public static var pidFilePath: String {
        baseDirectory.appendingPathComponent("steno.pid").path
    }

    /// Ensure the base directory exists.
    public static func ensureBaseDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }
}
