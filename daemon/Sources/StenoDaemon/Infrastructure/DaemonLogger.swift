import os

/// Logging categories for the daemon.
public enum DaemonLogger {
    /// General daemon lifecycle events.
    public static let daemon = Logger(subsystem: "com.steno.daemon", category: "daemon")

    /// Recording engine events.
    public static let engine = Logger(subsystem: "com.steno.daemon", category: "engine")

    /// Socket server events.
    public static let socket = Logger(subsystem: "com.steno.daemon", category: "socket")

    /// Summarization events.
    public static let summary = Logger(subsystem: "com.steno.daemon", category: "summary")
}
