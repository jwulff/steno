import Foundation
import Observation

/// The observable application state. Owns the daemon connection, folds the
/// event stream into UI-ready state, reads topics from SQLite, and exposes the
/// user's intents (pause/resume/demarcate/toggle system audio).
///
/// Pure event-folding lives in `apply(_:)` so it can be unit-tested without a
/// live socket; `start()` wires the real launcher + client around it.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Published state

    public private(set) var status: EngineStatus = .connecting
    public private(set) var device: String?
    public private(set) var systemAudioEnabled = false
    public private(set) var availableDevices: [String] = []

    public private(set) var entries: [TranscriptEntry] = []
    /// Live partial text keyed by source (rendered below finalized lines).
    public private(set) var partials: [AudioSource: String] = [:]

    public private(set) var micLevel: Double = 0
    public private(set) var sysLevel: Double = 0

    public private(set) var paused = false
    public private(set) var pausedIndefinitely = false
    public private(set) var pauseExpiresAt: Date?

    public private(set) var modelProcessing = false
    public private(set) var transcription = ComponentReadiness()
    public private(set) var diarization = ComponentReadiness()

    public private(set) var currentSessionId: String?
    public private(set) var topics: [Topic] = []

    /// Most recent non-transient error message, if any (cleared on recovery).
    public private(set) var lastError: String?
    public private(set) var systemAudioParkedNoDisplay = false

    // Daemon process health.
    public private(set) var daemonProcessRunning = false
    public private(set) var daemonPID: Int?
    public private(set) var daemonRestarting = false

    public var defaultPauseSeconds: Double = 1800

    // MARK: - Dependencies

    private let launcher: DaemonLauncher
    private let client: DaemonClient
    private let controller: DaemonController
    private let storeProvider: @Sendable () -> SQLiteReader?
    private var store: SQLiteReader?

    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    /// Per-session first-seen ordering of speaker UUIDs → "Speaker N".
    private var speakerOrder: [String] = []

    public init(
        launcher: DaemonLauncher = DaemonLauncher(),
        client: DaemonClient = DaemonClient(),
        controller: DaemonController = DaemonController(),
        storeProvider: @escaping @Sendable () -> SQLiteReader? = { SQLiteReader() }
    ) {
        self.launcher = launcher
        self.client = client
        self.controller = controller
        self.storeProvider = storeProvider
    }

    // MARK: - Lifecycle

    public func start() {
        reconnectTask?.cancel()
        reconnectTask = Task { await self.connectLoop() }
        startHealthPolling()
    }

    public func stop() {
        eventTask?.cancel()
        reconnectTask?.cancel()
        healthTask?.cancel()
        Task { await client.disconnect() }
    }

    // MARK: - Daemon health

    /// Pure derivation of overall daemon health (testable).
    public static func daemonHealth(
        status: EngineStatus, processRunning: Bool, restarting: Bool
    ) -> DaemonHealth {
        if restarting { return .restarting }
        switch status {
        case .recording, .idle, .starting: return .healthy
        case .paused: return .paused
        case .recovering, .stopping: return .recovering
        case .error: return .error
        case .connecting: return .connecting
        case .disconnected, .unknown:
            return processRunning ? .unreachable : .stopped
        }
    }

    public var daemonHealth: DaemonHealth {
        Self.daemonHealth(
            status: status, processRunning: daemonProcessRunning, restarting: daemonRestarting
        )
    }

    private func startHealthPolling() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshProcessHealth()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func refreshProcessHealth() {
        let pid = controller.runningDaemonPID()
        daemonPID = pid
        daemonProcessRunning = pid != nil
    }

    /// Stop the (possibly stuck) daemon and bring up a fresh one, then
    /// reconnect. Safe to call from any UI affordance.
    public func restartDaemon() {
        guard !daemonRestarting else { return }
        Task {
            daemonRestarting = true
            status = .connecting
            reconnectTask?.cancel()
            eventTask?.cancel()
            await client.disconnect()
            try? await controller.restart()
            refreshProcessHealth()
            daemonRestarting = false
            start()
        }
    }

    private func connectLoop() async {
        var backoff: Duration = .milliseconds(250)
        while !Task.isCancelled {
            status = .connecting
            do {
                try await launcher.ensureRunning()
                try await openSession()
                // Connected; block here until the event stream finishes
                // (connection dropped), then loop to reconnect.
                await eventTask?.value
            } catch {
                status = .disconnected
            }
            if Task.isCancelled { return }
            status = .disconnected
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(5))
        }
    }

    private func openSession() async throws {
        store = storeProvider()

        await client.setConnectionLostHandler { [weak self] in
            Task { @MainActor in self?.handleConnectionLost() }
        }

        // Set the event continuation before connect() so no early events drop.
        let stream = await client.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                await MainActor.run { self?.apply(event) }
            }
        }

        try await client.connect()

        // Prime status + device list.
        if let resp = try? await client.send(.status) { applyStatusResponse(resp) }
        if let resp = try? await client.send(.devices), let devs = resp.devices {
            availableDevices = devs
        }
        if let sid = currentSessionId { reloadTopics(sessionId: sid) }
    }

    private func handleConnectionLost() {
        status = .disconnected
    }

    // MARK: - Intents

    public func pauseTimed() { send(.pause(autoResumeSeconds: defaultPauseSeconds)) }
    public func pauseIndefinite() { send(.pauseIndefinitely) }
    public func resume() { send(.resume) }

    public func togglePause() {
        if paused { resume() } else { pauseTimed() }
    }

    public func demarcate() {
        Task {
            guard let resp = try? await client.send(.demarcate), resp.ok else { return }
            if let sid = resp.sessionId { beginNewSession(sid) }
        }
    }

    public func toggleSystemAudio() {
        send(.reconfigure(systemAudio: !systemAudioEnabled))
    }

    private func send(_ command: DaemonCommand) {
        Task {
            if let resp = try? await client.send(command) { applyStatusResponse(resp) }
        }
    }

    // MARK: - Response folding

    private func applyStatusResponse(_ resp: DaemonResponse) {
        if let s = resp.status { status = EngineStatus(daemonStatus: s) }
        else if let rec = resp.recording { status = rec ? .recording : .idle }
        if let d = resp.device { device = d }
        if let sa = resp.systemAudio { systemAudioEnabled = sa }
        if let p = resp.paused { paused = p }
        if let pi = resp.pausedIndefinitely { pausedIndefinitely = pi }
        pauseExpiresAt = resp.pauseExpiresAt.map { Date(timeIntervalSince1970: $0) }
        if paused { status = .paused }
        if let sid = resp.sessionId, sid != currentSessionId {
            // A new session observed via status poll (e.g. reconnect). Treat
            // this identically to beginNewSession so that (a) speakerOrder
            // doesn't incorrectly re-number existing visible entries, and (b)
            // stale transcript content from the old session is cleared.
            beginNewSession(sid)
        }
    }

    // MARK: - Event folding (pure, testable)

    /// Fold one daemon event into UI state. Side-effect-free except for the
    /// topics SQLite reload (gated behind the injected store).
    public func apply(_ event: DaemonEvent) {
        switch event.event {
        case EventName.partial:
            if let src = event.source.flatMap(AudioSource.init(rawValue:)) {
                partials[src] = event.text ?? ""
            }

        case EventName.segment:
            applySegment(event)

        case EventName.level:
            if let m = event.mic { micLevel = m }
            if let s = event.sys { sysLevel = s }

        case EventName.status:
            if let rec = event.recording {
                status = rec ? .recording : (paused ? .paused : .idle)
            }
            if event.recording == true { lastError = nil }

        case EventName.pauseState:
            paused = event.paused ?? false
            pausedIndefinitely = event.pausedIndefinitely ?? false
            pauseExpiresAt = event.pauseExpiresAt.map { Date(timeIntervalSince1970: $0) }
            status = paused ? .paused : .recording
            if paused { systemAudioParkedNoDisplay = false }

        case EventName.modelProcessing:
            modelProcessing = event.modelProcessing ?? false

        case EventName.modelStatus:
            applyModelStatus(event)

        case EventName.speakerLabel:
            applySpeakerLabel(event)

        case EventName.topics:
            if let sid = currentSessionId { reloadTopics(sessionId: sid) }

        case EventName.error:
            applyError(event)

        default:
            break
        }
    }

    private func applySegment(_ event: DaemonEvent) {
        guard let text = event.text, !text.isEmpty else { return }
        let source = event.source.flatMap(AudioSource.init(rawValue:))
        if let src = source { partials[src] = nil }

        if let sid = event.sessionId, sid != currentSessionId {
            // A fresh session appeared without an explicit demarcate (e.g.
            // daemon restart). Use beginNewSession so speaker labels and
            // entries are reset together — avoids renumbering visible segments.
            beginNewSession(sid)
        }

        let started = event.startedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
        let seq = event.sequenceNumber
        let entry = TranscriptEntry(
            id: entryId(seq: seq, source: source, fallback: event.sessionId),
            kind: .segment,
            source: source,
            text: text,
            startedAt: started,
            sequenceNumber: seq,
            speakerId: event.speakerId
        )

        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            insertSorted(entry)
        }
        if let sp = event.speakerId { registerSpeaker(sp) }
    }

    private func applySpeakerLabel(_ event: DaemonEvent) {
        guard let seq = event.sequenceNumber, let sp = event.speakerId else { return }
        registerSpeaker(sp)
        if let idx = entries.firstIndex(where: { $0.sequenceNumber == seq && $0.kind == .segment }) {
            entries[idx].speakerId = sp
        }
    }

    private func applyModelStatus(_ event: DaemonEvent) {
        let readiness = ComponentReadiness(
            state: ComponentReadiness.State(rawValue: event.state ?? "") ?? .unknown,
            reason: event.reason
        )
        switch event.component {
        case "transcription": transcription = readiness
        case "diarization": diarization = readiness
        default: break
        }
    }

    private func applyError(_ event: DaemonEvent) {
        let message = event.message ?? "Unknown error"

        if message.hasPrefix("SYSTEM_AUDIO_PARKED_NO_DISPLAY") {
            systemAudioParkedNoDisplay = true
            return
        }
        if message.hasPrefix("recovering:") {
            status = .recovering
            if message.contains("display:available") { systemAudioParkedNoDisplay = false }
            return
        }
        if message.hasPrefix("healed:") {
            if status == .recovering { status = .recording }
            return
        }
        if message.hasPrefix("recovery_exhausted:") {
            status = .error
            lastError = message
            return
        }
        // Generic error.
        if event.transient == true { return }
        lastError = message
    }

    // MARK: - Helpers

    private func beginNewSession(_ sid: String) {
        currentSessionId = sid
        speakerOrder.removeAll()
        topics = []
        entries.append(
            TranscriptEntry(
                id: "boundary-\(sid)",
                kind: .sessionBoundary,
                source: nil,
                text: "",
                startedAt: Date()
            )
        )
    }

    private func registerSpeaker(_ id: String) {
        if !speakerOrder.contains(id) { speakerOrder.append(id) }
    }

    /// "Speaker N" label for a speaker UUID, by per-session first-seen order.
    public func speakerLabel(for id: String) -> String {
        let n = (speakerOrder.firstIndex(of: id) ?? speakerOrder.count) + 1
        return "Speaker \(n)"
    }

    private func entryId(seq: Int?, source: AudioSource?, fallback: String?) -> String {
        if let seq { return "seg-\(seq)-\(source?.rawValue ?? "?")" }
        return "seg-\(fallback ?? "x")-\(UUID().uuidString)"
    }

    private func insertSorted(_ entry: TranscriptEntry) {
        // Newest at the end; keep chronological by startedAt then sequence.
        let idx = entries.firstIndex { existing in
            if existing.startedAt == entry.startedAt {
                return (existing.sequenceNumber ?? .max) > (entry.sequenceNumber ?? .max)
            }
            return existing.startedAt > entry.startedAt
        }
        if let idx { entries.insert(entry, at: idx) } else { entries.append(entry) }
    }

    private func reloadTopics(sessionId: String) {
        guard let store else { return }
        // Always assign (even an empty result) so stale topics from a prior
        // session don't remain visible when the new session has no topics yet.
        topics = store.topics(sessionId: sessionId)
    }

    /// Ordered partial lines for rendering (microphone first).
    public var orderedPartials: [(source: AudioSource, text: String)] {
        [AudioSource.microphone, .systemAudio].compactMap { src in
            guard let t = partials[src], !t.isEmpty else { return nil }
            return (src, t)
        }
    }
}
