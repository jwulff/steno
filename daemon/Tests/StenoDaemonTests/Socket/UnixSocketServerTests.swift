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

    // MARK: - #105: connection teardown

    /// A client that disconnects must leave a *cancelled* connection behind,
    /// not merely an unregistered one. Network.framework retains a started
    /// NWConnection until it is cancelled, so dropping the last Swift
    /// reference does not release the underlying socket.
    @Test func clientDisconnectCancelsConnection() async throws {
        let server = UnixSocketServer()
        let path = tmpSocketPath()

        let captured = CapturedConnection()

        server.onCommand = { client, _ in
            captured.set(client as? NWConnectionWrapper)
        }

        try await server.start(at: path)

        let client = NWConnection(to: .unix(path: path), using: .tcp)
        client.start(queue: .global())

        try await Task.sleep(for: .milliseconds(200))

        let json = #"{"cmd":"status"}"# + "\n"
        client.send(content: Data(json.utf8), completion: .contentProcessed { _ in })

        try await Task.sleep(for: .milliseconds(400))

        let wrapper = try #require(captured.value)
        #expect(wrapper.connection.state != .cancelled)

        client.cancel()

        try await Task.sleep(for: .milliseconds(600))

        #expect(wrapper.connection.state == .cancelled)

        await server.stop()
    }

    /// The user-visible defect from #105: every accepted connection leaked one
    /// descriptor, so a long-lived daemon eventually hit EMFILE, `accept()`
    /// started failing, and clients hung on connections the daemon would never
    /// read. Both ends live in this process, so a server-side leak shows up in
    /// the process descriptor count.
    ///
    /// The client does a full request/response round trip before closing,
    /// matching how the TUI and the daemon health probe actually talk to the
    /// socket. A client that writes and closes without reading is torn down by
    /// Network.framework before the read loop ever sees it, and does not leak.
    @Test func closedConnectionsDoNotLeakDescriptors() async throws {
        let server = UnixSocketServer()
        let path = tmpSocketPath()

        let accepted = OSAllocatedUnfairLock(initialState: 0)
        server.onCommand = { client, _ in
            accepted.withLock { $0 += 1 }
            try? await client.send(Data((#"{"ok":true}"# + "\n").utf8))
        }

        try await server.start(at: path)
        try await waitForSocket(at: path)

        // One warm-up round trip so Network.framework's one-time per-listener
        // allocations are inside the baseline rather than counted as a leak.
        try roundTrip(path: path)
        try await Task.sleep(for: .milliseconds(500))

        let baseline = openFileDescriptorCount()

        let cycles = 20
        for _ in 0 ..< cycles {
            try roundTrip(path: path)
        }
        try await Task.sleep(for: .milliseconds(1000))

        let growth = openFileDescriptorCount() - baseline

        #expect(accepted.withLock { $0 } == cycles + 1, "server did not service every connection")

        // Before the fix this grew by one descriptor per connection.
        #expect(growth <= 4, "leaked \(growth) descriptors across \(cycles) round trips")

        await server.stop()
    }

    /// A send that fails must tear the connection down. Otherwise a client that
    /// died mid-response leaves a registered, un-cancelled socket behind, which
    /// is the same leak by another route.
    @Test(.timeLimit(.minutes(1)))
    func sendFailureNotifiesOwner() async throws {
        let connection = NWConnection(to: .unix(path: tmpSocketPath()), using: .tcp)

        let notified = TestFlag()
        let wrapper = NWConnectionWrapper(connection: connection) { _ in
            notified.set()
        }

        connection.start(queue: .global())

        // Cancelling first guarantees the send fails promptly. Pointing the
        // connection at a socket nobody is listening on is not enough: the
        // send is queued against a connection that never becomes ready, and
        // the completion handler is never called at all.
        connection.cancel()
        try await Task.sleep(for: .milliseconds(300))

        await #expect(throws: (any Error).self) {
            try await wrapper.send(Data((#"{"ok":true}"# + "\n").utf8))
        }

        #expect(notified.isSet)
    }

    // MARK: - Helpers

    /// Open a raw client socket, send one command, read the response, and
    /// close. Raw sockets rather than NWConnection so the client side is
    /// released synchronously on `close()` and any residual growth is
    /// unambiguously the server's.
    private func roundTrip(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socketFailed(errno)
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketTestError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw SocketTestError.connectFailed(errno)
        }

        let line = Data((#"{"cmd":"status"}"# + "\n").utf8)
        _ = line.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }

        // Read the response so the connection is a completed round trip, then
        // let `defer` close it.
        var scratch = [UInt8](repeating: 0, count: 256)
        _ = read(fd, &scratch, scratch.count)
    }

    /// `NWListener.start` returns before the listener is ready, so the socket
    /// file appears asynchronously. Wait for it rather than guessing a sleep.
    private func waitForSocket(at path: String, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SocketTestError.listenerNotReady
    }

    /// Count this process's open descriptors. Descriptors are handed out
    /// lowest-first, so scanning a bounded window is exact for a test that
    /// opens a few dozen.
    private func openFileDescriptorCount() -> Int {
        var count = 0
        for fd in Int32(0) ..< Int32(4096) where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
    }
}

/// Errors raised by the raw-socket test helper.
private enum SocketTestError: Error {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case pathTooLong
    case listenerNotReady
}

/// Thread-safe holder for the connection wrapper handed to `onCommand`.
private final class CapturedConnection: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: NWConnectionWrapper?.none)

    var value: NWConnectionWrapper? { state.withLock { $0 } }

    func set(_ wrapper: NWConnectionWrapper?) {
        state.withLock { $0 = wrapper }
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
