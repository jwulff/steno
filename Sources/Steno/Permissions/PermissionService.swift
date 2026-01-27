import Foundation

/// Status of required permissions for speech recognition.
public struct PermissionStatus: Sendable, Equatable {
    /// Whether microphone access is granted.
    public let microphoneGranted: Bool

    /// Whether speech recognition is authorized.
    public let speechRecognitionGranted: Bool

    /// Whether all required permissions are granted.
    public var allGranted: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    /// Error message if permissions are denied.
    public var errorMessage: String? {
        var missing: [String] = []
        if !microphoneGranted {
            missing.append("Microphone access")
        }
        if !speechRecognitionGranted {
            missing.append("Speech recognition")
        }
        return missing.isEmpty ? nil : "Missing permissions: \(missing.joined(separator: ", "))"
    }

    public init(microphoneGranted: Bool, speechRecognitionGranted: Bool) {
        self.microphoneGranted = microphoneGranted
        self.speechRecognitionGranted = speechRecognitionGranted
    }

    /// All permissions granted.
    public static let granted = PermissionStatus(microphoneGranted: true, speechRecognitionGranted: true)

    /// All permissions denied.
    public static let denied = PermissionStatus(microphoneGranted: false, speechRecognitionGranted: false)
}

/// Protocol for checking and requesting system permissions.
public protocol PermissionService: Sendable {
    /// Requests microphone access from the user.
    /// - Returns: Whether access was granted.
    func requestMicrophoneAccess() async -> Bool

    /// Requests speech recognition authorization.
    /// - Returns: The current permission status after the request.
    func requestSpeechRecognitionAccess() async -> PermissionStatus

    /// Checks current permission status without prompting.
    /// - Returns: The current permission status.
    func checkPermissions() async -> PermissionStatus
}
