import Foundation
@testable import StenoDaemon

/// Mock socket server for testing.
final class MockSocketServer: SocketServerProtocol, @unchecked Sendable {
    var onCommand: (@Sendable (any ClientConnection, DaemonCommand) async -> Void)?
    var onClientDisconnected: (@Sendable (UUID) async -> Void)?

    private(set) var startCalled = false
    private(set) var stopCalled = false
    private(set) var lastPath: String?

    func start(at path: String) async throws {
        startCalled = true
        lastPath = path
    }

    func stop() async {
        stopCalled = true
    }

    /// Simulate receiving a command from a client.
    func simulateCommand(from client: any ClientConnection, command: DaemonCommand) async {
        await onCommand?(client, command)
    }
}
