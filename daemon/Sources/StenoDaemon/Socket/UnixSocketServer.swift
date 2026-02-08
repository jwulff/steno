import Foundation
import Network
import os

/// Unix domain socket server using NWListener.
///
/// Each connected client gets a read loop that reads newline-delimited JSON
/// commands and dispatches them via the `onCommand` handler.
public final class UnixSocketServer: SocketServerProtocol, @unchecked Sendable {
    private var listener: NWListener?
    private let connections = OSAllocatedUnfairLock(initialState: [UUID: NWConnectionWrapper]())
    private var socketPath: String?

    public var onCommand: (@Sendable (any ClientConnection, DaemonCommand) async -> Void)?
    public var onClientDisconnected: (@Sendable (UUID) async -> Void)?

    public init() {}

    public func start(at path: String) async throws {
        // Remove stale socket file
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        // Ensure parent directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        socketPath = path

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        listener.start(queue: .global(qos: .userInitiated))
    }

    public func stop() async {
        listener?.cancel()
        listener = nil

        let conns = connections.withLock { conns -> [NWConnectionWrapper] in
            let values = Array(conns.values)
            conns.removeAll()
            return values
        }

        for conn in conns {
            await conn.close()
        }

        // Remove socket file
        if let path = socketPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let wrapper = NWConnectionWrapper(connection: nwConnection)

        connections.withLock { $0[wrapper.id] = wrapper }

        nwConnection.start(queue: .global(qos: .userInitiated))
        readLine(from: wrapper)
    }

    private func readLine(from wrapper: NWConnectionWrapper) {
        wrapper.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // Split by newlines — there may be multiple commands in one read
                let str = String(data: data, encoding: .utf8) ?? ""
                let lines = str.split(separator: "\n", omittingEmptySubsequences: true)

                for line in lines {
                    let lineData = Data(line.utf8)
                    if let command = try? JSONDecoder().decode(DaemonCommand.self, from: lineData) {
                        let handler = self.onCommand
                        Task {
                            await handler?(wrapper, command)
                        }
                    } else {
                        // Malformed JSON — send error response
                        let response = DaemonResponse.failure("Invalid JSON")
                        if let responseData = try? JSONEncoder().encode(response) {
                            Task {
                                try? await wrapper.send(responseData + Data("\n".utf8))
                            }
                        }
                    }
                }
            }

            if isComplete || error != nil {
                self.removeConnection(wrapper.id)
                return
            }

            // Continue reading
            self.readLine(from: wrapper)
        }
    }

    private func removeConnection(_ id: UUID) {
        let existed = connections.withLock { $0.removeValue(forKey: id) != nil }

        if existed {
            let handler = onClientDisconnected
            Task {
                await handler?(id)
            }
        }
    }
}

/// Wraps an NWConnection to conform to ClientConnection.
final class NWConnectionWrapper: ClientConnection, @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() async {
        connection.cancel()
    }
}
