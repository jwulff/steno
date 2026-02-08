import Foundation

/// Routes socket commands to the RecordingEngine and returns responses.
public actor CommandDispatcher {
    private let engine: RecordingEngine
    private let broadcaster: EventBroadcaster

    public init(engine: RecordingEngine, broadcaster: EventBroadcaster) {
        self.engine = engine
        self.broadcaster = broadcaster
    }

    /// Handle a command from a client and send a response.
    public func handle(
        _ command: DaemonCommand,
        from client: any ClientConnection
    ) async {
        let response: DaemonResponse

        switch command.cmd {
        case "start":
            response = await handleStart(command)

        case "stop":
            response = await handleStop()

        case "status":
            response = await handleStatus()

        case "devices":
            response = await handleDevices()

        case "subscribe":
            response = await handleSubscribe(command, from: client)

        default:
            response = DaemonResponse.failure("Unknown command: \(command.cmd)")
        }

        // Send response
        if let data = try? JSONEncoder().encode(response) {
            try? await client.send(data + Data("\n".utf8))
        }
    }

    // MARK: - Command Handlers

    private func handleStart(_ command: DaemonCommand) async -> DaemonResponse {
        let locale: Locale
        if let localeId = command.locale {
            locale = Locale(identifier: localeId)
        } else {
            locale = .current
        }

        do {
            let session = try await engine.start(
                locale: locale,
                device: command.device,
                systemAudio: command.systemAudio ?? false
            )
            return DaemonResponse(
                ok: true,
                sessionId: session.id.uuidString,
                recording: true
            )
        } catch {
            return DaemonResponse.failure(error.localizedDescription)
        }
    }

    private func handleStop() async -> DaemonResponse {
        await engine.stop()
        return DaemonResponse(ok: true, recording: false)
    }

    private func handleStatus() async -> DaemonResponse {
        let status = await engine.status
        let session = await engine.currentSession
        let segments = await engine.segmentCount
        let device = await engine.currentDevice
        let systemAudio = await engine.isSystemAudioEnabled

        return DaemonResponse(
            ok: true,
            sessionId: session?.id.uuidString,
            recording: status == .recording,
            segments: segments,
            status: status.rawValue,
            device: device,
            systemAudio: systemAudio
        )
    }

    private func handleDevices() async -> DaemonResponse {
        let devices = await engine.availableDevices()
        return DaemonResponse(
            ok: true,
            devices: devices.map(\.name)
        )
    }

    private func handleSubscribe(
        _ command: DaemonCommand,
        from client: any ClientConnection
    ) async -> DaemonResponse {
        let eventTypes: Set<EventType>
        if let requested = command.events {
            eventTypes = Set(requested.compactMap { EventType(rawValue: $0) })
        } else {
            eventTypes = Set(EventType.allCases)
        }

        await broadcaster.subscribe(client: client, events: eventTypes)
        return DaemonResponse.success()
    }
}
