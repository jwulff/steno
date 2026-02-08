import Foundation

/// Protocol for the Unix domain socket server.
public protocol SocketServerProtocol: Sendable {
    /// Start listening on the given socket path.
    func start(at path: String) async throws

    /// Stop listening and close all connections.
    func stop() async

    /// Handler called when a command is received from a client.
    var onCommand: (@Sendable (any ClientConnection, DaemonCommand) async -> Void)? { get set }

    /// Handler called when a client disconnects.
    var onClientDisconnected: (@Sendable (UUID) async -> Void)? { get set }
}
