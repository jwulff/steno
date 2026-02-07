import SwiftTUI
import Combine
import Foundation
import CoreAudio
import GRDB
@preconcurrency import Speech
@preconcurrency import AVFoundation

/// Get terminal dimensions using ioctl
func getTerminalHeight() -> Int {
    var windowSize = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0 {
        return Int(windowSize.ws_row)
    }
    // Fallback to environment variable or default
    if let lines = ProcessInfo.processInfo.environment["LINES"], let height = Int(lines) {
        return height
    }
    return 24  // Default terminal height
}

func getTerminalWidth() -> Int {
    var windowSize = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0 {
        return Int(windowSize.ws_col)
    }
    // Fallback to environment variable or default
    if let cols = ProcessInfo.processInfo.environment["COLUMNS"], let width = Int(cols) {
        return width
    }
    return 80  // Default terminal width
}

/// Represents an audio input device
struct AudioInputDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// A timestamped transcript entry for the log view
struct TranscriptEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    var text: String
    let isFinal: Bool
    let source: AudioSourceType

    init(timestamp: Date, text: String, isFinal: Bool, source: AudioSourceType = .microphone) {
        self.timestamp = timestamp
        self.text = text
        self.isFinal = isFinal
        self.source = source
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

/// Get list of available audio input devices
func getAudioInputDevices() -> [AudioInputDevice] {
    var devices: [AudioInputDevice] = []

    var propertySize: UInt32 = 0
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0, nil,
        &propertySize
    )

    guard status == noErr else { return devices }

    let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

    status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0, nil,
        &propertySize,
        &deviceIDs
    )

    guard status == noErr else { return devices }

    for deviceID in deviceIDs {
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var inputSize: UInt32 = 0
        status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)

        if status == noErr && inputSize > 0 {
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }

            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPtr)

            if status == noErr {
                var hasInput = false
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferListPtr))
                for buffer in buffers {
                    if buffer.mNumberChannels > 0 {
                        hasInput = true
                        break
                    }
                }

                if hasInput {
                    var nameAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceNameCFString,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )

                    var name: Unmanaged<CFString>?
                    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                    status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

                    let deviceName = status == noErr ? (name?.takeUnretainedValue() as String? ?? "Unknown Device") : "Unknown Device"

                    var uidAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )

                    var uid: Unmanaged<CFString>?
                    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                    status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

                    let deviceUID = status == noErr ? (uid?.takeUnretainedValue() as String? ?? "") : ""

                    devices.append(AudioInputDevice(id: deviceID, name: deviceName, uid: deviceUID))
                }
            }
        }
    }

    return devices
}

/// Handles audio tap callbacks in a thread-safe way
final class AudioTapProcessor: @unchecked Sendable {
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private let onLog: @Sendable (String) -> Void
    private var lastLogTime = Date()
    private let lock = NSLock()
    private let converter: AVAudioConverter?
    private let analyzerFormat: AVAudioFormat?
    private let inputSampleRate: Double

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        converter: AVAudioConverter?,
        analyzerFormat: AVAudioFormat?,
        inputSampleRate: Double,
        onLevel: @escaping @Sendable (Float) -> Void,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        self.inputBuilder = inputBuilder
        self.converter = converter
        self.analyzerFormat = analyzerFormat
        self.inputSampleRate = inputSampleRate
        self.onLevel = onLevel
        self.onLog = onLog
    }

    func handleBuffer(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        // Calculate audio level
        let frameLength = buffer.frameLength
        var maxLevel: Float = 0
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameLength) {
                let sample = abs(channelData[i])
                if sample > maxLevel { maxLevel = sample }
            }
        }

        // Report level
        onLevel(maxLevel)

        // Log periodically
        lock.lock()
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastLogTime) >= 1.0
        if shouldLog {
            lastLogTime = now
        }
        lock.unlock()

        if shouldLog {
            let levelBar = String(repeating: "█", count: min(20, Int(maxLevel * 100)))
            onLog("Level: \(String(format: "%.3f", maxLevel)) \(levelBar)")
        }

        // Convert buffer if needed and feed to analyzer
        let bufferToSend: AVAudioPCMBuffer
        if let converter = converter, let analyzerFormat = analyzerFormat {
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * analyzerFormat.sampleRate / inputSampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outputFrameCapacity) else {
                return
            }
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil {
                return
            }
            bufferToSend = convertedBuffer
        } else {
            bufferToSend = buffer
        }

        inputBuilder.yield(AnalyzerInput(buffer: bufferToSend))
    }
}

/// State container for the view using macOS 26 SpeechAnalyzer API.
class ViewState: ObservableObject, @unchecked Sendable {
    @Published var isListening: Bool = false
    @Published var segments: [TranscriptSegment] = []
    @Published var entries: [TranscriptEntry] = []
    @Published var partialText: String = ""
    @Published var errorMessage: String? = nil
    @Published var statusMessage: String = "Ready"
    @Published var audioLevel: Float = 0
    @Published var availableDevices: [AudioInputDevice] = []
    @Published var selectedDeviceIndex: Int = 0
    @Published var isDownloadingModel: Bool = false
    @Published var downloadProgress: Double = 0

    // Transcript scroll state
    @Published var transcriptScrollOffset: Int = 0
    @Published var transcriptIsLiveMode: Bool = true
    let transcriptLineWidth: Int = 38  // Narrower transcript (leaving room for timestamp)

    // LLM panel scroll state
    @Published var llmScrollOffset: Int = 0
    @Published var llmIsLiveMode: Bool = true
    let llmLineWidth: Int = 50  // LLM output width

