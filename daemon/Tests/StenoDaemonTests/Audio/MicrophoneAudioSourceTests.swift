import Testing
@preconcurrency import AVFoundation
@testable import StenoDaemon

/// Tests for U7's `MicrophoneAudioSource`.
///
/// The class wraps `AVAudioEngine` and exposes the same
/// `(buffers, format, stop)` tuple shape that
/// `DefaultAudioSourceFactory.makeMicrophoneSource(device:)` historically
/// returned. We can't reliably exercise the actual AVAudioEngine in CI
/// (no microphone, no permissions, no entitlements), but we can verify:
/// - the lifecycle methods don't crash on a fresh instance
/// - `currentDeviceUID()` reflects the injected provider
/// - `currentFormat()` is `nil` before start and cleared after stop
/// - the device-UID provider is invoked at start time (not at init time)
///   so a subsequent system change is observable
/// - a `device` that no input device matches is rejected *before* any
///   `AVAudioEngine` is built, so the failure is reachable in CI
@Suite("MicrophoneAudioSource Tests (U7)")
struct MicrophoneAudioSourceTests {

    // MARK: - Provider injection

    @Test("currentDeviceUID is nil before start()")
    func uidNilBeforeStart() {
        let mic = MicrophoneAudioSource(deviceUIDProvider: { "BuiltInMic" })
        #expect(mic.currentDeviceUID() == nil)
    }

    @Test("currentFormat is nil before start()")
    func formatNilBeforeStart() {
        let mic = MicrophoneAudioSource(deviceUIDProvider: { "BuiltInMic" })
        #expect(mic.currentFormat() == nil)
    }

    @Test("Provider is captured but not invoked until start()")
    func providerInvokedLazily() async {
        nonisolated(unsafe) var calls = 0
        let mic = MicrophoneAudioSource(deviceUIDProvider: {
            calls += 1
            return "BuiltInMic"
        })
        // No start() — provider must not have been invoked yet.
        #expect(calls == 0)
        // Reading the cached UID also does not invoke the provider.
        _ = mic.currentDeviceUID()
        #expect(calls == 0)
    }

    @Test("stop() on never-started source is a no-op (no crash)")
    func stopWithoutStart() async {
        let mic = MicrophoneAudioSource(deviceUIDProvider: { "BuiltInMic" })
        await mic.stop()
        #expect(mic.currentDeviceUID() == nil)
        #expect(mic.currentFormat() == nil)
    }

    // MARK: - Device selection (#104)

    @Test("start(device:) throws when the requested device does not exist")
    func unknownDeviceThrows() async {
        let enumerator = MockAudioInputDeviceEnumerator(devices: [
            AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")
        ])
        let mic = MicrophoneAudioSource(
            deviceUIDProvider: { "BuiltInMicrophoneDevice" },
            deviceEnumerator: enumerator
        )

        await #expect(throws: MicrophoneAudioSourceError.self) {
            _ = try await mic.start(device: "Blue Yeti")
        }
    }

    @Test("The unknown-device error names the device and lists what is available")
    func unknownDeviceErrorIsActionable() async {
        let enumerator = MockAudioInputDeviceEnumerator(devices: [
            AudioInputDevice(id: 41, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone"),
            AudioInputDevice(id: 77, uid: "bt:1", name: "soundcore P30i")
        ])
        let mic = MicrophoneAudioSource(
            deviceUIDProvider: { "BuiltInMicrophoneDevice" },
            deviceEnumerator: enumerator
        )

        do {
            _ = try await mic.start(device: "Blue Yeti")
            Issue.record("start(device:) should have thrown")
        } catch let error as MicrophoneAudioSourceError {
            #expect(error == .deviceNotFound(
                requested: "Blue Yeti",
                available: ["MacBook Air Microphone", "soundcore P30i"]
            ))
            let message = error.localizedDescription
            #expect(message.contains("Blue Yeti"))
            #expect(message.contains("soundcore P30i"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Resolution failure happens before any engine is built")
    func failsBeforeTouchingTheEngine() async {
        // Nothing was started, so nothing may be left behind. This also
        // documents why the check is ordered first: an AVAudioEngine
        // cannot be constructed in CI, so a later check would make this
        // path untestable.
        let mic = MicrophoneAudioSource(
            deviceUIDProvider: { "BuiltInMicrophoneDevice" },
            deviceEnumerator: MockAudioInputDeviceEnumerator(devices: [])
        )
        _ = try? await mic.start(device: "Anything")
        #expect(mic.currentFormat() == nil)
        #expect(mic.currentDeviceUID() == nil)
    }

    @Test("A pinned device reports its own UID, not the system default's")
    func pinnedDeviceUIDWins() {
        let pinned = AudioInputDevice(id: 77, uid: "bt:1", name: "soundcore P30i")
        let uid = MicrophoneAudioSource.effectiveDeviceUID(
            pinned: pinned,
            fallback: { "BuiltInMicrophoneDevice" }
        )
        #expect(uid == "bt:1")
    }

    @Test("With no pinned device the system default UID is reported")
    func unpinnedFallsBackToDefault() {
        let uid = MicrophoneAudioSource.effectiveDeviceUID(
            pinned: nil,
            fallback: { "BuiltInMicrophoneDevice" }
        )
        #expect(uid == "BuiltInMicrophoneDevice")
    }
}
