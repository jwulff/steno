import Foundation
@testable import StenoDaemon

/// Mock client connection that captures sent data for test assertions.
actor MockClientConnection: ClientConnection {
    nonisolated let id = UUID()
    private var sentData: [Data] = []
    private(set) var closeCalled = false
    var shouldThrowOnSend = false

    nonisolated func send(_ data: Data) async throws {
        if await shouldThrowOnSend {
            throw MockConnectionError.sendFailed
        }
        await appendData(data)
    }

    private func appendData(_ data: Data) {
        sentData.append(data)
    }

    nonisolated func close() async {
        await markClosed()
    }

    private func markClosed() {
        closeCalled = true
    }

    // MARK: - Test Helpers

    /// All data that was sent to this connection.
    var allSentData: [Data] { sentData }

    /// Decode sent data as DaemonResponse lines.
    var sentResponses: [DaemonResponse] {
        sentData.compactMap { data in
            // Data may contain trailing newline
            let trimmed = data.filter { $0 != UInt8(ascii: "\n") }
            return try? JSONDecoder().decode(DaemonResponse.self, from: trimmed)
        }
    }

    /// Decode sent data as DaemonEvent lines.
    var sentEvents: [DaemonEvent] {
        sentData.compactMap { data in
            let trimmed = data.filter { $0 != UInt8(ascii: "\n") }
            return try? JSONDecoder().decode(DaemonEvent.self, from: trimmed)
        }
    }

    func reset() {
        sentData.removeAll()
        closeCalled = false
        shouldThrowOnSend = false
    }
}

enum MockConnectionError: Error {
    case sendFailed
}
