import ArgumentParser
import Foundation

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install launchd plist for automatic startup"
    )

    @Option(name: .long, help: "Path to the steno-daemon executable")
    var executablePath: String?

    func run() throws {
        let path = executablePath ?? ProcessInfo.processInfo.arguments[0]

        try DaemonPaths.ensureBaseDirectory()
        try LaunchdPlist.install(executablePath: path)

        print("Installed: \(LaunchdPlist.plistPath)")
        print("To start now: launchctl bootstrap gui/\(getuid()) \(LaunchdPlist.plistPath)")
    }
}
