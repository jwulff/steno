import ArgumentParser
import Foundation

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the daemon in the foreground"
    )

    @Option(name: .long, help: "Socket path (default: ~/Library/Application Support/Steno/steno.sock)")
    var socketPath: String?

    @Option(name: .long, help: "Database path (default: ~/Library/Application Support/Steno/steno.sqlite)")
    var dbPath: String?

    func run() async throws {
        let log = DaemonLogger.daemon

        // 1. Ensure base directory
        try DaemonPaths.ensureBaseDirectory()

        // 2. Acquire PID file
        let pidFile = PIDFile()
        guard try pidFile.acquire() else {
            let (_, existingPID) = pidFile.isRunning()
            print("steno-daemon: another instance is already running (PID \(existingPID ?? 0))")
            throw ExitCode.failure
        }
        defer { pidFile.release() }

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

        let engine = RecordingEngine(
            repository: repository,
            permissionService: permissionService,
            summaryCoordinator: summaryCoordinator,
            audioSourceFactory: audioSourceFactory,
            speechRecognizerFactory: speechRecognizerFactory,
            delegate: broadcaster
        )

        let dispatcher = CommandDispatcher(engine: engine, broadcaster: broadcaster)

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
        await engine.stop()
        await server.stop()
        log.info("Shutdown complete")
    }
}
