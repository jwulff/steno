import Foundation
import AVFoundation

/// Real implementation of PermissionService using system APIs.
///
/// Only checks microphone access via AVCaptureDevice. Speech recognition
/// permission is not checked because macOS 26 SpeechAnalyzer does not
/// require the legacy SFSpeechRecognizer entitlement or TCC grant.
public final class SystemPermissionService: PermissionService, Sendable {

    public init() {}

    public func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func checkPermissions() async -> PermissionStatus {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return PermissionStatus(microphoneGranted: micStatus == .authorized)
    }
}
