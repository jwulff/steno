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
}