    // Dynamic visible lines based on terminal size
    var visibleLines: Int {
        let terminalHeight = getTerminalHeight()
        // Reserve lines for: header(3) + status(2) + dividers(2) + controls(2) + padding(2)
        let reservedLines = 11
        return max(10, terminalHeight - reservedLines)
    }

    var transcriptVisibleLines: Int { visibleLines }
    var llmVisibleLines: Int { visibleLines }

    // Timing for partial text display
    @Published var partialTimestamp: Date = Date()

    // Storage components
    private var repository: SQLiteTranscriptRepository?
    private var summaryCoordinator: RollingSummaryCoordinator?
    private var localSummarizer: FoundationModelSummarizationService?
    private var remoteSummarizer: AnthropicSummarizationService?
    private var currentSession: Session?
    private var currentSequenceNumber: Int = 0

    // Summary display
    @Published var latestSummaryText: String?        // Brief summary (top right)
    @Published var detailedMeetingNotes: String?     // Detailed notes with bullets (bottom right)
    @Published var modelStatusMessage: String?

    // Token usage tracking (Anthropic only)
    @Published var totalTokensUsed: Int = 0

    // Model processing indicator
    @Published var isModelProcessing: Bool = false

    // Settings
    @Published var settings: StenoSettings = StenoSettings.load()
    @Published var isShowingSettings: Bool = false
    @Published var apiKeyInput: String = ""
    @Published var selectedModelIndex: Int = 0
    @Published var isLoadingModels: Bool = false

    // Available Claude models (dynamically fetched)
    @Published var claudeModels: [ClaudeModel] = ViewState.fallbackModels

    // Fallback models if API fetch fails
    static let fallbackModels: [ClaudeModel] = [
        ClaudeModel(id: "claude-3-5-haiku-20241022", displayName: "Claude 3.5 Haiku", createdAt: nil),
        ClaudeModel(id: "claude-3-5-sonnet-20241022", displayName: "Claude 3.5 Sonnet", createdAt: nil),
        ClaudeModel(id: "claude-3-opus-20240229", displayName: "Claude 3 Opus", createdAt: nil),
    ]

    // SpeechAnalyzer components (macOS 26+)
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var recognizerTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var audioTapProcessor: AudioTapProcessor?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var selectedDevice: AudioInputDevice? {
        guard selectedDeviceIndex < availableDevices.count else { return nil }
        return availableDevices[selectedDeviceIndex]
    }

    /// Get wrapped lines for display
    var displayLines: [String] {
        var lines: [String] = []

        for entry in entries {
            let prefix = "[\(entry.formattedTime)] "
            let wrappedLines = wrapText(entry.text, width: transcriptLineWidth - prefix.count)

            for (i, line) in wrappedLines.enumerated() {
                if i == 0 {
                    lines.append(prefix + line)
                } else {
                    lines.append(String(repeating: " ", count: prefix.count) + line)
                }
            }
        }

        // Add partial/volatile text if present
        if !partialText.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeStr = formatter.string(from: partialTimestamp)
            let prefix = "[\(timeStr)] "
            let wrappedLines = wrapText(partialText, width: transcriptLineWidth - prefix.count)
            for (i, line) in wrappedLines.enumerated() {
                if i == 0 {
                    lines.append(prefix + line + " ▌")  // Show cursor to indicate in-progress
                } else {
                    lines.append(String(repeating: " ", count: prefix.count) + line)
                }
            }
        }

