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

/// Which panel has keyboard focus.
public enum PanelFocus: Sendable, Equatable {
    case topics
    case transcript
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

    // Topic state
    @Published var topics: [Topic] = []
    @Published var selectedTopicIndex: Int = 0
    @Published var expandedTopicId: UUID? = nil
    @Published var topicScrollOffset: Int = 0
    @Published var focusedPanel: PanelFocus = .topics


    // Dynamic visible lines based on terminal size
    var visibleLines: Int {
        let terminalHeight = getTerminalHeight()
        // Reserve lines for: header(3) + status(2) + dividers(2) + controls(2) + padding(2)
        let reservedLines = 11
        return max(10, terminalHeight - reservedLines)
    }

    var transcriptVisibleLines: Int { visibleLines }

    // Panel widths based on terminal size (30% topics, 70% transcript)
    var topicPanelWidth: Int {
        let terminalWidth = getTerminalWidth()
        return max(20, Int(Double(terminalWidth) * 0.3))
    }

    var transcriptPanelWidth: Int {
        let terminalWidth = getTerminalWidth()
        return max(30, terminalWidth - topicPanelWidth - 3)  // 3 for divider + padding
    }

    var transcriptLineWidth: Int {
        max(20, transcriptPanelWidth - 14)  // room for timestamp prefix
    }

    // Topic panel display lines
    var displayTopicLines: [String] {
        var lines: [String] = []

        if topics.isEmpty {
            lines.append("  No topics yet...")
            lines.append("  Topics appear as you speak")
            return lines
        }

        for (index, topic) in topics.enumerated() {
            let isSelected = index == selectedTopicIndex
            let isExpanded = topic.id == expandedTopicId
            let marker = isSelected ? ">" : " "
            let expandMarker = isExpanded ? "▾" : "▸"

            lines.append("\(marker) \(expandMarker) \(topic.title)")

            if isExpanded {
                let wrappedSummary = wrapText(topic.summary, width: max(10, topicPanelWidth - 6))
                for summaryLine in wrappedSummary {
                    lines.append("    \(summaryLine)")
                }
            }
        }

        return lines
    }

    // Topic visible lines with scroll offset
    var visibleTopicLines: [String] {
        let allLines = displayTopicLines
        guard !allLines.isEmpty else { return [] }

        // Reserve some lines for the header
        let visibleCount = max(5, visibleLines / 2)
        let start = max(0, min(topicScrollOffset, allLines.count - visibleCount))
        let end = min(start + visibleCount, allLines.count)
        return Array(allLines[start..<end])
    }

    // MARK: - Topic Navigation

    func topicMoveUp() {
        guard !topics.isEmpty else { return }
        selectedTopicIndex = max(0, selectedTopicIndex - 1)
        adjustTopicScroll()
    }

    func topicMoveDown() {
        guard !topics.isEmpty else { return }
        selectedTopicIndex = min(topics.count - 1, selectedTopicIndex + 1)
        adjustTopicScroll()
    }

    func toggleTopicExpansion() {
        guard selectedTopicIndex < topics.count else { return }
        let topic = topics[selectedTopicIndex]
        if expandedTopicId == topic.id {
            expandedTopicId = nil
        } else {
            expandedTopicId = topic.id
        }
    }

    func togglePanelFocus() {
        focusedPanel = focusedPanel == .topics ? .transcript : .topics
    }

    private func adjustTopicScroll() {
        let visibleCount = max(5, visibleLines / 2)
        // Count lines up to selected topic to ensure it's visible
        var lineCount = 0
        for (index, topic) in topics.enumerated() {
            if index == selectedTopicIndex {
                break
            }
            lineCount += 1  // topic title line
            if topic.id == expandedTopicId {
                lineCount += wrapText(topic.summary, width: max(10, topicPanelWidth - 6)).count
            }
        }

        if lineCount < topicScrollOffset {
            topicScrollOffset = lineCount
        } else if lineCount >= topicScrollOffset + visibleCount {
            topicScrollOffset = lineCount - visibleCount + 1
        }
    }

    // Timing for partial text display
    @Published var partialTimestamp: Date = Date()

