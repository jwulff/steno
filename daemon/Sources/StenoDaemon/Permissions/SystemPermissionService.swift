import Foundation
import AVFoundation
import Speech

/// Real implementation of PermissionService using system APIs.
public final class SystemPermissionService: PermissionService, Sendable {

    public init() {}

    public func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public func requestSpeechRecognitionAccess() async -> PermissionStatus {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        let micGranted = await requestMicrophoneAccess()
        let speechGranted = speechStatus == .authorized

        return PermissionStatus(
            microphoneGranted: micGranted,
            speechRecognitionGranted: speechGranted
        )
    }

    public func checkPermissions() async -> PermissionStatus {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        return PermissionStatus(
            microphoneGranted: micStatus == .authorized,
            speechRecognitionGranted: speechStatus == .authorized
        )
    }
}
