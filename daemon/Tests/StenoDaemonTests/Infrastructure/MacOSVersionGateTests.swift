import Foundation
import Testing

@testable import StenoDaemon

@Suite("MacOSVersionGate Tests")
struct MacOSVersionGateTests {
    // MARK: - Pre-26 systems are rejected

    @Test func macOS25IsRejected() {
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 25, minorVersion: 0, patchVersion: 0)
        )

        #expect(!result.isSupported)
        #expect(result.message != nil)
        #expect(result.message!.contains("macOS 26.0 or later"))
        #expect(result.message!.contains("25.0.0"))
    }

    @Test func macOS25_9IsRejected() {
        // Highest plausible pre-26 version — still rejected.
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 25, minorVersion: 9, patchVersion: 5)
        )

        #expect(!result.isSupported)
        #expect(result.message!.contains("25.9.5"))
    }

    @Test func macOS14IsRejected() {
        // Sonoma — well below the floor.
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        )

        #expect(!result.isSupported)
        #expect(result.message!.contains("macOS 26.0 or later"))
    }

    // MARK: - macOS 26+ is accepted

    @Test func macOS26_0IsAccepted() {
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )

        #expect(result.isSupported)
        #expect(result.message == nil)
    }

    @Test func macOS26_1IsAccepted() {
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        )

        #expect(result.isSupported)
        #expect(result.message == nil)
    }

    @Test func macOS27IsAccepted() {
        // Future major version — still supported (we only enforce a floor).
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )

        #expect(result.isSupported)
        #expect(result.message == nil)
    }

    // MARK: - Message format

    @Test func rejectionMessageMatchesContract() {
        // The exact stderr-bound message format is part of U3's contract:
        //   "steno-daemon: requires macOS 26.0 or later (current: <version>)"
        let result = MacOSVersionGate.check(
            currentVersion: OperatingSystemVersion(majorVersion: 25, minorVersion: 4, patchVersion: 1)
        )

        #expect(result.message == "steno-daemon: requires macOS 26.0 or later (current: 25.4.1)")
    }

    // MARK: - CheckResult equality

    @Test func checkResultEquality() {
        let a = MacOSVersionGate.CheckResult(isSupported: true, message: nil)
        let b = MacOSVersionGate.CheckResult(isSupported: true, message: nil)
        let c = MacOSVersionGate.CheckResult(isSupported: false, message: "different")

        #expect(a == b)
        #expect(a != c)
    }
}
