import Foundation

/// Generates and manages launchd plist for the daemon.
public enum LaunchdPlist {
    public static let label = "com.steno.daemon"

    public static var plistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    /// Generate plist XML for the daemon.
    public static func generate(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardOutPath</key>
            <string>\(DaemonPaths.baseDirectory.appendingPathComponent("daemon.log").path)</string>
            <key>StandardErrorPath</key>
            <string>\(DaemonPaths.baseDirectory.appendingPathComponent("daemon.log").path)</string>
        </dict>
        </plist>
        """
    }

    /// Install the plist to ~/Library/LaunchAgents/.
    public static func install(executablePath: String) throws {
        let plist = generate(executablePath: executablePath)
        let dir = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    }

    /// Uninstall: bootout the service and remove the plist.
    public static func uninstall() throws {
        // Bootout the service (ignore errors if not loaded)
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(uid)/\(label)"]
        try? process.run()
        process.waitUntilExit()

        // Remove plist file
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }
}
