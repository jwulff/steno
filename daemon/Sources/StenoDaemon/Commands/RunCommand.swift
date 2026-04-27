import ArgumentParser
import Foundation

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the daemon in the foreground"
    )

    @Option(name: .long, help: "Socket path (default: ~/Library/Application Support/Steno/steno.sock)")
    var socketPath: String?

    @Option(name: .long, help: "Database path (default: ~/Library/Application Support/Steno/steno.sqlite)")
    var dbPath: String?

    func run() throws {
        let log = DaemonLogger.daemon

        // 0. Refuse to start on pre-macOS-26 systems. Without this, an old
        // system would spin in launchd's KeepAlive loop forever (U5's backoff
        // doesn't cover misconfigured-host failures). See MacOSVersionGate
        // for why this is a runtime check rather than `#available`.
        let gate = MacOSVersionGate.check(
            currentVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
        if !gate.isSupported, let message = gate.message {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            throw ExitCode.failure
        }

        // 1. Ensure base directory
        try DaemonPaths.ensureBaseDirectory()

        // 2. Acquire PID file
        let pidFile = PIDFile()
        guard try pidFile.acquire() else {
            let (_, existingPID) = pidFile.isRunning()
            print("steno-daemon: another instance is already running (PID \(existingPID ?? 0))")
            throw ExitCode.failure
        }

        let socketPath = self.socketPath
        let dbPath = self.dbPath

        // Launch all async work in a Task, then keep the main RunLoop alive
        // via dispatchMain(). SpeechAnalyzer requires the main RunLoop.
        Task {
            do {
                log.info("Starting steno-daemon (PID \(ProcessInfo.processInfo.processIdentifier))")

                // 3. Initialize database
                let dbURL = dbPath.map { URL(fileURLWithPath: $0) } ?? DaemonPaths.databaseURL
                let dbQueue = try DatabaseConfiguration.makeQueue(at: dbURL)
                let repository = SQLiteTranscriptRepository(dbQueue: dbQueue)

                // 4. Initialize services
                let permissionService = SystemPermissionService()
                let summarizer: SummarizationService = FoundationModelSummarizationService()

                let summaryCoordinator = RollingSummaryCoordinator(
                    repository: repository,
                    summarizer: summarizer
                )

                let audioSourceFactory = DefaultAudioSourceFactory()
                let speechRecognizerFactory = DefaultSpeechRecognizerFactory()

                // 5. Create engine, broadcaster, dispatcher
                let broadcaster = EventBroadcaster()

                let settings = StenoSettings.load()

                // U11: cross-source dedup coordinator runs as a background
                // pass after each segment write, debounced per-session.
                let dedupCoordinator = DedupCoordinator(
                    repository: repository,
                    overlapSeconds: settings.dedupOverlapSeconds,
                    scoreThreshold: settings.dedupScoreThreshold,
                    micPeakThresholdDb: settings.dedupMicPeakThresholdDb
                )

                let engine = RecordingEngine(
                    repository: repository,
                    permissionService: permissionService,
                    summaryCoordinator: summaryCoordinator,
                    audioSourceFactory: audioSourceFactory,
                    speechRecognizerFactory: speechRecognizerFactory,
                    delegate: broadcaster,
                    deviceUIDProvider: { defaultInputDeviceUID() },
                    healThresholdSeconds: settings.healGapSeconds,
                    dedupCoordinator: dedupCoordinator,
                    dedupTriggerDebounce: .seconds(settings.dedupTriggerDebounceSeconds)
                )

                let dispatcher = CommandDispatcher(engine: engine, broadcaster: broadcaster)

                // U6: register IOKit power observer BEFORE auto-start so
                // a willSleep arriving during the orphan sweep is
                // delivered to the actor (which serializes) and not lost.
                // The observer routes its notification port through
                // libdispatch on the main queue (not CFRunLoop, which
                // doesn't pump under `dispatchMain()`).
                let powerObserver = PowerManagementObserver()
                do {
                    try powerObserver.start(target: engine)
                    log.info("Power observer registered (IOKit)")
                } catch {
                    // Non-fatal: the daemon can still record; we just
                    // won't gracefully drain across sleep/wake. Surface
                    // as a warning and continue.
                    log.error("Power observer registration failed: \(error)")
                }

                // U7: register AVAudioEngine config-change observer
                // BEFORE auto-start. Same reasoning as U6: a
                // notification arriving during the orphan sweep should
                // serialize through the actor, not be dropped on the
                // floor. The observer subscribes to
                // `AVAudioEngine.configurationChangeNotification` on
                // `NotificationCenter.default` and trampolines
                // debounced events into `engine.audioConfigurationChanged(...)`.
                // formatProvider awaits the engine's cached mic format
                // so U7's "same UID + same format" cheap-restart path
                // can fire (the previous `{ nil }` placeholder always
                // looked like a format change because lastMicFormat
                // becomes non-nil after start). See PR #35 review
                // (issue 5).
                let deviceObserver = AudioDeviceObserver(
                    deviceUIDProvider: { defaultInputDeviceUID() },
                    formatProvider: { [engine] in await engine.currentMicFormat() }
                )
                do {
                    try deviceObserver.start(target: engine)
                    log.info("Audio device observer registered (AVAudioEngine config-change)")
                } catch {
                    // Non-fatal: the daemon can still record; we just
                    // won't react to AirPods disconnect / USB unplug
                    // until the next user-driven event.
                    log.error("Audio device observer registration failed: \(error)")
                }

                // 5b. Auto-start recording. R1/R9: the daemon must never
                // sit in `idle` after launch. Failure is logged but does
                // NOT crash the daemon — the engine surfaces the error
                // (e.g., mic permission denied) and the user can grant
                // permission and trigger a retry via the TUI. Settings
                // restore the last-known device + systemAudio choice.
                do {
                    _ = try await engine.recoverOrphansAndAutoStart(
                        locale: .current,
                        device: settings.lastDevice,
                        systemAudio: settings.lastSystemAudioEnabled
                    )
                } catch {
                    log.error("Auto-start failed: \(error). Engine remains in error state; awaiting external resume.")
                }

                // 6. Start socket server
                let server = UnixSocketServer()
                let sockPath = socketPath ?? DaemonPaths.socketPath

                server.onCommand = { client, command in
                    await dispatcher.handle(command, from: client)
                }

                server.onClientDisconnected = { clientId in
                    await broadcaster.unsubscribe(clientId)
                }

                try await server.start(at: sockPath)
                log.info("Listening on \(sockPath)")
                print("steno-daemon: listening on \(sockPath)")

                // 7. Await shutdown signal
                for await signal in makeSignalStream() {
                    log.info("Received \(String(describing: signal)), shutting down...")
                    print("steno-daemon: shutting down...")
                    break
                }

                // 8. Graceful shutdown
                powerObserver.stop()
                deviceObserver.stop()
                await engine.stop()
                await server.stop()
                pidFile.release()
                log.info("Shutdown complete")
                Foundation.exit(0)
            } catch {
                pidFile.release()
                log.error("Fatal error: \(error)")
                Foundation.exit(1)
            }
        }

        // Keep the main RunLoop alive — required by SpeechAnalyzer.
        dispatchMain()
    }
}
