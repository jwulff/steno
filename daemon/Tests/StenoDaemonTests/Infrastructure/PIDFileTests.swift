import Foundation
import Testing

@testable import StenoDaemon

@Suite("PIDFile Tests")
struct PIDFileTests {
    private func makeTempPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("steno-test-\(UUID().uuidString).pid").path
    }

    @Test func acquireWritesPIDFile() throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pidFile = PIDFile(path: path)
        let acquired = try pidFile.acquire()

        #expect(acquired)
        #expect(FileManager.default.fileExists(atPath: path))

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let writtenPID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(writtenPID == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func releaseRemovesPIDFile() throws {
        let path = makeTempPath()

        let pidFile = PIDFile(path: path)
        _ = try pidFile.acquire()
        #expect(FileManager.default.fileExists(atPath: path))

        pidFile.release()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func acquireFailsWhenOwnProcessRunning() throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Write our own PID (which is running)
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(toFile: path, atomically: true, encoding: .utf8)

        let pidFile = PIDFile(path: path)
        let acquired = try pidFile.acquire()

        #expect(!acquired)
    }

    @Test func acquireSucceedsWithStalePID() throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Write a PID that doesn't exist (very high PID unlikely to be running)
        try "999999".write(toFile: path, atomically: true, encoding: .utf8)

        let pidFile = PIDFile(path: path)
        let acquired = try pidFile.acquire()

        #expect(acquired)
    }

    @Test func isRunningReturnsFalseWithNoPIDFile() {
        let path = makeTempPath()
        let pidFile = PIDFile(path: path)

        let (running, pid) = pidFile.isRunning()
        #expect(!running)
        #expect(pid == nil)
    }

    @Test func isRunningReturnsTrueForLiveProcess() throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Write our own PID
        let myPID = ProcessInfo.processInfo.processIdentifier
        try String(myPID).write(toFile: path, atomically: true, encoding: .utf8)

        let pidFile = PIDFile(path: path)
        let (running, pid) = pidFile.isRunning()

        #expect(running)
        #expect(pid == myPID)
    }

    @Test func isRunningReturnsFalseForStalePID() throws {
        let path = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "999999".write(toFile: path, atomically: true, encoding: .utf8)

        let pidFile = PIDFile(path: path)
        let (running, pid) = pidFile.isRunning()

        #expect(!running)
        #expect(pid == nil)
    }

    @Test func releaseIsIdempotent() throws {
        let path = makeTempPath()

        let pidFile = PIDFile(path: path)
        _ = try pidFile.acquire()

        pidFile.release()
        pidFile.release() // Should not throw
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
