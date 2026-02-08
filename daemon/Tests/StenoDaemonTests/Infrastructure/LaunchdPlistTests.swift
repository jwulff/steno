import Foundation
import Testing

@testable import StenoDaemon

@Suite("LaunchdPlist Tests")
struct LaunchdPlistTests {
    @Test func labelIsCorrect() {
        #expect(LaunchdPlist.label == "com.steno.daemon")
    }

    @Test func plistPathIsInLaunchAgents() {
        let path = LaunchdPlist.plistPath
        #expect(path.contains("Library/LaunchAgents"))
        #expect(path.hasSuffix("com.steno.daemon.plist"))
    }

    @Test func generateProducesValidXML() {
        let xml = LaunchdPlist.generate(executablePath: "/usr/local/bin/steno-daemon")

        #expect(xml.contains("<?xml version=\"1.0\""))
        #expect(xml.contains("<!DOCTYPE plist"))
        #expect(xml.contains("<plist version=\"1.0\">"))
        #expect(xml.contains("</plist>"))
    }

    @Test func generateContainsLabel() {
        let xml = LaunchdPlist.generate(executablePath: "/usr/local/bin/steno-daemon")

        #expect(xml.contains("<key>Label</key>"))
        #expect(xml.contains("<string>com.steno.daemon</string>"))
    }

    @Test func generateContainsExecutablePath() {
        let path = "/opt/homebrew/bin/steno-daemon"
        let xml = LaunchdPlist.generate(executablePath: path)

        #expect(xml.contains("<string>\(path)</string>"))
        #expect(xml.contains("<string>run</string>"))
    }

    @Test func generateHasRunAtLoad() {
        let xml = LaunchdPlist.generate(executablePath: "/usr/local/bin/steno-daemon")

        #expect(xml.contains("<key>RunAtLoad</key>"))
        #expect(xml.contains("<true/>"))
    }

    @Test func generateHasKeepAlive() {
        let xml = LaunchdPlist.generate(executablePath: "/usr/local/bin/steno-daemon")

        #expect(xml.contains("<key>KeepAlive</key>"))
        #expect(xml.contains("<key>SuccessfulExit</key>"))
        #expect(xml.contains("<false/>"))
    }

    @Test func generateHasLogPaths() {
        let xml = LaunchdPlist.generate(executablePath: "/usr/local/bin/steno-daemon")

        #expect(xml.contains("<key>StandardOutPath</key>"))
        #expect(xml.contains("<key>StandardErrorPath</key>"))
        #expect(xml.contains("daemon.log"))
    }

    @Test func installWritesPlistFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-launchd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistPath = tempDir.appendingPathComponent("test.plist").path
        let xml = LaunchdPlist.generate(executablePath: "/usr/local/bin/steno-daemon")
        try xml.write(toFile: plistPath, atomically: true, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: plistPath))

        let contents = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(contents.contains("com.steno.daemon"))
    }
}
