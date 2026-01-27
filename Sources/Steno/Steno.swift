import ArgumentParser
import Foundation

@main
struct Steno: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Real-time speech-to-text transcription for macOS",
        version: "0.1.0"
    )

    @Flag(name: .shortAndLong, help: "Print version and exit")
    var version = false

    func run() async throws {
        if version {
            print("Steno v0.1.0")
            return
        }

        print("Steno - Speech to Text")
        print("Starting transcription interface...")
        print("")

        await StenoApp().run()
    }
}
