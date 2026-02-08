import Foundation
import Testing

@testable import StenoDaemon

@Suite("SignalHandler Tests")
struct SignalHandlerTests {
    @Test func makeSignalStreamReturnsDaemonSignalStream() async {
        // Verify the stream can be created and cancelled without crashing
        let stream = makeSignalStream()
        var iterator = stream.makeAsyncIterator()

        // Send SIGINT to ourselves
        kill(ProcessInfo.processInfo.processIdentifier, SIGINT)

        let signal = await iterator.next()
        #expect(signal == .interrupt)
    }

    @Test func daemonSignalCases() {
        // Verify the enum has the expected cases
        let terminate = DaemonSignal.terminate
        let interrupt = DaemonSignal.interrupt

        #expect(terminate != interrupt)
    }
}
