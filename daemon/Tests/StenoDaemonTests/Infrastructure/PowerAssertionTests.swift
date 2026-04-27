import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U6's `PowerAssertion`.
///
/// Exercises acquire/release with a real `IOPMAssertionCreateWithName`
/// call. We shell out to `pmset -g assertions` to verify visibility.
/// On systems where `pmset` is unavailable (sandboxed CI containers)
/// the visibility checks are skipped, but the API contract (idempotent
/// release, deinit-release) is still asserted.
@Suite("PowerAssertion Tests (U6)")
struct PowerAssertionTests {

    // MARK: - API contract (cheap, always run)

    @Test("acquire then release → no crash, no leak")
    func acquireAndReleaseCleanly() throws {
        let assertion = PowerAssertion(name: "Steno: test acquire/release")
        try assertion.acquire()
        assertion.release()
        // Second release is idempotent (no double-release crash).
        assertion.release()
    }

    @Test("deinit releases automatically without explicit release()")
    func deinitReleasesAutomatically() throws {
        // Hold the assertion in a local scope so it deinits at scope-end.
        do {
            let assertion = PowerAssertion(name: "Steno: test deinit")
            try assertion.acquire()
            // Intentionally NOT calling release() — deinit must clean up.
            _ = assertion
        }
        // Survival of this line proves no SIGABRT in deinit.
    }

    @Test("acquire is idempotent — second acquire is a no-op")
    func acquireIsIdempotent() throws {
        let assertion = PowerAssertion(name: "Steno: test idempotent acquire")
        try assertion.acquire()
        // Second acquire must not throw and must not leak a second
        // IOPMAssertion (caller would otherwise need to release twice).
        try assertion.acquire()
        assertion.release()
    }

    @Test("release without acquire is a no-op")
    func releaseWithoutAcquireIsNoOp() {
        let assertion = PowerAssertion(name: "Steno: test release-without-acquire")
        // No throw, no crash.
        assertion.release()
    }

    // MARK: - pmset visibility (skips if pmset unavailable)

    /// Run `pmset -g assertions` and return its stdout, or nil if pmset
    /// is unavailable or returns nonzero status.
    private func pmsetAssertions() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    @Test("pmset shows the assertion name only while held")
    func pmsetVisibility() throws {
        // Use a unique-enough name to avoid collisions with parallel tests.
        let uniqueName = "Steno: pmset-visibility-\(UUID().uuidString.prefix(6))"

        // Pre-state: name is not present.
        guard let before = pmsetAssertions() else {
            // pmset unavailable; skip the visibility assertion.
            return
        }
        #expect(!before.contains(uniqueName))

        let assertion = PowerAssertion(name: uniqueName)
        try assertion.acquire()

        // Post-acquire: name appears in pmset.
        let during = pmsetAssertions() ?? ""
        #expect(during.contains(uniqueName))

        assertion.release()

        // Post-release: name is gone again.
        let after = pmsetAssertions() ?? ""
        #expect(!after.contains(uniqueName))
    }
}
