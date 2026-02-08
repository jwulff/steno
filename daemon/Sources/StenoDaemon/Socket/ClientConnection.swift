import Foundation

/// Protocol wrapping a client connection to the daemon socket.
public protocol ClientConnection: Sendable, Identifiable where ID == UUID {
    var id: UUID { get }

    /// Send raw data to the client.
    func send(_ data: Data) async throws

    /// Close the connection.
    func close() async
}
