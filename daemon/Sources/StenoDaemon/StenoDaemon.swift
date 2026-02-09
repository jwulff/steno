import ArgumentParser
import Foundation

@main
struct StenoDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "steno-daemon",
        abstract: "Headless recording, transcription, and analysis daemon for Steno",
        version: "0.1.0",
        subcommands: [RunCommand.self, StatusCommand.self, InstallCommand.self, UninstallCommand.self],
        defaultSubcommand: RunCommand.self
    )
}
