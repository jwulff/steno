import Testing
import AVFoundation
import Foundation
@testable import StenoDaemon

/// Tests for device enumeration and the sustained-silence warning (#104).
///
/// Before this change `availableDevices()` was a stub returning `[]`, so
/// `{"cmd":"devices"}` always answered with an empty list and a client had
/// no way to learn a valid name for `{"cmd":"start","device":"..."}`.
@Suite("Device Selection Tests")
struct DeviceSelectionTests {

    // MARK: - Helpers

    @MainActor
    private func makeEngine(
        enumerator: MockAudioInputDeviceEnumerator = MockAudioInputDeviceEnumerator(),
        micSilenceWarnAfter: Duration = .seconds(30),
        audioFactory: MockAudioSourceFactory? = nil,
        delegate: MockRecordingEngineDelegate? = nil
    ) async -> (
        engine: RecordingEngine,
        audioFactory: MockAudioSourceFactory,
        delegate: MockRecordingEngineDelegate
    ) {
        let repo = MockTranscriptRepository()
        let af = audioFactory ?? MockAudioSourceFactory()
        let del = delegate ?? MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: MockSummarizationService(),
            triggerCount: 100,
            timeThreshold: 3600
        )
        let engine = RecordingEngine(
            repository: repo,
            permissionService: MockPermissionService(),
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: MockSpeechRecognizerFactory(),
            delegate: del,
            backoffSleep: { _ in /* no wait */ },
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0,
            deviceEnumerator: enumerator,
            micSilenceWarnAfter: micSilenceWarnAfter
        )
        return (engine, af, del)
    }

    private func waitFor(
        timeout: Duration = .seconds(3),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        _ = timeout
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func silentBuffer(format: AVAudioFormat, frames: AVAudioFrameCount = 512) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // AVAudioPCMBuffer is zero-filled on allocation; leaving it that
        // way is the point — this is the "recording nothing" case.
        return buffer
    }

    private func loudBuffer(format: AVAudioFormat, frames: AVAudioFrameCount = 512) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { channel[i] = 0.5 }
        }
        return buffer
    }

    // MARK: - Enumeration

    @Test("availableDevices reports every Core Audio input")
    func enumeratesInputs() async {
        let enumerator = MockAudioInputDeviceEnumerator(
            devices: [
                AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone"),
                AudioInputDevice(id: 77, uid: "bt:1", name: "soundcore P30i")
            ],
            defaultUID: "bt:1"
        )
        let (engine, _, _) = await makeEngine(enumerator: enumerator)

        let devices = await engine.availableDevices()

        #expect(devices.map(\.name) == ["MacBook Air Microphone", "soundcore P30i"])
        #expect(devices.map(\.id) == ["BuiltInMicrophoneDevice", "bt:1"])
    }

    @Test("availableDevices flags the system default input")
    func marksDefault() async {
        let enumerator = MockAudioInputDeviceEnumerator(
            devices: [
                AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone"),
                AudioInputDevice(id: 77, uid: "bt:1", name: "soundcore P30i")
            ],
            defaultUID: "bt:1"
        )
        let (engine, _, _) = await makeEngine(enumerator: enumerator)

        let devices = await engine.availableDevices()

        #expect(devices.first(where: { $0.isDefault })?.name == "soundcore P30i")
        #expect(devices.filter(\.isDefault).count == 1)
    }

    @Test("availableDevices returns an empty list when there are no inputs")
    func noInputs() async {
        let (engine, _, _) = await makeEngine()
        #expect(await engine.availableDevices().isEmpty)
    }

    @Test("availableDevices flags nothing when the default cannot be resolved")
    func unknownDefault() async {
        let enumerator = MockAudioInputDeviceEnumerator(
            devices: [AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")],
            defaultUID: nil
        )
        let (engine, _, _) = await makeEngine(enumerator: enumerator)
        #expect(await engine.availableDevices().allSatisfy { !$0.isDefault })
    }

    // MARK: - Silence warning

    @Test("Sustained digital silence raises a warning while recording")
    func warnsOnSustainedSilence() async throws {
        let (engine, _, delegate) = await makeEngine(micSilenceWarnAfter: .milliseconds(300))
        try await engine.start()

        let warned = await waitFor {
            await !delegate.audioSilentReports.isEmpty
        }
        #expect(warned, "expected an audioSilent event after sustained zero levels")

        let report = await delegate.audioSilentReports.first
        #expect(report?.source == .microphone)
        #expect((report?.seconds ?? 0) >= 0.3)

        await engine.stop()
    }

    @Test("The silence warning fires once, not once per throttle tick")
    func warnsOnce() async throws {
        let (engine, _, delegate) = await makeEngine(micSilenceWarnAfter: .milliseconds(200))
        try await engine.start()

        _ = await waitFor { await !delegate.audioSilentReports.isEmpty }
        try await Task.sleep(for: .milliseconds(600))

        #expect(await delegate.audioSilentReports.count == 1)

        await engine.stop()
    }

    @Test("Audible input suppresses the silence warning")
    func audibleInputSuppressesWarning() async throws {
        let af = MockAudioSourceFactory()
        let (engine, _, delegate) = await makeEngine(
            micSilenceWarnAfter: .milliseconds(300),
            audioFactory: af
        )
        try await engine.start()

        // Keep feeding audio for longer than the silence threshold.
        for _ in 0..<12 {
            af.emitMicBuffer(loudBuffer(format: af.micFormat))
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await delegate.audioSilentReports.isEmpty)

        await engine.stop()
    }

    @Test("Silent buffers still count as silence")
    func silentBuffersAreSilence() async throws {
        let af = MockAudioSourceFactory()
        let (engine, _, delegate) = await makeEngine(
            micSilenceWarnAfter: .milliseconds(300),
            audioFactory: af
        )
        try await engine.start()

        for _ in 0..<12 {
            af.emitMicBuffer(silentBuffer(format: af.micFormat))
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await !delegate.audioSilentReports.isEmpty)

        await engine.stop()
    }

    // MARK: - Pinned device vs. the system default

    @Test("A pinned session ignores a change to the system default input")
    func pinnedSessionIgnoresDefaultChange() async throws {
        let pinned = AudioInputDevice(id: 92, uid: "usb:1", name: "Scarlett Solo USB")
        let enumerator = MockAudioInputDeviceEnumerator(
            devices: [
                AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone"),
                pinned
            ],
            defaultUID: "BuiltInMicrophoneDevice"
        )
        let af = MockAudioSourceFactory()
        let (engine, _, delegate) = await makeEngine(
            enumerator: enumerator,
            audioFactory: af
        )
        try await engine.start(device: "Scarlett Solo USB")
        let createsAfterStart = af.micCreateCount

        // The user plugs in AirPods and macOS makes them the default
        // input. Nothing about the pinned Scarlett changed.
        await engine.handleAudioDeviceChange(deviceUID: "airpods:1", format: af.micFormat)
        _ = await waitFor { await af.micCreateCount > createsAfterStart }

        let reasons = await delegate.recoveringReasons
        #expect(!reasons.contains { $0.hasPrefix("device-change:uid:") })

        await engine.stop()
    }

    @Test("A pinned device that disappears is still treated as a device change")
    func pinnedDeviceVanishing() async throws {
        let pinned = AudioInputDevice(id: 92, uid: "usb:1", name: "Scarlett Solo USB")
        let enumerator = MockAudioInputDeviceEnumerator(
            devices: [
                AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone"),
                pinned
            ],
            defaultUID: "usb:1"
        )
        let af = MockAudioSourceFactory()
        let (engine, _, delegate) = await makeEngine(
            enumerator: enumerator,
            audioFactory: af
        )
        try await engine.start(device: "Scarlett Solo USB")

        // The interface is unplugged: it is gone from the device list
        // and the default has fallen back to the built-in mic.
        enumerator.devices = [
            AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")
        ]
        enumerator.defaultUID = "BuiltInMicrophoneDevice"
        await engine.handleAudioDeviceChange(
            deviceUID: "BuiltInMicrophoneDevice",
            format: af.micFormat
        )

        let sawUIDChange = await waitFor {
            await delegate.recoveringReasons.contains {
                $0.hasPrefix("device-change:uid:")
            }
        }
        #expect(sawUIDChange)

        await engine.stop()
    }

    @Test("The requested device is passed through to the audio source")
    func devicePassedThrough() async throws {
        let af = MockAudioSourceFactory()
        let (engine, _, _) = await makeEngine(audioFactory: af)

        try await engine.start(device: "soundcore P30i")

        #expect(af.lastDevice == "soundcore P30i")

        await engine.stop()
    }
}
