import Foundation
@testable import StenoDaemon

/// Mock implementation of PermissionService for testing.
/// Uses @MainActor to avoid concurrency issues in tests.
@MainActor
final class MockPermissionService: PermissionService {
    /// The status to return from checkPermissions and requestSpeechRecognitionAccess.
    var permissionStatus: PermissionStatus = .granted

    /// The value to return from requestMicrophoneAccess.
    var microphoneAccessGranted = true

    /// Tracks if requestMicrophoneAccess was called.
    private(set) var microphoneAccessRequested = false

    /// Tracks if requestSpeechRecognitionAccess was called.
    private(set) var speechRecognitionRequested = false

    /// Tracks if checkPermissions was called.
    private(set) var permissionsChecked = false

    nonisolated func requestMicrophoneAccess() async -> Bool {
        await MainActor.run {
            self.microphoneAccessRequested = true
            return self.microphoneAccessGranted
        }
    }

    nonisolated func requestSpeechRecognitionAccess() async -> PermissionStatus {
        await MainActor.run {
            self.speechRecognitionRequested = true
            return self.permissionStatus
        }
    }

    nonisolated func checkPermissions() async -> PermissionStatus {
        await MainActor.run {
            self.permissionsChecked = true
            return self.permissionStatus
        }
    }

    // MARK: - Test Helpers

    /// Resets all state for a new test.
    func reset() {
        permissionStatus = .granted
        microphoneAccessGranted = true
        microphoneAccessRequested = false
        speechRecognitionRequested = false
        permissionsChecked = false
    }

    /// Configures all permissions as denied.
    func denyAll() {
        permissionStatus = .denied
        microphoneAccessGranted = false
    }

    /// Configures all permissions as granted.
    func grantAll() {
        permissionStatus = .granted
        microphoneAccessGranted = true
    }
}