    // Storage components
    private var repository: SQLiteTranscriptRepository?
    private var summaryCoordinator: RollingSummaryCoordinator?
    private var localSummarizer: FoundationModelSummarizationService?
    private var remoteSummarizer: AnthropicSummarizationService?
    private var currentSession: Session?
    private var currentSequenceNumber: Int = 0

    // Model status
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

    // System audio capture components
    @Published var isSystemAudioEnabled: Bool = false
    @Published var systemPartialText: String = ""
    @Published var systemAudioLevel: Float = 0
    @Published var hasUsedSystemAudio: Bool = false  // true once system audio has been enabled in this session
    private var systemAudioSource: SystemAudioSource?
    private var systemRecognizerTask: Task<Void, Never>?
    private var systemAnalyzer: SpeechAnalyzer?
    private var systemTranscriber: SpeechTranscriber?
    private var systemInputBuilder: AsyncStream<AnalyzerInput>.Continuation?

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
            let sourceLabel = hasUsedSystemAudio ? (entry.source == .microphone ? "[You] " : "[Others] ") : ""
            let prefix = "[\(entry.formattedTime)] \(sourceLabel)"
            let wrappedLines = wrapText(entry.text, width: transcriptLineWidth - prefix.count)

            for (i, line) in wrappedLines.enumerated() {
                if i == 0 {
                    lines.append(prefix + line)
                } else {
                    lines.append(String(repeating: " ", count: prefix.count) + line)
                }
            }
        }

        // Add mic partial/volatile text if present
        if !partialText.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeStr = formatter.string(from: partialTimestamp)
            let sourceLabel = hasUsedSystemAudio ? "[You] " : ""
            let prefix = "[\(timeStr)] \(sourceLabel)"
            let wrappedLines = wrapText(partialText, width: transcriptLineWidth - prefix.count)
            for (i, line) in wrappedLines.enumerated() {
                if i == 0 {
                    lines.append(prefix + line + " ▌")  // Show cursor to indicate in-progress
                } else {
                    lines.append(String(repeating: " ", count: prefix.count) + line)
                }
            }
        }

        // Add system audio partial text if present
        if !systemPartialText.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let timeStr = formatter.string(from: Date())
            let prefix = "[\(timeStr)] [Others] "
            let wrappedLines = wrapText(systemPartialText, width: transcriptLineWidth - prefix.count)
            for (i, line) in wrappedLines.enumerated() {
                if i == 0 {
                    lines.append(prefix + line + " ▌")
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

    var canTranscriptScrollUp: Bool {
        !transcriptIsLiveMode && transcriptScrollOffset > 0
    }

    var canTranscriptScrollDown: Bool {
        let totalLines = displayLines.count
        return !transcriptIsLiveMode && transcriptScrollOffset < totalLines - transcriptVisibleLines
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

    /// Testing-only init that skips audio/storage/keyboard setup.
    internal init(forTesting: Bool) {
        // No side effects — used only by tests
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
        // a/A = toggle system audio
        Application.globalKeyHandlers["a"] = { [weak self] in
            self?.toggleSystemAudio()
        }
        Application.globalKeyHandlers["A"] = { [weak self] in
            self?.toggleSystemAudio()
        }
        // j = topic down (when topics panel focused)
        Application.globalKeyHandlers["j"] = { [weak self] in
            guard let self, self.focusedPanel == .topics else { return }
            self.topicMoveDown()
        }
        // k = topic up (when topics panel focused)
        Application.globalKeyHandlers["k"] = { [weak self] in
            guard let self, self.focusedPanel == .topics else { return }
            self.topicMoveUp()
        }
        // Enter = toggle topic expansion (when topics panel focused)
        Application.globalKeyHandlers["\n"] = { [weak self] in
            guard let self, self.focusedPanel == .topics else { return }
            self.toggleTopicExpansion()
        }
        // Tab = toggle panel focus
        Application.globalKeyHandlers["\t"] = { [weak self] in
            self?.togglePanelFocus()
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
        if !result.topics.isEmpty {
            topics = result.topics
        }
        log("Summary updated (\(result.topics.count) topics)")
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
                                                            self.handleSummaryResult(result)
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

        // Stop system audio if active
        stopSystemAudio()

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

    // MARK: - System Audio

    func toggleSystemAudio() {
        guard isListening else {
            log("Cannot toggle system audio: not listening")
            return
        }

        if isSystemAudioEnabled {
            stopSystemAudio()
        } else {
            startSystemAudio()
        }
    }

    private func startSystemAudio() {
        log("Starting system audio capture...")
        hasUsedSystemAudio = true

        let source = SystemAudioSource()
        self.systemAudioSource = source

        // Setup task: create recognizer/analyzer on MainActor, then hand off buffer feeding to background
        Task { [weak self] in
            guard let self else { return }

            do {
                let (buffers, format) = try await source.start()
                await MainActor.run {
                    self.log("[SYS] Tap format: \(format.sampleRate)Hz, \(format.channelCount)ch, interleaved=\(format.isInterleaved), standard=\(format.isStandard)")
                }

                // Create second SpeechTranscriber + SpeechAnalyzer
                let locale = Locale.current
                let sysTranscriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                )
                let sysAnalyzer = SpeechAnalyzer(modules: [sysTranscriber])
                let sysAnalyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [sysTranscriber])

                // Create async stream for feeding audio to analyzer
                let (inputSequence, sysInputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                await MainActor.run {
                    self.systemTranscriber = sysTranscriber
                    self.systemAnalyzer = sysAnalyzer
                    self.systemInputBuilder = sysInputBuilder
                }

                // Set up converter if formats differ
                var converter: AVAudioConverter?
                if let analyzerFmt = sysAnalyzerFormat, format != analyzerFmt {
                    converter = AVAudioConverter(from: format, to: analyzerFmt)
                    await MainActor.run {
                        self.log("[SYS] Created converter: \(format.sampleRate)Hz -> \(analyzerFmt.sampleRate)Hz")
                    }
                }

                // Create audio processor for system audio buffers
                let sysProcessor = AudioTapProcessor(
                    inputBuilder: sysInputBuilder,
                    converter: converter,
                    analyzerFormat: sysAnalyzerFormat,
                    inputSampleRate: format.sampleRate,
                    onLevel: { [weak self] level in
                        DispatchQueue.main.async {
                            self?.systemAudioLevel = level
                        }
                    },
                    onLog: { [weak self] message in
                        DispatchQueue.main.async {
                            self?.log("[SYS] \(message)")
                        }
                    }
                )

                // Listen for results from system audio recognizer (@MainActor since it only handles UI updates)
                let recognizerTask = Task { @MainActor [weak self] in
                    do {
                        for try await result in sysTranscriber.results {
                            guard let self = self else { return }

                            let text = String(result.text.characters)

                            if result.isFinal {
                                self.log("[SYS] FINAL: '\(text)'")

                                if !text.isEmpty {
                                    let segment = TranscriptSegment(
                                        text: text,
                                        timestamp: Date(),
                                        duration: 0,
                                        confidence: nil,
                                        source: .systemAudio
                                    )
                                    self.segments.append(segment)

                                    let entry = TranscriptEntry(
                                        timestamp: Date(),
                                        text: text,
                                        isFinal: true,
                                        source: .systemAudio
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
                                                self.log("[SYS] Saved segment \(self.currentSequenceNumber)")
                                            } catch {
                                                self.log("[SYS] Failed to save segment: \(error)")
                                            }
                                        }
                                    }

                                    self.statusMessage = "Recording... MIC + SYS (\(self.segments.count) segments)"
                                }

                                self.systemPartialText = ""

                                if self.transcriptIsLiveMode {
                                    self.transcriptScrollOffset = 0
                                }
                            } else {
                                self.systemPartialText = text
                            }
                        }
                    } catch {
                        self?.log("[SYS] Recognition error: \(error.localizedDescription)")
                    }
                }

                await MainActor.run {
                    self.systemRecognizerTask = recognizerTask
                }

                // Start the system analyzer
                try await sysAnalyzer.start(inputSequence: inputSequence)
                await MainActor.run {
                    self.log("[SYS] Analyzer started, feeding buffers...")
                }

                // Feed buffers from system audio source to the analyzer (runs on background — NOT MainActor)
                var bufferCount = 0
                for await buffer in buffers {
                    // Diagnostic: check audio levels of first few buffers and periodically
                    if bufferCount < 5 || bufferCount % 500 == 0 {
                        var maxLevel: Float = 0
                        if let data = buffer.floatChannelData?[0] {
                            for i in 0..<min(Int(buffer.frameLength), 512) {
                                maxLevel = max(maxLevel, abs(data[i]))
                            }
                        }
                        let bc = bufferCount
                        let fl = buffer.frameLength
                        let ch = buffer.format.channelCount
                        let sr = buffer.format.sampleRate
                        let il = buffer.format.isInterleaved
                        await MainActor.run {
                            self.log("[SYS] buf#\(bc): \(fl) frames, \(ch)ch \(sr)Hz il=\(il) maxLvl=\(String(format: "%.6f", maxLevel))")
                        }
                    }
                    sysProcessor.handleBuffer(buffer, AVAudioTime(hostTime: mach_absolute_time()))
                    bufferCount += 1
                }

                await MainActor.run {
                    self.log("[SYS] Buffer stream ended after \(bufferCount) buffers")
                }

            } catch let error as SystemAudioError {
                await MainActor.run {
                    self.log("[SYS] System audio error: \(error)")
                    switch error {
                    case .permissionDenied:
                        self.errorMessage = "System audio requires \"Screen & System Audio Recording\" permission. Grant permission in the dialog or via System Settings > Privacy & Security."
                    case .noDisplaysAvailable:
                        self.errorMessage = "System audio unavailable: no display found"
                    case .streamStartFailed(let reason):
                        self.errorMessage = "System audio unavailable: \(reason)"
                    }
                    self.isSystemAudioEnabled = false
                    self.systemAudioSource = nil
                }
            } catch {
                await MainActor.run {
                    self.log("[SYS] Unexpected error: \(error)")
                    self.errorMessage = "System audio error: \(error.localizedDescription)"
                    self.isSystemAudioEnabled = false
                    self.systemAudioSource = nil
                }
            }
        }

        isSystemAudioEnabled = true
        statusMessage = "Recording... MIC + SYS"
    }

    private func stopSystemAudio() {
        guard isSystemAudioEnabled else { return }
        log("Stopping system audio...")

        systemRecognizerTask?.cancel()
        systemRecognizerTask = nil

        systemInputBuilder?.finish()
        systemInputBuilder = nil

        Task {
            await systemAudioSource?.stop()
            await MainActor.run {
                self.systemAudioSource = nil
            }

            do {
                try await systemAnalyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                await MainActor.run {
                    self.log("[SYS] Error finalizing analyzer: \(error)")
                }
            }
        }

        systemAnalyzer = nil
        systemTranscriber = nil
        systemPartialText = ""
        systemAudioLevel = 0
        isSystemAudioEnabled = false

        if isListening {
            statusMessage = "Recording..."
        }

        log("System audio stopped")
    }

    func clear() {
        segments.removeAll()
        entries.removeAll()
        partialText = ""
        systemPartialText = ""
        hasUsedSystemAudio = false
        errorMessage = nil
        statusMessage = "Ready"
        transcriptScrollOffset = 0
        transcriptIsLiveMode = true
        partialTimestamp = Date()
        totalTokensUsed = 0
        isModelProcessing = false
        topics = []
        selectedTopicIndex = 0
        expandedTopicId = nil
        topicScrollOffset = 0
        focusedPanel = .topics
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
            // Header
            HeaderView(state: state)

            // Settings Screen (modal)
            if state.isShowingSettings {
                settingsScreen
            }

            // Status bar
            StatusBarView(state: state)

            // Main content area - split screen
            Text(String(repeating: "─", count: getTerminalWidth()))
                .foregroundColor(.gray)

            HStack(alignment: .top) {
                // LEFT PANEL: Topic Outline (30%)
                TopicPanelView(state: state)
                    .frame(width: Extended(state.topicPanelWidth))

                // Vertical divider
                Text("│")
                    .foregroundColor(.gray)

                // RIGHT PANEL: Live Transcript (70%)
                TranscriptPanelView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Text(String(repeating: "─", count: getTerminalWidth()))
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

            // Keyboard shortcuts
            KeyboardShortcutsView(state: state)
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

    private func maskAPIKey(_ key: String) -> String {
        if key.isEmpty {
            return "(empty)"
        } else if key.count <= 8 {
            return String(repeating: "•", count: key.count)
        } else {
            return String(key.prefix(4)) + String(repeating: "•", count: key.count - 8) + String(key.suffix(4))
        }
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
