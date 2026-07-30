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

    /// Sent lines classified in wire order (#86). `sentResponses` and
    /// `sentEvents` each drop the other kind, so neither can show what a
    /// client reading the socket sequentially actually sees first — and for
    /// the subscribe path that ordering is the whole contract.
    var sentLines: [SentLine] {
        sentData.map { data in
            let trimmed = data.filter { $0 != UInt8(ascii: "\n") }
            if let response = try? JSONDecoder().decode(DaemonResponse.self, from: trimmed) {
                return .response(response)
            }
            if let event = try? JSONDecoder().decode(DaemonEvent.self, from: trimmed) {
                return .event(event)
            }
            return .undecodable
        }
    }

    func reset() {
        sentData.removeAll()
        closeCalled = false
        shouldThrowOnSend = false
    }
}

/// One NDJSON line as written to a client, tagged with what it decodes as.
enum SentLine {
    case response(DaemonResponse)
    case event(DaemonEvent)
    case undecodable
}

enum MockConnectionError: Error {
    case sendFailed
}
