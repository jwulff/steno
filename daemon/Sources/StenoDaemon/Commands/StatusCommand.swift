import ArgumentParser
import Foundation
import Network

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check daemon status"
    )

    @Option(name: .long, help: "Socket path")
    var socketPath: String?

    func run() throws {
        let sockPath = socketPath ?? DaemonPaths.socketPath

        // Check PID file first
        let pidFile = PIDFile()
        let (running, pid) = pidFile.isRunning()

        if !running {
            print("steno-daemon: not running")
            if !FileManager.default.fileExists(atPath: sockPath) {
                return
            }
        }

        if let pid {
            print("steno-daemon: running (PID \(pid))")
        }

        // Try to connect and get status
        print("Socket: \(sockPath)")
    }
}
