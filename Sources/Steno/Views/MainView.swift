import SwiftTUI
import Combine
import Foundation
import CoreAudio
@preconcurrency import Speech
@preconcurrency import AVFoundation

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

    // Scroll state
    @Published var scrollOffset: Int = 0
    @Published var isLiveMode: Bool = true
    let visibleLines: Int = 15
    let lineWidth: Int = 58  // Characters per line (leaving room for timestamp)

    // Timing for partial text display
    @Published var partialTimestamp: Date = Date()

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
            let wrappedLines = wrapText(entry.text, width: lineWidth - prefix.count)

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
            let wrappedLines = wrapText(partialText, width: lineWidth - prefix.count)
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

        if isLiveMode {
            // Show last N lines
            let start = max(0, totalLines - visibleLines)
            return Array(allLines[start..<totalLines])
        } else {
            // Show from scroll offset
            let start = max(0, min(scrollOffset, totalLines - visibleLines))
            let end = min(start + visibleLines, totalLines)
            return Array(allLines[start..<end])
        }
    }

    var canScrollUp: Bool {
        !isLiveMode && scrollOffset > 0
    }

    var canScrollDown: Bool {
        let totalLines = displayLines.count
        return !isLiveMode && scrollOffset < totalLines - visibleLines
    }

    private func wrapText(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [text] }

        var lines: [String] = []
        var currentLine = ""

        let words = text.split(separator: " ", omittingEmptySubsequences: false)

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
        }

        return lines.isEmpty ? [""] : lines
    }

    func scrollUp() {
        if isLiveMode {
            isLiveMode = false
            scrollOffset = max(0, displayLines.count - visibleLines - 1)
        } else if scrollOffset > 0 {
            scrollOffset -= 1
        }
    }

    func scrollDown() {
        guard !isLiveMode else { return }
        let maxOffset = max(0, displayLines.count - visibleLines)
        if scrollOffset < maxOffset {
            scrollOffset += 1
        }
        // Jump back to live if at bottom
        if scrollOffset >= maxOffset {
            jumpToLive()
        }
    }

    func jumpToLive() {
        isLiveMode = true
        scrollOffset = 0
    }

    init() {
        refreshDevices()
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

                                    self.statusMessage = "Recording... (\(self.segments.count) segments)"
                                }

                                self.partialText = ""
                                self.partialTimestamp = Date()

                                if self.isLiveMode {
                                    self.scrollOffset = 0
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
        scrollOffset = 0
        isLiveMode = true
        partialTimestamp = Date()
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

            // Scroll indicator
            HStack {
                if state.isLiveMode {
                    Text("LIVE")
                        .foregroundColor(.green)
                        .bold()
                } else {
                    Text("PAUSED - ↑↓ scroll")
                        .foregroundColor(.yellow)
                    Button("[ LIVE ]") {
                        state.jumpToLive()
                    }
                }
            }

            // Divider
            Text(String(repeating: "─", count: 60))
                .foregroundColor(.gray)

            // Transcript log view (expands to fill available space)
            VStack(alignment: .leading) {
                if state.entries.isEmpty && state.partialText.isEmpty {
                    Text("Press [Start] to begin transcription...")
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
            .frame(maxHeight: .infinity)

            // Divider
            Text(String(repeating: "─", count: 60))
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

            // Control buttons
            HStack {
                Button(state.isListening ? "[ Stop ]" : "[ Start ]") {
                    state.toggleListening()
                }

                Text(" ")

                Button("[ ↑ ]") {
                    state.scrollUp()
                }

                Button("[ ↓ ]") {
                    state.scrollDown()
                }

                Text(" ")

                Button("[ Clear ]") {
                    state.clear()
                }

                Text(" ")

                Button("[ Quit ]") {
                    Darwin.exit(0)
                }
            }

                Text("Tab=navigate | ↑↓=scroll | Log: ~/.steno.log")
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(1)
    }

    private func truncateName(_ name: String, max: Int) -> String {
        if name.count <= max {
            return name
        }
        return String(name.prefix(max - 3)) + "..."
    }
}
