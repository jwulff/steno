import Foundation
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

    /// Diarization scheduling / windowing events.
    public static let diarization = Logger(subsystem: "com.steno.daemon", category: "diarization")
}

/// Console mirroring for lifecycle messages that must appear in the same
/// stream the operator is watching (#93).
///
/// `os.Logger` writes to unified logging only. FluidAudio's `AppLogger`
/// mirrors its warnings and errors to stdout in release builds, so a first-run
/// model download appears to the operator as a minute of bare `[WARN]` lines
/// with nothing around them saying what is happening or that retries are
/// expected. Anything meant to frame that noise has to be written to the same
/// place, in a comparable shape.
///
/// Deliberately narrow: this is for a handful of lifecycle transitions, not a
/// general logging path. Everything else stays on `os.Logger`.
public enum DaemonConsole {
    public enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Write one timestamped line to stdout, shaped like the third-party
    /// library lines it sits among so the sequence reads as one narrative.
    public static func log(_ level: Level, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level.rawValue)] [Steno] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
