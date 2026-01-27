import ArgumentParser
import Foundation
import SwiftTUI

@main
struct Steno: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Real-time speech-to-text transcription for macOS",
        version: "0.1.0"
    )

    func run() throws {
        print("Steno - Speech to Text")
        print("Starting transcription interface...")
        print("")

        // dispatch run loop - now that we're not in async context, this should work
        Application(rootView: MainView()).start()
    }
}
