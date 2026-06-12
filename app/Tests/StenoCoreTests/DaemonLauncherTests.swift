import Testing
import Foundation
@testable import StenoCore

struct DaemonLauncherTests {

    @Test func prefersColocatedBinary() {
        let path = DaemonLauncher.resolveDaemonPath(
            env: ["STENO_DAEMON_PATH": "/override/steno-daemon", "PATH": "/usr/bin"],
            home: "/Users/x",
            colocatedDir: "/Applications/Steno.app/Contents/MacOS",
            fileExists: { $0 == "/Applications/Steno.app/Contents/MacOS/steno-daemon" }
        )
        #expect(path == "/Applications/Steno.app/Contents/MacOS/steno-daemon")
    }

    @Test func fallsBackToEnvOverride() {
        let path = DaemonLauncher.resolveDaemonPath(
            env: ["STENO_DAEMON_PATH": "/override/steno-daemon", "PATH": "/usr/bin"],
            home: "/Users/x",
            colocatedDir: "/nope",
            fileExists: { $0 == "/override/steno-daemon" }
        )
        #expect(path == "/override/steno-daemon")
    }

    @Test func fallsBackToLocalBin() {
        let path = DaemonLauncher.resolveDaemonPath(
            env: ["PATH": "/usr/bin"],
            home: "/Users/x",
            colocatedDir: nil,
            fileExists: { $0 == "/Users/x/.local/bin/steno-daemon" }
        )
        #expect(path == "/Users/x/.local/bin/steno-daemon")
    }

    @Test func searchesPathEntries() {
        let path = DaemonLauncher.resolveDaemonPath(
            env: ["PATH": "/a:/b:/c"],
            home: "/Users/x",
            colocatedDir: nil,
            fileExists: { $0 == "/b/steno-daemon" }
        )
        #expect(path == "/b/steno-daemon")
    }

    @Test func returnsNilWhenNothingFound() {
        let path = DaemonLauncher.resolveDaemonPath(
            env: ["PATH": "/a:/b"],
            home: "/Users/x",
            colocatedDir: "/nope",
            fileExists: { _ in false }
        )
        #expect(path == nil)
    }
}
