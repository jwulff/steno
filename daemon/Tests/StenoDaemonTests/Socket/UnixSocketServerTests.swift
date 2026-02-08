import Testing
import Foundation
import Network
import os
@testable import StenoDaemon

@Suite("UnixSocketServer Tests")
struct UnixSocketServerTests {

    /// Generate a unique socket path in /tmp for test isolation.
    private func tmpSocketPath() -> String {
        "/tmp/steno-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func listenAndAcceptConnection() async throws {
        let server = UnixSocketServer()
        let path = tmpSocketPath()

        let commandReceived = TestFlag()

        server.onCommand = { _, command in
            #expect(command.cmd == "status")
            commandReceived.set()
        }

        try await server.start(at: path)

        // Connect and send a command
        let clientConn = NWConnection(to: .unix(path: path), using: .tcp)
        clientConn.start(queue: .global())

        try await Task.sleep(for: .milliseconds(200))

        let json = #"{"cmd":"status"}"# + "\n"
        clientConn.send(content: Data(json.utf8), completion: .contentProcessed { _ in })

        try await Task.sleep(for: .milliseconds(500))

        #expect(commandReceived.isSet)

        clientConn.cancel()
        await server.stop()

        // Socket file should be cleaned up
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func staleSocketFileRemoved() async throws {
        let path = tmpSocketPath()

        // Create a stale socket file
        FileManager.default.createFile(atPath: path, contents: nil)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = UnixSocketServer()
        try await server.start(at: path)

        await server.stop()
    }

    @Test func multipleClients() async throws {
        let server = UnixSocketServer()
        let path = tmpSocketPath()

        let counter = OSAllocatedUnfairLock(initialState: 0)

        server.onCommand = { _, _ in
            counter.withLock { $0 += 1 }
        }

        try await server.start(at: path)

        // Connect two clients
        let client1 = NWConnection(to: .unix(path: path), using: .tcp)
        let client2 = NWConnection(to: .unix(path: path), using: .tcp)
        client1.start(queue: .global())
        client2.start(queue: .global())

        try await Task.sleep(for: .milliseconds(200))

        let json = #"{"cmd":"status"}"# + "\n"
        client1.send(content: Data(json.utf8), completion: .contentProcessed { _ in })
        client2.send(content: Data(json.utf8), completion: .contentProcessed { _ in })

        try await Task.sleep(for: .milliseconds(500))

        let count = counter.withLock { $0 }
        #expect(count == 2)

        client1.cancel()
        client2.cancel()
        await server.stop()
    }

    @Test func clientDisconnectNotification() async throws {
        let server = UnixSocketServer()
        let path = tmpSocketPath()

        let disconnected = TestFlag()

        server.onClientDisconnected = { _ in
            disconnected.set()
        }

        try await server.start(at: path)

        let client = NWConnection(to: .unix(path: path), using: .tcp)
        client.start(queue: .global())

        try await Task.sleep(for: .milliseconds(200))

        // Disconnect the client
        client.cancel()

        try await Task.sleep(for: .milliseconds(500))

        #expect(disconnected.isSet)

        await server.stop()
    }
}

/// Thread-safe flag for test assertions.
private final class TestFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