        return lines
    }

    /// Get the lines currently visible based on scroll position
    var visibleDisplayLines: [String] {
        let allLines = displayLines
        guard !allLines.isEmpty else { return [] }

        let totalLines = allLines.count

        if transcriptIsLiveMode {
            // Show last N lines
            let start = max(0, totalLines - transcriptVisibleLines)
            return Array(allLines[start..<totalLines])
        } else {
            // Show from scroll offset
            let start = max(0, min(transcriptScrollOffset, totalLines - transcriptVisibleLines))
            let end = min(start + transcriptVisibleLines, totalLines)
            return Array(allLines[start..<end])
        }
    }

    /// Get wrapped LLM content lines for display
    var llmDisplayLines: [String] {
        var lines: [String] = []

        // Add summary
        if let summary = latestSummaryText {
            lines.append("── SUMMARY ──")
            lines.append(contentsOf: wrapText(summary, width: llmLineWidth))
            lines.append("")
        }

        // Add meeting notes
        if let notes = detailedMeetingNotes {
            lines.append("── MEETING NOTES ──")
            lines.append(contentsOf: wrapText(notes, width: llmLineWidth))
        }

        return lines
    }

    /// Get the LLM lines currently visible based on scroll position
    var visibleLLMLines: [String] {
        let allLines = llmDisplayLines
        guard !allLines.isEmpty else { return [] }

        let totalLines = allLines.count

        if llmIsLiveMode {
            // Show from beginning in live mode (LLM content reads top-down)
            let end = min(llmVisibleLines, totalLines)
            return Array(allLines[0..<end])
        } else {
            // Show from scroll offset
            let start = max(0, min(llmScrollOffset, totalLines - llmVisibleLines))
            let end = min(start + llmVisibleLines, totalLines)
            return Array(allLines[start..<end])
        }
    }

    var canTranscriptScrollUp: Bool {
        !transcriptIsLiveMode && transcriptScrollOffset > 0
    }

    var canTranscriptScrollDown: Bool {
        let totalLines = displayLines.count
        return !transcriptIsLiveMode && transcriptScrollOffset < totalLines - transcriptVisibleLines
    }

    var canLLMScrollUp: Bool {
        !llmIsLiveMode && llmScrollOffset > 0
    }

    var canLLMScrollDown: Bool {
        let totalLines = llmDisplayLines.count
        return !llmIsLiveMode && llmScrollOffset < totalLines - llmVisibleLines
    }

    private func wrapText(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [text] }

        var lines: [String] = []

        // Split by newlines first to preserve line breaks
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)

        for paragraph in paragraphs {
            var currentLine = ""
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: false)

            for word in words {
                let wordStr = String(word)
                if currentLine.isEmpty {
                    currentLine = wordStr
                } else if currentLine.count + 1 + wordStr.count <= width {
                    currentLine += " " + wordStr
                } else {
                    lines.append(currentLine)
                    currentLine = wordStr
                }
            }

            if !currentLine.isEmpty {
                lines.append(currentLine)
            } else {
                lines.append("")  // Preserve empty lines
            }
        }

        return lines.isEmpty ? [""] : lines
    }

    // Transcript scroll controls
    func transcriptScrollUp() {
        if transcriptIsLiveMode {
            transcriptIsLiveMode = false
            transcriptScrollOffset = max(0, displayLines.count - transcriptVisibleLines - 1)
        } else if transcriptScrollOffset > 0 {
            transcriptScrollOffset -= 1
        }
    }

    func transcriptScrollDown() {
        guard !transcriptIsLiveMode else { return }
        let maxOffset = max(0, displayLines.count - transcriptVisibleLines)
        if transcriptScrollOffset < maxOffset {
            transcriptScrollOffset += 1
        }
        if transcriptScrollOffset >= maxOffset {
            transcriptJumpToLive()
        }
    }

    func transcriptJumpToLive() {
        transcriptIsLiveMode = true
        transcriptScrollOffset = 0
    }

    // LLM scroll controls
    func llmScrollUp() {
        if llmIsLiveMode {
            llmIsLiveMode = false
            llmScrollOffset = 0  // Start at top when leaving live mode
        } else if llmScrollOffset > 0 {
            llmScrollOffset -= 1
        }
    }

    func llmScrollDown() {
        guard !llmIsLiveMode else { return }
        let maxOffset = max(0, llmDisplayLines.count - llmVisibleLines)
        if llmScrollOffset < maxOffset {
            llmScrollOffset += 1
        }
    }

    func llmJumpToLive() {
        llmIsLiveMode = true
        llmScrollOffset = 0
    }

    init() {
        refreshDevices()
        initializeStorage()
        // Fetch available models if we have an API key
        if settings.effectiveAnthropicAPIKey != nil {
            fetchModels()
        }
        // Register global keyboard shortcuts
        registerKeyboardShortcuts()
        // Auto-start transcription on boot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startListening()
        }
    }

    private func registerKeyboardShortcuts() {
        // Space = toggle start/stop
        Application.globalKeyHandlers[" "] = { [weak self] in
            self?.toggleListening()
        }
        // s/S = settings
        Application.globalKeyHandlers["s"] = { [weak self] in
            self?.openSettings()
        }
        Application.globalKeyHandlers["S"] = { [weak self] in
            self?.openSettings()
        }
        // q/Q = quit
        Application.globalKeyHandlers["q"] = {
            Darwin.exit(0)
        }
        Application.globalKeyHandlers["Q"] = {
            Darwin.exit(0)
        }
        // i/I = cycle input device
        Application.globalKeyHandlers["i"] = { [weak self] in
            self?.selectNextDevice()
        }
        Application.globalKeyHandlers["I"] = { [weak self] in
            self?.selectNextDevice()
        }
        // m/M = cycle model
        Application.globalKeyHandlers["m"] = { [weak self] in
            self?.selectNextModel()
        }
        Application.globalKeyHandlers["M"] = { [weak self] in
            self?.selectNextModel()
        }
    }

    private func initializeStorage() {
        do {
            let dbQueue = try DatabaseConfiguration.makeQueue(at: DatabaseConfiguration.defaultURL)
            repository = SQLiteTranscriptRepository(dbQueue: dbQueue)
            log("Database initialized at: \(DatabaseConfiguration.defaultURL.path)")

            // Initialize both summarizers
            localSummarizer = FoundationModelSummarizationService()
            if let apiKey = settings.effectiveAnthropicAPIKey, !apiKey.isEmpty {
                remoteSummarizer = AnthropicSummarizationService(
                    apiKey: apiKey,
                    model: settings.anthropicModel,
                    onTokenUsage: { [weak self] usage in
                        DispatchQueue.main.async {
                            self?.totalTokensUsed += usage.totalTokens
                        }
                    }
                )
            }

            // Create coordinator with active summarizer
            updateSummaryCoordinator()
            log("Storage and summarization initialized (provider: \(settings.summarizationProvider.displayName))")

            // Check model availability asynchronously
            updateModelStatus()
        } catch {
            log("Failed to initialize storage: \(error)")
            // App continues without persistence
        }
    }

    private func updateSummaryCoordinator() {
        guard let repository else { return }

        let activeSummarizer: SummarizationService
        switch settings.summarizationProvider {
        case .local:
            activeSummarizer = localSummarizer ?? FoundationModelSummarizationService()
        case .anthropic:
            if let remote = remoteSummarizer {
                activeSummarizer = remote
            } else {
                // No API key configured
                activeSummarizer = localSummarizer ?? FoundationModelSummarizationService()
            }
        }

        summaryCoordinator = RollingSummaryCoordinator(
            repository: repository,
            summarizer: activeSummarizer,
            triggerCount: 10
        )
    }

    func handleSummaryResult(_ result: SummaryResult) {
        latestSummaryText = result.briefSummary
        detailedMeetingNotes = result.meetingNotes
        log("Summary updated")
    }

    private func updateModelStatus() {
        Task {
            let message: String?
            switch settings.summarizationProvider {
            case .local:
                if let summarizer = localSummarizer {
                    let reason = await summarizer.availabilityReason
                    message = reason.userMessage
                } else {
                    message = "Local model not initialized"
                }
            case .anthropic:
                if let apiKey = settings.effectiveAnthropicAPIKey, !apiKey.isEmpty {
                    message = nil  // API key configured, ready to go
                } else {
                    message = "Set ANTHROPIC_API_KEY env var or use [Set Key]"
                }
            }

            await MainActor.run {
                self.modelStatusMessage = message
                if let msg = message {
                    self.log("Model status: \(msg)")
                } else {
                    self.log("AI model available (\(self.settings.summarizationProvider.displayName))")
                }
            }
        }
    }

    // MARK: - Settings Screen

    func openSettings() {
        // Find current model index
        if let index = claudeModels.firstIndex(where: { $0.id == settings.anthropicModel }) {
            selectedModelIndex = index
        } else {
            selectedModelIndex = 0
        }
        apiKeyInput = settings.anthropicAPIKey ?? ""
        isShowingSettings = true

        // Fetch latest models if we have an API key
        if settings.effectiveAnthropicAPIKey != nil {
            fetchModels()
        }
    }

    func closeSettings() {
        isShowingSettings = false
    }

    func selectProvider(_ provider: SummarizationProvider) {
        var updatedSettings = settings
        updatedSettings.summarizationProvider = provider
        settings = updatedSettings  // Explicit reassign to trigger @Published
        try? settings.save()
        updateSummaryCoordinator()
        updateModelStatus()
        log("Switched to provider: \(provider.displayName)")
    }

    func selectNextModel() {
        guard !claudeModels.isEmpty else { return }
        selectedModelIndex = (selectedModelIndex + 1) % claudeModels.count
        var updatedSettings = settings
        updatedSettings.anthropicModel = claudeModels[selectedModelIndex].id
        settings = updatedSettings  // Explicit reassign to trigger @Published
        try? settings.save()
        recreateRemoteSummarizer()
        log("Selected model: \(claudeModels[selectedModelIndex].displayName)")
    }

    func selectPreviousModel() {
        guard !claudeModels.isEmpty else { return }
        selectedModelIndex = (selectedModelIndex - 1 + claudeModels.count) % claudeModels.count
        var updatedSettings = settings
        updatedSettings.anthropicModel = claudeModels[selectedModelIndex].id
        settings = updatedSettings  // Explicit reassign to trigger @Published
        try? settings.save()
        recreateRemoteSummarizer()
        log("Selected model: \(claudeModels[selectedModelIndex].displayName)")
    }

    func fetchModels() {
        guard let apiKey = settings.effectiveAnthropicAPIKey, !apiKey.isEmpty else {
            log("No API key, using fallback models")
            return
        }

        isLoadingModels = true
        Task {
            do {
                let models = try await fetchAvailableModels(apiKey: apiKey)
                await MainActor.run {
                    // Filter to only include chat models (exclude embedding models, etc.)
                    self.claudeModels = models.filter { model in
                        model.id.contains("claude")
                    }
                    // Update selected index if current model is in the list
                    if let index = self.claudeModels.firstIndex(where: { $0.id == self.settings.anthropicModel }) {
                        self.selectedModelIndex = index
                    } else if !self.claudeModels.isEmpty {
                        self.selectedModelIndex = 0
                        // Update settings to use first available model
                        var updatedSettings = self.settings
                        updatedSettings.anthropicModel = self.claudeModels[0].id
                        self.settings = updatedSettings
                        try? self.settings.save()
                    }
                    self.isLoadingModels = false
                    self.log("Fetched \(self.claudeModels.count) models from API")
                }
            } catch {
                await MainActor.run {
                    self.isLoadingModels = false
                    self.log("Failed to fetch models: \(error)")
                }
            }
        }
    }

    func saveAPIKey() {
        var updatedSettings = settings
        updatedSettings.anthropicAPIKey = apiKeyInput.isEmpty ? nil : apiKeyInput
        settings = updatedSettings  // Explicit reassign to trigger @Published
        try? settings.save()
        recreateRemoteSummarizer()
        updateModelStatus()
        // Fetch latest models with new API key
        if !apiKeyInput.isEmpty {
            fetchModels()
        }
        log("API key saved")
    }

    private func recreateRemoteSummarizer() {
        if let apiKey = settings.effectiveAnthropicAPIKey, !apiKey.isEmpty {
            remoteSummarizer = AnthropicSummarizationService(
                apiKey: apiKey,
                model: settings.anthropicModel,
                onTokenUsage: { [weak self] usage in
                    DispatchQueue.main.async {
                        self?.totalTokensUsed += usage.totalTokens
                    }
                }
            )
        } else {
            remoteSummarizer = nil
        }
        updateSummaryCoordinator()
    }

    func refreshDevices() {
        availableDevices = getAudioInputDevices()
        log("Found \(availableDevices.count) input devices:")
        for (i, device) in availableDevices.enumerated() {
            log("  [\(i)] \(device.name) (ID: \(device.id))")
        }
    }

    func selectNextDevice() {
        guard !availableDevices.isEmpty else { return }
        selectedDeviceIndex = (selectedDeviceIndex + 1) % availableDevices.count
        log("Selected device: \(selectedDevice?.name ?? "none")")
    }

    func selectPreviousDevice() {
        guard !availableDevices.isEmpty else { return }
        selectedDeviceIndex = (selectedDeviceIndex - 1 + availableDevices.count) % availableDevices.count
        log("Selected device: \(selectedDevice?.name ?? "none")")
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        log("Starting with SpeechAnalyzer API...")
        statusMessage = "Checking permissions..."

        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                self.log("Microphone access granted")
                // Request speech recognition permission (still needed)
                SFSpeechRecognizer.requestAuthorization { status in
                    if status == .authorized {
                        self.log("Speech recognition authorized")
                        Task { @MainActor in
                            await self.beginSpeechAnalyzer()
                        }
                    } else {
                        self.log("Speech recognition denied: \(status.rawValue)")
                        self.errorMessage = "Speech recognition denied"
                        self.statusMessage = "Permission denied"
                    }
                }
            } else {
                self.log("Microphone access denied")
                self.errorMessage = "Microphone access denied"
                self.statusMessage = "Permission denied"
            }
        }
    }

    private func setAudioInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var deviceID = deviceID
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            propertySize,
            &deviceID
        )

        if status == noErr {
            log("Set default input device to ID: \(deviceID)")
            return true
        } else {
            log("Failed to set input device, error: \(status)")
            return false
        }
    }

    @MainActor
    private func beginSpeechAnalyzer() async {
        log("Beginning SpeechAnalyzer transcription...")
        statusMessage = "Initializing..."

        // Create a new session for persistence
        currentSequenceNumber = 0
        if let repository {
            do {
                currentSession = try await repository.createSession(locale: .current)
                log("Created session: \(currentSession?.id.uuidString ?? "nil")")
            } catch {
                log("Failed to create session: \(error)")
            }
        }

        // Set audio input device
        if let device = selectedDevice {
            log("Using input device: \(device.name)")
            _ = setAudioInputDevice(device.id)
        }

        do {
            let locale = Locale.current
            log("Locale: \(locale.identifier)")

            // Check if locale is supported
            let supported = await SpeechTranscriber.supportedLocales
            log("Supported locales: \(supported.map { $0.identifier })")

            guard supported.contains(where: { $0.identifier == locale.identifier || $0.language.languageCode == locale.language.languageCode }) else {
                log("ERROR: Locale not supported")
                errorMessage = "Locale '\(locale.identifier)' not supported"
                statusMessage = "Error"
                return
            }

            // Create transcriber with volatile results for real-time feedback
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],  // Get real-time partial results
                attributeOptions: []
            )
            self.transcriber = transcriber

            // Check if model needs to be downloaded
            let installed = await SpeechTranscriber.installedLocales
            log("Installed locales: \(installed.map { $0.identifier })")

            let isInstalled = installed.contains(where: { $0.identifier == locale.identifier || $0.language.languageCode == locale.language.languageCode })

            if !isInstalled {
                log("Model not installed, checking for download...")
                statusMessage = "Downloading model..."
                isDownloadingModel = true

                // Reserve the locale first
                for reserved in await AssetInventory.reservedLocales {
                    await AssetInventory.release(reservedLocale: reserved)
                }
                try await AssetInventory.reserve(locale: locale)

                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    log("Starting model download...")

                    // Monitor progress
                    Task {
                        while !request.progress.isFinished {
                            await MainActor.run {
                                self.downloadProgress = request.progress.fractionCompleted
                                self.statusMessage = "Downloading: \(Int(self.downloadProgress * 100))%"
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }

                    try await request.downloadAndInstall()
                    log("Model downloaded successfully")
                }

                isDownloadingModel = false
            }

            // Create analyzer with the transcriber module
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            // Get the required audio format
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            self.analyzerFormat = analyzerFormat
            log("Analyzer format: \(analyzerFormat?.sampleRate ?? 0)Hz, \(analyzerFormat?.channelCount ?? 0) channels")

            // Create async stream for feeding audio
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            self.inputBuilder = inputBuilder

            // Start listening for results
            recognizerTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        await MainActor.run {
                            guard let self = self else { return }

                            let text = String(result.text.characters)

                            if result.isFinal {
                                // Final result - add to entries
                                self.log("FINAL: '\(text)'")

                                if !text.isEmpty {
                                    let segment = TranscriptSegment(
                                        text: text,
                                        timestamp: Date(),
                                        duration: 0,
                                        confidence: nil
                                    )
                                    self.segments.append(segment)

                                    let entry = TranscriptEntry(
                                        timestamp: self.partialTimestamp,
                                        text: text,
                                        isFinal: true
                                    )
                                    self.entries.append(entry)

                                    // Persist to database
                                    if let repository = self.repository, let session = self.currentSession {
                                        self.currentSequenceNumber += 1
                                        let storedSegment = StoredSegment.from(
                                            segment,
                                            sessionId: session.id,
                                            sequenceNumber: self.currentSequenceNumber
                                        )
                                        Task {
                                            do {
                                                try await repository.saveSegment(storedSegment)
                                                self.log("Saved segment \(self.currentSequenceNumber)")

                                                // Trigger rolling summary check
                                                if let coordinator = self.summaryCoordinator {
                                                    await MainActor.run {
                                                        self.isModelProcessing = true
                                                    }
                                                    let result = await coordinator.onSegmentSaved(sessionId: session.id)
                                                    await MainActor.run {
                                                        self.isModelProcessing = false
                                                        if let result = result {
                                                            self.latestSummaryText = result.briefSummary
                                                            self.detailedMeetingNotes = result.meetingNotes
                                                            self.log("Summary updated: \(result.briefSummary.prefix(50))...")
                                                        }
                                                    }
                                                }
                                            } catch {
                                                self.log("Failed to save segment: \(error)")
                                            }
                                        }
                                    }

                                    self.statusMessage = "Recording... (\(self.segments.count) segments)"
                                }

                                self.partialText = ""
                                self.partialTimestamp = Date()

                                if self.transcriptIsLiveMode {
                                    self.transcriptScrollOffset = 0
                                }
                            } else {
                                // Volatile/partial result - show as in-progress
                                self.log("PARTIAL: '\(text)'")

                                if self.partialText.isEmpty && !text.isEmpty {
                                    self.partialTimestamp = Date()
                                }
                                self.partialText = text
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        self?.log("Recognition error: \(error.localizedDescription)")
                        if !error.localizedDescription.lowercased().contains("cancel") {
                            self?.errorMessage = error.localizedDescription
                        }
                    }
                }
            }

            // Start the analyzer
            try await analyzer.start(inputSequence: inputSequence)
            log("Analyzer started")

            // Set up audio engine
            let audioEngine = AVAudioEngine()
            self.audioEngine = audioEngine

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            log("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

            // Create converter if formats don't match
            if let analyzerFormat = analyzerFormat, inputFormat != analyzerFormat {
                audioConverter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
                log("Created audio converter")
            }

            // Install tap to capture audio
            // Create audio processor that handles tap callback without isolation issues
            let audioProcessor = AudioTapProcessor(
                inputBuilder: inputBuilder,
                converter: self.audioConverter,
                analyzerFormat: analyzerFormat,
                inputSampleRate: inputFormat.sampleRate,
                onLevel: { [weak self] level in
                    DispatchQueue.main.async {
                        self?.audioLevel = level
                    }
                },
                onLog: { [weak self] message in
                    DispatchQueue.main.async {
                        self?.log(message)
                    }
                }
            )
            self.audioTapProcessor = audioProcessor

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: audioProcessor.handleBuffer)

            audioEngine.prepare()
            try audioEngine.start()
            log("Audio engine started")

            isListening = true
            statusMessage = "Recording..."

        } catch {
            log("ERROR: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            statusMessage = "Error"
        }
    }

    private func stopListening() {
        log("Stopping transcription...")
        statusMessage = "Stopping..."

        // Stop audio engine first
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil

        // Finish the input stream
        inputBuilder?.finish()
        inputBuilder = nil

        // Finalize the analyzer
        Task {
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                log("Analyzer finalized")
            } catch {
                log("Error finalizing analyzer: \(error)")
            }
        }

        // End the session in the database
        if let repository, let session = currentSession {
            Task {
                do {
                    try await repository.endSession(session.id)
                    log("Ended session: \(session.id.uuidString)")
                } catch {
                    log("Failed to end session: \(error)")
                }
            }
        }
        currentSession = nil

        // Cancel recognition task
        recognizerTask?.cancel()
        recognizerTask = nil

        // Clear references
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        audioTapProcessor = nil

        isListening = false
        audioLevel = 0
        statusMessage = "Ready"
        log("Stopped")
    }

    func clear() {
        segments.removeAll()
        entries.removeAll()
        partialText = ""
        errorMessage = nil
        statusMessage = "Ready"
        transcriptScrollOffset = 0
        transcriptIsLiveMode = true
        llmScrollOffset = 0
        llmIsLiveMode = true
        partialTimestamp = Date()
        latestSummaryText = nil
        detailedMeetingNotes = nil
        totalTokensUsed = 0
        isModelProcessing = false
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let logMessage = "[\(timestamp)] \(message)\n"

        let logFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".steno.log")

        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
}

