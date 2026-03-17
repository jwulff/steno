import Foundation

/// Status of required permissions.
///
/// Only checks microphone access. macOS 26 SpeechAnalyzer does not require
/// the `com.apple.developer.speech-recognition` entitlement or TCC check —
/// that was only needed for the legacy SFSpeechRecognizer API.
public struct PermissionStatus: Sendable, Equatable {
    /// Whether microphone access is granted.
    public let microphoneGranted: Bool

    /// Whether all required permissions are granted.
    public var allGranted: Bool {
        microphoneGranted
    }

    /// Error message if permissions are denied.
    public var errorMessage: String? {
        microphoneGranted ? nil : "Missing permissions: Microphone access"
    }

    public init(microphoneGranted: Bool) {
        self.microphoneGranted = microphoneGranted
    }

    /// All permissions granted.
    public static let granted = PermissionStatus(microphoneGranted: true)

    /// All permissions denied.
    public static let denied = PermissionStatus(microphoneGranted: false)
}

/// Protocol for checking and requesting system permissions.
public protocol PermissionService: Sendable {
    /// Requests microphone access from the user.
    /// - Returns: Whether access was granted.
    func requestMicrophoneAccess() async -> Bool

    /// Checks current permission status without prompting.
    /// - Returns: The current permission status.
    func checkPermissions() async -> PermissionStatus
}
