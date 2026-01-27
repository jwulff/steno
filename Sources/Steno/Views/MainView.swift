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

                    var name: CFString = "" as CFString
                    var nameSize = UInt32(MemoryLayout<CFString>.size)
                    status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

                    let deviceName = status == noErr ? name as String : "Unknown Device"

                    var uidAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )

                    var uid: CFString = "" as CFString
                    var uidSize = UInt32(MemoryLayout<CFString>.size)
                    status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

                    let deviceUID = status == noErr ? uid as String : ""

                    devices.append(AudioInputDevice(id: deviceID, name: deviceName, uid: deviceUID))
                }
            }
        }
    }

    return devices
}

/// State container for the view with actual speech service integration.
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

    // Scroll state
    @Published var scrollOffset: Int = 0
    @Published var isLiveMode: Bool = true
    let visibleLines: Int = 15
    let lineWidth: Int = 58  // Characters per line (leaving room for timestamp)

    // Timing for entry grouping
    private var lastEntryTime: Date?
    @Published var partialTimestamp: Date = Date()
    let entryGroupingThreshold: TimeInterval = 5.0  // Start new line if > 5 seconds gap

    // Stabilization timer - treat partial as final if unchanged for this duration
    private var stabilizationWorkItem: DispatchWorkItem?
    private var lastPartialText: String = ""
    private var finalizedTextLength: Int = 0  // Track how much text we've already finalized
    let stabilizationDelay: TimeInterval = 1.5  // Seconds of no change = finalize

    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

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

        // Add partial text if present (with real timestamp)
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
        log("Starting...")
        statusMessage = "Checking permissions..."

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        log("Current permissions - mic: \(micStatus.rawValue), speech: \(speechStatus.rawValue)")

        if micStatus != .authorized {
            log("Requesting microphone access...")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.log("Microphone access: \(granted)")
                if granted {
                    self.requestSpeechAndStart()
                } else {
                    self.errorMessage = "Microphone access denied"
                    self.statusMessage = "Permission denied"
                }
            }
        } else {
            requestSpeechAndStart()
        }
    }

    private func requestSpeechAndStart() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        if speechStatus != .authorized {
            log("Requesting speech recognition access...")
            SFSpeechRecognizer.requestAuthorization { status in
                self.log("Speech recognition status: \(status.rawValue)")
                if status == .authorized {
                    self.beginTranscription()
                } else {
                    self.errorMessage = "Speech recognition denied"
                    self.statusMessage = "Permission denied"
                }
            }
        } else {
            beginTranscription()
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

    private func beginTranscription() {
        log("Beginning transcription...")
        statusMessage = "Starting..."

        if let device = selectedDevice {
            log("Using input device: \(device.name)")
            _ = setAudioInputDevice(device.id)
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current) else {
            log("ERROR: Could not create speech recognizer for current locale")
            errorMessage = "Speech recognizer unavailable for locale"
            return
        }

        guard recognizer.isAvailable else {
            log("ERROR: Speech recognizer not available")
            errorMessage = "Speech recognizer not available"
            return
        }

        log("Speech recognizer available: \(recognizer.locale.identifier)")

        do {
            let audioEngine = AVAudioEngine()
            self.audioEngine = audioEngine

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            log("Audio format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount) channels")

            self.log("Installing audio tap...")
            var lastLogTime = Date()
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, _ in
                request.append(buffer)

                let frameLength = buffer.frameLength
                var maxLevel: Float = 0
                if let channelData = buffer.floatChannelData?[0] {
                    for i in 0..<Int(frameLength) {
                        let level = abs(channelData[i])
                        if level > maxLevel { maxLevel = level }
                    }
                }

                self.audioLevel = maxLevel

                let now = Date()
                if now.timeIntervalSince(lastLogTime) >= 0.5 {
                    lastLogTime = now
                    let levelBar = String(repeating: "█", count: min(20, Int(maxLevel * 100)))
                    self.log("Level: \(String(format: "%.3f", maxLevel)) \(levelBar)")
                }
            }
            self.log("Audio tap installed")

            audioEngine.prepare()
            try audioEngine.start()
            log("Audio engine started")

            isListening = true
            statusMessage = "Recording..."

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                let errorMsg = error?.localizedDescription
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let confidence = result?.bestTranscription.segments.last?.confidence

                if let errorMsg = errorMsg {
                    if errorMsg.lowercased().contains("cancel") {
                        self.log("Recognition stopped (cancelled)")
                        return
                    }
                    self.log("Recognition error: \(errorMsg)")
                    self.errorMessage = errorMsg
                    self.isListening = false
                    self.statusMessage = "Error"
                    return
                }

                guard let text = text else {
                    self.log("No result")
                    return
                }

                self.log("Result: '\(text)' (final: \(isFinal))")

                // Note: isFinal is often never true during continuous recognition
                // We use a stabilization timer instead - if text unchanged for 1.5s, finalize it

                if isFinal {
                    // Rare, but handle it if it happens
                    self.cancelStabilizationTimer()

                    let segment = TranscriptSegment(
                        text: text,
                        timestamp: Date(),
                        duration: 0,
                        confidence: confidence
                    )
                    self.segments.append(segment)

                    let now = Date()
                    let entry = TranscriptEntry(timestamp: now, text: text, isFinal: true)
                    self.entries.append(entry)

                    self.lastEntryTime = now
                    self.lastPartialText = ""
                    self.partialText = ""
                    self.statusMessage = "Recording... (\(self.segments.count) segments)"

                    if self.isLiveMode {
                        self.scrollOffset = 0
                    }
                } else {
                    // Partial result - use stabilization timer
                    // Only show/track the NEW text (after what we've already finalized)
                    let newText: String
                    if self.finalizedTextLength > 0 && text.count > self.finalizedTextLength {
                        let startIndex = text.index(text.startIndex, offsetBy: self.finalizedTextLength)
                        newText = String(text[startIndex...]).trimmingCharacters(in: .whitespaces)
                    } else if self.finalizedTextLength == 0 {
                        newText = text
                    } else {
                        newText = ""
                    }

                    if self.partialText.isEmpty && !newText.isEmpty {
                        self.partialTimestamp = Date()
                    }

                    // Check if the new portion actually changed
                    if newText != self.partialText && !newText.isEmpty {
                        self.lastPartialText = text  // Store full text for finalization
                        self.partialText = newText   // Display only new portion

                        // Reset the timer since we got new content
                        self.startStabilizationTimer()
                    }
                }
            }

            log("Recognition task started")

        } catch {
            log("ERROR starting audio: \(error.localizedDescription)")
            errorMessage = "Audio error: \(error.localizedDescription)"
            statusMessage = "Error"
        }
    }

    private func stopListening() {
        log("Stopping transcription...")
        statusMessage = "Stopping..."

        // Finalize any pending partial text before stopping
        cancelStabilizationTimer()
        if !partialText.isEmpty {
            finalizePartialText()
        }

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        isListening = false
        audioLevel = 0
        lastPartialText = ""
        finalizedTextLength = 0  // Reset for next session
        statusMessage = "Ready"
        log("Stopped")
    }

    func clear() {
        cancelStabilizationTimer()
        segments.removeAll()
        entries.removeAll()
        partialText = ""
        errorMessage = nil
        statusMessage = "Ready"
        scrollOffset = 0
        isLiveMode = true
        lastEntryTime = nil
        partialTimestamp = Date()
        lastPartialText = ""
        finalizedTextLength = 0
    }

    private func cancelStabilizationTimer() {
        stabilizationWorkItem?.cancel()
        stabilizationWorkItem = nil
    }

    private func startStabilizationTimer() {
        cancelStabilizationTimer()

        let textToFinalize = partialText
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only finalize if the text hasn't changed since timer started
            if self.partialText == textToFinalize && !textToFinalize.isEmpty {
                self.finalizePartialText()
            } else {
                self.log("Timer fired but text changed: '\(textToFinalize.prefix(20))...' -> '\(self.partialText.prefix(20))...'")
            }
        }
        stabilizationWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + stabilizationDelay, execute: workItem)
        log("Timer started (\(stabilizationDelay)s) for: '\(textToFinalize.prefix(40))...'")
    }

    private func finalizePartialText() {
        guard !partialText.isEmpty else { return }

        // partialText already contains only the new text (calculated in the callback)
        let newText = partialText

        log("Stabilization timer fired - finalizing: '\(newText)'")

        let now = Date()
        let segment = TranscriptSegment(
            text: newText,
            timestamp: now,
            duration: 0,
            confidence: nil
        )
        segments.append(segment)

        // Create new timestamped entry
        let entry = TranscriptEntry(timestamp: partialTimestamp, text: newText, isFinal: true)
        entries.append(entry)

        // Update how much text we've finalized (use full text length from recognizer)
        finalizedTextLength = lastPartialText.count

        lastEntryTime = now
        partialText = ""  // Clear display of partial
        statusMessage = "Recording... (\(segments.count) segments)"

        // Auto-scroll to bottom if in live mode
        if isLiveMode {
            scrollOffset = 0
        }
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
                Text("- Speech to Text")
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
                } else {
                    Text("○")
                        .foregroundColor(.gray)
                }
                Text(state.statusMessage)
                    .foregroundColor(state.isListening ? .green : .gray)

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

            // Transcript log view
            VStack(alignment: .leading) {
                if state.entries.isEmpty && state.partialText.isEmpty {
                    Text("Press [Start] to begin transcription...")
                        .foregroundColor(.gray)
                        .italic()
                    // Pad to maintain consistent height
                    ForEach(0..<(state.visibleLines - 1), id: \.self) { _ in
                        Text(" ")
                    }
                } else {
                    let lines = state.visibleDisplayLines
                    ForEach(0..<state.visibleLines, id: \.self) { i in
                        if i < lines.count {
                            Text(lines[i])
                                .foregroundColor(lines[i].hasSuffix(" ▌") ? .yellow : .white)
                        } else {
                            Text(" ")
                        }
                    }
                }
            }

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
        .padding(1)
    }

    private func truncateName(_ name: String, max: Int) -> String {
        if name.count <= max {
            return name
        }
        return String(name.prefix(max - 3)) + "..."
    }
}