/// Main TUI view for the Steno application.
struct MainView: View {
    @ObservedObject var state = ViewState()

    var body: some View {
        VStack(alignment: .leading) {
            // Header + Settings Group
            Group {
                // Header
                HStack {
                    Text("Steno")
                        .bold()
                    Text("- Speech to Text (SpeechAnalyzer)")
                        .foregroundColor(.gray)
                }

                // Microphone selector
                HStack {
                    Text("Mic:")
                        .foregroundColor(.gray)
                    Button("[ < ]") {
                        state.selectPreviousDevice()
                    }
                    Text(truncateName(state.selectedDevice?.name ?? "No devices", max: 30))
                        .foregroundColor(.cyan)
                    Button("[ > ]") {
                        state.selectNextDevice()
                    }
                }

                // AI status line
                HStack {
                    Text("AI:")
                        .foregroundColor(.gray)
                    Text(state.settings.summarizationProvider.displayName)
                        .foregroundColor(.magenta)

                    if state.settings.summarizationProvider == .anthropic {
                        Text("│")
                            .foregroundColor(.gray)
                        if state.isModelProcessing {
                            Text("⟳")
                                .foregroundColor(.yellow)
                        }
                        Text(formatModelName(state.settings.anthropicModel))
                            .foregroundColor(state.isModelProcessing ? .yellow : .gray)
                        if state.totalTokensUsed > 0 {
                            Text("\(formatTokenCount(state.totalTokensUsed))")
                                .foregroundColor(.cyan)
                        }
                        if state.settings.effectiveAnthropicAPIKey != nil {
                            Text("✓")
                                .foregroundColor(.green)
                        } else {
                            Text("⚠ no key")
                                .foregroundColor(.red)
                        }
                    }

                    Text("│")
                        .foregroundColor(.gray)
                    Button("[ Settings ]") {
                        state.openSettings()
                    }
                }
            }

            // Settings Screen (modal)
            if state.isShowingSettings {
                settingsScreen
            }

            // Status + Scroll Group
            Group {
                // Status line with level meter
                HStack {
                    if state.isListening {
                        Text("●")
                            .foregroundColor(.red)
                    } else if state.isDownloadingModel {
                        Text("↓")
                            .foregroundColor(.yellow)
                    } else {
                        Text("○")
                            .foregroundColor(.gray)
                    }
                    Text(state.statusMessage)
                        .foregroundColor(state.isListening ? .green : (state.isDownloadingModel ? .yellow : .gray))

                    if state.isListening {
                        Text(" |")
                            .foregroundColor(.gray)
                        let levelBars = min(20, Int(state.audioLevel * 100))
                        Text(String(repeating: "█", count: levelBars) + String(repeating: "░", count: 20 - levelBars))
                            .foregroundColor(levelBars > 10 ? .green : (levelBars > 5 ? .yellow : .gray))
                    }
                }

            }

            // Main content area - split screen
            Text(String(repeating: "─", count: 120))
                .foregroundColor(.gray)

            HStack(alignment: .top) {
                // LEFT PANEL: Transcript (narrower)
                VStack(alignment: .leading) {
                    // Transcript header with scroll controls
                    HStack {
                        Text("TRANSCRIPT")
                            .foregroundColor(.cyan)
                            .bold()
                        if state.transcriptIsLiveMode {
                            Text("LIVE")
                                .foregroundColor(.green)
                        } else {
                            Text("SCROLL")
                                .foregroundColor(.yellow)
                        }
                        Spacer()
                        Button("[↑]") { state.transcriptScrollUp() }
                        Button("[↓]") { state.transcriptScrollDown() }
                        if !state.transcriptIsLiveMode {
                            Button("[L]") { state.transcriptJumpToLive() }
                        }
                    }

                    if state.entries.isEmpty && state.partialText.isEmpty {
                        Text("Starting transcription...")
                            .foregroundColor(.gray)
                            .italic()
                    } else {
                        let lines = state.visibleDisplayLines
                        ForEach(0..<lines.count, id: \.self) { i in
                            Text(lines[i])
                                .foregroundColor(lines[i].hasSuffix(" ▌") ? .yellow : .white)
                        }
                    }
                    Spacer()
                }
                .frame(width: 50)

                // Vertical divider
                Text("│")
                    .foregroundColor(.gray)

                // RIGHT PANEL: AI Analysis (wider)
                VStack(alignment: .leading) {
                    // LLM header with scroll controls
                    HStack {
                        Text("AI ANALYSIS")
                            .foregroundColor(.magenta)
                            .bold()
                        if state.isModelProcessing {
                            Text("⟳ processing...")
                                .foregroundColor(.yellow)
                        } else {
                            Text("(\(state.segments.count))")
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button("[↑]") { state.llmScrollUp() }
                        Button("[↓]") { state.llmScrollDown() }
                        if !state.llmIsLiveMode {
                            Button("[L]") { state.llmJumpToLive() }
                        }
                    }

                    // Scrollable LLM content
                    if state.llmDisplayLines.isEmpty {
                        if let modelMsg = state.modelStatusMessage {
                            Text("⚠ \(modelMsg)")
                                .foregroundColor(.yellow)
                        } else {
                            Text("Waiting for segments...")
                                .foregroundColor(.gray)
                                .italic()
                        }
                    } else {
                        let lines = state.visibleLLMLines
                        ForEach(0..<lines.count, id: \.self) { i in
                            let line = lines[i]
                            if line.starts(with: "──") {
                                Text(line)
                                    .foregroundColor(.magenta)
                                    .bold()
                            } else if line.starts(with: "•") || line.starts(with: "-") {
                                Text(line)
                                    .foregroundColor(.white)
                            } else if line.starts(with: "KEY") || line.starts(with: "ACTION") || line.starts(with: "DECISION") || line.starts(with: "QUESTION") {
                                Text(line)
                                    .foregroundColor(.green)
                                    .bold()
                            } else {
                                Text(line)
                                    .foregroundColor(.cyan)
                            }
                        }
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Text(String(repeating: "─", count: 120))
                .foregroundColor(.gray)

            // Error display
            if let errorMessage = state.errorMessage {
                HStack {
                    Text("Error:")
                        .foregroundColor(.red)
                        .bold()
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
            }

            // Keyboard shortcuts status line
            HStack {
                Text("[Space]")
                    .foregroundColor(.cyan)
                Text(state.isListening ? "stop" : "start")
                    .foregroundColor(.gray)
                Text("[s]")
                    .foregroundColor(.cyan)
                Text("settings")
                    .foregroundColor(.gray)
                Text("[i]")
                    .foregroundColor(.cyan)
                Text("input")
                    .foregroundColor(.gray)
                Text("[m]")
                    .foregroundColor(.cyan)
                Text("model")
                    .foregroundColor(.gray)
                Text("[q]")
                    .foregroundColor(.cyan)
                Text("quit")
                    .foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(1)
    }

    // MARK: - Settings Screen

    private var settingsScreen: some View {
        VStack(alignment: .leading) {
            // Header
            Group {
                Text(String(repeating: "═", count: 60))
                    .foregroundColor(.cyan)
                Text("  AI SETTINGS")
                    .foregroundColor(.cyan)
                    .bold()
                Text(String(repeating: "═", count: 60))
                    .foregroundColor(.cyan)
                Text("")
            }

            // Provider selection
            Group {
                Text("Provider:")
                    .foregroundColor(.gray)
                HStack {
                    Button(state.settings.summarizationProvider == .local ? "[●] Apple Intelligence" : "[ ] Apple Intelligence") {
                        state.selectProvider(.local)
                    }
                    .foregroundColor(state.settings.summarizationProvider == .local ? .green : .white)
                }
                HStack {
                    Button(state.settings.summarizationProvider == .anthropic ? "[●] Anthropic Claude" : "[ ] Anthropic Claude") {
                        state.selectProvider(.anthropic)
                    }
                    .foregroundColor(state.settings.summarizationProvider == .anthropic ? .green : .white)
                }
                Text("")
            }

            // Anthropic settings (only shown when Anthropic is selected)
            if state.settings.summarizationProvider == .anthropic {
                anthropicSettingsSection
            }

            // Footer
            Group {
                Text("")
                Text(String(repeating: "═", count: 60))
                    .foregroundColor(.cyan)
                HStack {
                    Button("[ Done ]") {
                        state.closeSettings()
                    }
                    .foregroundColor(.green)
                }
            }
        }
    }

    private var anthropicSettingsSection: some View {
        Group {
            Text(String(repeating: "─", count: 50))
                .foregroundColor(.gray)

            // Model selection
            Text("Model:")
                .foregroundColor(.gray)
            HStack {
                Button("[ < ]") {
                    state.selectPreviousModel()
                }
                if state.isLoadingModels {
                    Text("Loading...")
                        .foregroundColor(.yellow)
                } else if state.selectedModelIndex < state.claudeModels.count {
                    Text(state.claudeModels[state.selectedModelIndex].displayName)
                        .foregroundColor(.magenta)
                } else {
                    Text("No models")
                        .foregroundColor(.red)
                }
                Button("[ > ]") {
                    state.selectNextModel()
                }
            }

            Text("")

            // API Key status
            apiKeySection
        }
    }

    private var apiKeySection: some View {
        Group {
            Text("API Key:")
                .foregroundColor(.gray)
            if let _ = state.settings.effectiveAnthropicAPIKey {
                if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil {
                    Text("  ✓ Using ANTHROPIC_API_KEY env var")
                        .foregroundColor(.green)
                } else {
                    Text("  ✓ Key saved in settings")
                        .foregroundColor(.green)
                }
            } else {
                Text("  ⚠ No API key configured")
                    .foregroundColor(.red)
            }

            Text("")
            Text("Enter key (paste with Cmd+V):")
                .foregroundColor(.gray)
            HStack {
                Text("  ")
                Text(maskAPIKey(state.apiKeyInput))
                    .foregroundColor(.white)
                Text("▌")
                    .foregroundColor(.yellow)
            }
            HStack {
                Button("[ Save Key ]") {
                    state.saveAPIKey()
                }
                Button("[ Clear ]") {
                    state.apiKeyInput = ""
                }
            }
        }
    }

    private func truncateName(_ name: String, max: Int) -> String {
        if name.count <= max {
            return name
        }
        return String(name.prefix(max - 3)) + "..."
    }

    private func maskAPIKey(_ key: String) -> String {
        if key.isEmpty {
            return "(empty)"
        } else if key.count <= 8 {
            return String(repeating: "•", count: key.count)
        } else {
            return String(key.prefix(4)) + String(repeating: "•", count: key.count - 8) + String(key.suffix(4))
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private func formatModelName(_ model: String) -> String {
        // Extract model family and version from model IDs like:
        // - "claude-haiku-4-5-20251001" (new format)
        // - "claude-3-5-haiku-20241022" (old format)
        // - "claude-sonnet-4-20250514"
        let modelLower = model.lowercased()

        // Determine model family
        let family: String
        if modelLower.contains("haiku") {
            family = "haiku"
        } else if modelLower.contains("sonnet") {
            family = "sonnet"
        } else if modelLower.contains("opus") {
            family = "opus"
        } else {
            return model.split(separator: "-").last.map(String.init) ?? model
        }

        // Split and find version numbers (single digits, not 8-digit dates)
        let parts = model.split(separator: "-").map(String.init)
        var major: Int?
        var minor: Int?

        for part in parts {
            // Skip non-numeric parts and dates (8 digits)
            guard let num = Int(part), part.count <= 2 else { continue }
            if major == nil {
                major = num
            } else if minor == nil {
                minor = num
                break
            }
        }

        if let maj = major {
            if let min = minor {
                return "\(family)-\(maj).\(min)"
            }
            return "\(family)-\(maj)"
        }

        return family
    }

    private func wrapSummary(_ text: String) -> [String] {
        wrapText(text, width: 58)
    }

    private func wrapText(_ text: String, width: Int) -> [String] {
        var lines: [String] = []

        // Split by newlines first to preserve line breaks
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)

        for paragraph in paragraphs {
            var currentLine = ""
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: false)

            for word in words {
                let wordStr = String(word)
                if currentLine.isEmpty {
                    currentLine = wordStr
                } else if currentLine.count + 1 + wordStr.count <= width {
                    currentLine += " " + wordStr
                } else {
                    lines.append(currentLine)
                    currentLine = wordStr
                }
            }

            if !currentLine.isEmpty {
                lines.append(currentLine)
            } else {
                lines.append("")  // Preserve empty lines
            }
        }

        return lines.isEmpty ? [""] : lines
    }
}
