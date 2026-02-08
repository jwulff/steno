import ArgumentParser
import Foundation

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove launchd plist and stop the daemon"
    )

    func run() throws {
        try LaunchdPlist.uninstall()
        print("Uninstalled: \(LaunchdPlist.label)")
    }
}
