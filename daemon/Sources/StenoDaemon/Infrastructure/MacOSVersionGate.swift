import Foundation

/// Refuses to start the daemon on pre-macOS-26 systems.
///
/// The daemon depends on macOS 26's `SpeechAnalyzer` / `SpeechTranscriber` APIs
/// and the `Package.swift` deployment target is `.macOS(.v26)`. In practice the
/// dynamic linker will reject a binary built against macOS 26 on an older system,
/// but a clear, attributable failure is much friendlier than a launch loop in
/// launchd's KeepAlive policy.
///
/// We deliberately use a runtime check (`OperatingSystemVersion`) instead of
/// `#available`, since `#available` is compile-time and the binary already
/// targets macOS 26. The runtime check defends against the (rare) scenario
/// where the binary somehow runs on an older system.
public enum MacOSVersionGate {
    /// Result of a version-gate check.
    public struct CheckResult: Equatable, Sendable {
        public let isSupported: Bool
        /// User-facing message intended for stderr. `nil` when supported.
        public let message: String?

        public init(isSupported: Bool, message: String?) {
            self.isSupported = isSupported
            self.message = message
        }
    }

    /// Minimum supported macOS version.
    public static let minimumVersion = OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 0,
        patchVersion: 0
    )

    /// Check whether `currentVersion` meets the minimum macOS version.
    ///
    /// - Parameter currentVersion: The OS version to evaluate. Production code
    ///   passes `ProcessInfo.processInfo.operatingSystemVersion`; tests pass
    ///   synthesized values.
    /// - Returns: A `CheckResult` whose `message` is non-nil only when
    ///   unsupported.
    public static func check(currentVersion: OperatingSystemVersion) -> CheckResult {
        if isAtLeast(currentVersion, minimumVersion) {
            return CheckResult(isSupported: true, message: nil)
        }

        let formatted = format(currentVersion)
        let message = "steno-daemon: requires macOS 26.0 or later (current: \(formatted))"
        return CheckResult(isSupported: false, message: message)
    }

    // MARK: - Private helpers

    private static func isAtLeast(
        _ version: OperatingSystemVersion,
        _ minimum: OperatingSystemVersion
    ) -> Bool {
        if version.majorVersion != minimum.majorVersion {
            return version.majorVersion > minimum.majorVersion
        }
        if version.minorVersion != minimum.minorVersion {
            return version.minorVersion > minimum.minorVersion
        }
        return version.patchVersion >= minimum.patchVersion
    }

    private static func format(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
