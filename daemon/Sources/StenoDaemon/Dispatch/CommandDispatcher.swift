import Foundation

/// Routes socket commands to the RecordingEngine and returns responses.
public actor CommandDispatcher {
    private let engine: RecordingEngine
    private let broadcaster: EventBroadcaster

    /// Default auto-resume window for `pause` commands that omit both
    /// `autoResumeSeconds` and `indefinite`. 30 minutes matches the
    /// plan's UX choice and is intentionally explicit (not a magic
    /// number sprinkled in the engine).
    public static let defaultPauseAutoResumeSeconds: Double = 1800

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

        case "pause":
            response = await handlePause(command)

        case "resume":
            response = await handleResume()

        case "demarcate":
            response = await handleDemarcate()

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
        let pause = await engine.pauseStateSnapshot()

        return DaemonResponse(
            ok: true,
            sessionId: session?.id.uuidString,
            recording: status == .recording,
            segments: segments,
            status: status.rawValue,
            device: device,
            systemAudio: systemAudio,
            paused: pause.paused,
            pausedIndefinitely: pause.indefinite,
            pauseExpiresAt: pause.expiresAt?.timeIntervalSince1970
        )
    }

    // MARK: - U10 pause / resume / demarcate

    private func handlePause(_ command: DaemonCommand) async -> DaemonResponse {
        // Resolve auto-resume window. Explicit `indefinite=true` wins over
        // `autoResumeSeconds`. If neither is supplied, default to the
        // server-side timeout (30 min).
        let autoResumeSeconds: TimeInterval?
        if command.indefinite == true {
            autoResumeSeconds = nil
        } else if let secs = command.autoResumeSeconds {
            autoResumeSeconds = secs
        } else {
            autoResumeSeconds = Self.defaultPauseAutoResumeSeconds
        }

        do {
            try await engine.pause(autoResumeSeconds: autoResumeSeconds)
            let snapshot = await engine.pauseStateSnapshot()
            return DaemonResponse(
                ok: true,
                recording: false,
                status: EngineStatus.paused.rawValue,
                paused: snapshot.paused,
                pausedIndefinitely: snapshot.indefinite,
                pauseExpiresAt: snapshot.expiresAt?.timeIntervalSince1970
            )
        } catch {
            return DaemonResponse.failure(error.localizedDescription)
        }
    }

    private func handleResume() async -> DaemonResponse {
        do {
            try await engine.resume()
            let session = await engine.currentSession
            return DaemonResponse(
                ok: true,
                sessionId: session?.id.uuidString,
                recording: true,
                paused: false,
                pausedIndefinitely: false,
                pauseExpiresAt: nil
            )
        } catch {
            return DaemonResponse.failure(error.localizedDescription)
        }
    }

    private func handleDemarcate() async -> DaemonResponse {
        do {
            let fresh = try await engine.demarcate()
            // Re-read the engine status AFTER `demarcate()` returns. The
            // happy path leaves status at `.recording`, but `demarcate`
            // can succeed in `.recovering` (the queued path returns the
            // current pre-recovery session and waits for the next
            // return-to-`.recording` transition to apply the boundary).
            // Reporting `recording: true / status: "recording"` in the
            // recovering case would lie to the client; mirror what the
            // engine actually says.
            let status = await engine.status
            return DaemonResponse(
                ok: true,
                sessionId: fresh.id.uuidString,
                recording: status == .recording,
                status: status.rawValue
            )
        } catch {
            return DaemonResponse.failure(error.localizedDescription)
        }
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
