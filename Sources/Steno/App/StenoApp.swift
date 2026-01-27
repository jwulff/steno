import Foundation
import SwiftTUI

/// Main application orchestrator that sets up dependencies and runs the TUI.
@MainActor
public struct StenoApp {
    private let speechService: SpeechRecognitionService
    private let permissionService: PermissionService

    public init(
        speechService: SpeechRecognitionService? = nil,
        permissionService: PermissionService? = nil
    ) {
        self.speechService = speechService ?? SpeechAnalyzerService()
        self.permissionService = permissionService ?? SystemPermissionService()
    }

    /// Runs the TUI application.
    public func run() async {
        // Request permissions before starting
        let status = await permissionService.checkPermissions()

        if !status.allGranted {
            print("Requesting permissions...")
            _ = await permissionService.requestSpeechRecognitionAccess()
        }

        // Start the TUI
        Application(rootView: MainView()).start()
    }
}
