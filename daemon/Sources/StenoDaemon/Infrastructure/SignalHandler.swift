import Foundation

/// Signals that the daemon handles for graceful shutdown.
public enum DaemonSignal: Sendable {
    case terminate
    case interrupt
}

/// Creates an AsyncStream that yields when SIGTERM or SIGINT is received.
public func makeSignalStream() -> AsyncStream<DaemonSignal> {
    AsyncStream { continuation in
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler {
            continuation.yield(.terminate)
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler {
            continuation.yield(.interrupt)
        }
        intSource.resume()

        continuation.onTermination = { _ in
            termSource.cancel()
            intSource.cancel()
        }
    }
}
