import Foundation
import Network

public enum DaemonClientError: Error, Sendable {
    case notConnected
    case encodingFailed
    case connectionFailed(String)
    case closed
}

/// Runs a closure at most once, safely across the connection's dispatch queue.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// NDJSON client for the daemon's Unix socket.
///
/// Uses two connections, mirroring the TUI:
///   • a **command** channel — one request in flight at a time, awaiting the
///     daemon's single response line (an `actor` serializes sends);
///   • an **event** channel — sends `subscribe`, then streams every following
///     line as a `DaemonEvent` into `events`.
///
/// The daemon's server is an `NWListener` bound to a Unix endpoint with a TCP
/// protocol stack, so a matching `NWConnection` interoperates directly.
public actor DaemonClient {
    private let socketPath: String

    private var commandConn: NWConnection?
    private var commandFramer = LineFramer()
    /// FIFO of awaiters; with serialized sends there is at most one.
    private var responseWaiters: [CheckedContinuation<DaemonResponse, Error>] = []
    private var bufferedResponses: [DaemonResponse] = []

    private var eventConn: NWConnection?
    private var eventFramer = LineFramer()
    private var eventContinuation: AsyncStream<DaemonEvent>.Continuation?

    /// Invoked (off the main actor) when either connection drops, so the app
    /// model can drive reconnection.
    public var onConnectionLost: (@Sendable () -> Void)?

    public init(socketPath: String = StenoPaths.socketPath) {
        self.socketPath = socketPath
    }

    public func setConnectionLostHandler(_ handler: @escaping @Sendable () -> Void) {
        self.onConnectionLost = handler
    }

    // MARK: - Connect

    /// Open both channels and subscribe to all events. Returns once the command
    /// channel is ready and the subscribe ack has been requested.
    public func connect() async throws {
        let cmd = makeConnection()
        let evt = makeConnection()
        self.commandConn = cmd
        self.eventConn = evt

        try await start(cmd, role: .command)
        try await start(evt, role: .event)

        // Begin streaming events, then subscribe.
        startReceiveLoop(on: evt, role: .event)
        startReceiveLoop(on: cmd, role: .command)

        // The subscribe ack arrives on the event channel as a bare {"ok":true}
        // line, which fails DaemonEvent decoding and is harmlessly ignored.
        try sendLine(DaemonCommand.subscribe, on: evt)
    }

    public func disconnect() {
        commandConn?.cancel()
        eventConn?.cancel()
        commandConn = nil
        eventConn = nil
        finishEvents()
        failAllWaiters(DaemonClientError.closed)
    }

    // MARK: - Commands

    /// Send a command and await its response. Serialized by the actor: the next
    /// caller suspends until this one's response arrives.
    public func send(_ command: DaemonCommand) async throws -> DaemonResponse {
        guard let conn = commandConn else { throw DaemonClientError.notConnected }

        if !bufferedResponses.isEmpty {
            return bufferedResponses.removeFirst()
        }

        try sendLine(command, on: conn)

        return try await withCheckedThrowingContinuation { continuation in
            responseWaiters.append(continuation)
        }
    }

    // MARK: - Events

    /// A stream of every event the daemon broadcasts. Created lazily; call once.
    public func events() -> AsyncStream<DaemonEvent> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    // MARK: - Internals

    private enum Role { case command, event }

    private func makeConnection() -> NWConnection {
        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        let endpoint = NWEndpoint.unix(path: socketPath)
        return NWConnection(to: endpoint, using: params)
    }

    private func start(_ conn: NWConnection, role: Role) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { cont.resume() }
                case .failed(let err):
                    once.run { cont.resume(throwing: DaemonClientError.connectionFailed("\(err)")) }
                    Task { await self.handleDrop() }
                case .cancelled:
                    once.run { cont.resume(throwing: DaemonClientError.closed) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private func sendLine(_ command: DaemonCommand, on conn: NWConnection) throws {
        guard var data = try? JSONEncoder().encode(command) else {
            throw DaemonClientError.encodingFailed
        }
        data.append(UInt8(ascii: "\n"))
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startReceiveLoop(on conn: NWConnection, role: Role) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { await self.ingest(data, role: role) }
            }
            if isComplete || error != nil {
                Task { await self.handleDrop() }
                return
            }
            Task { await self.continueReceiving(on: conn, role: role) }
        }
    }

    private func continueReceiving(on conn: NWConnection, role: Role) {
        // Only keep reading if this connection is still the live one.
        switch role {
        case .command where conn === commandConn: break
        case .event where conn === eventConn: break
        default: return
        }
        startReceiveLoop(on: conn, role: role)
    }

    private func ingest(_ data: Data, role: Role) {
        switch role {
        case .command:
            for line in commandFramer.append(data) {
                guard let resp = try? JSONDecoder().decode(DaemonResponse.self, from: line) else { continue }
                if let waiter = responseWaiters.first {
                    responseWaiters.removeFirst()
                    waiter.resume(returning: resp)
                } else {
                    bufferedResponses.append(resp)
                }
            }
        case .event:
            for line in eventFramer.append(data) {
                // The subscribe ack ({"ok":true}) has no `event` and is skipped.
                guard let evt = try? JSONDecoder().decode(DaemonEvent.self, from: line) else { continue }
                eventContinuation?.yield(evt)
            }
        }
    }

    private func handleDrop() {
        // Cancel and nil out both connections so stale callbacks from old
        // connections can't tear down a freshly-established session, and so
        // commands fail immediately rather than queuing against a dead socket.
        commandConn?.cancel()
        commandConn = nil
        eventConn?.cancel()
        eventConn = nil
        commandFramer = LineFramer()
        eventFramer = LineFramer()
        finishEvents()
        failAllWaiters(DaemonClientError.closed)
        let handler = onConnectionLost
        if let handler {
            Task.detached { handler() }
        }
    }

    private func finishEvents() {
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func failAllWaiters(_ error: Error) {
        let waiters = responseWaiters
        responseWaiters.removeAll()
        for w in waiters { w.resume(throwing: error) }
    }
}
