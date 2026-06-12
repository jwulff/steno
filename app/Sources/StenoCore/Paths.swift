import Foundation

/// File-system locations shared with the daemon. Mirrors the daemon's
/// `DaemonPaths` so the app reads/writes the same socket, DB, and PID file.
public enum StenoPaths {
    /// `~/Library/Application Support/Steno/`
    public static var baseDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Steno", isDirectory: true)
    }

    /// `~/Library/Application Support/Steno/steno.sock`
    public static var socketPath: String {
        baseDirectory.appendingPathComponent("steno.sock").path
    }

    /// `~/Library/Application Support/Steno/steno.sqlite`
    public static var databaseURL: URL {
        baseDirectory.appendingPathComponent("steno.sqlite")
    }

    /// `~/Library/Application Support/Steno/steno.pid`
    public static var pidFilePath: String {
        baseDirectory.appendingPathComponent("steno.pid").path
    }
}
