import Testing
import AVFoundation
@testable import StenoDaemon

@Suite("SystemAudioSource Tests")
struct SystemAudioSourceTests {

    @Test func hasCorrectProperties() {
        let source = SystemAudioSource()

        #expect(source.name == "System Audio")
        #expect(source.sourceType == .systemAudio)
    }

    @Test func conformsToAudioSourceProtocol() {
        let source: any AudioSource = SystemAudioSource()

        #expect(source.sourceType == .systemAudio)
    }

    @Test func systemAudioErrorEquality() {
        #expect(SystemAudioError.permissionDenied == SystemAudioError.permissionDenied)
        #expect(SystemAudioError.noDisplaysAvailable == SystemAudioError.noDisplaysAvailable)
        #expect(SystemAudioError.streamStartFailed("a") == SystemAudioError.streamStartFailed("a"))
        #expect(SystemAudioError.streamStartFailed("a") != SystemAudioError.streamStartFailed("b"))
    }

    @Test func systemAudioErrorTypes() {
        // Verify all error cases exist and are distinguishable
        let errors: [SystemAudioError] = [
            .noDisplaysAvailable,
            .streamStartFailed("test"),
            .permissionDenied,
        ]

        #expect(errors.count == 3)
    }

    // MARK: - Protocol Contract Tests (using MockAudioSource)

    @Test func protocolStartReturnsFormatAndBuffers() async throws {
        let mock = MockAudioSource(name: "System Audio", sourceType: .systemAudio)
        let source: any AudioSource = mock

        let (buffers, format) = try await source.start()

        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)

        await source.stop()
        _ = buffers
    }

    @Test func protocolStopIsIdempotent() async throws {
        let mock = MockAudioSource()
        _ = try await mock.start()

        await mock.stop()
        await mock.stop()  // Second stop should not crash

        #expect(mock.stopCalled)
    }

    @Test func protocolStartErrorPropagates() async {
        let mock = MockAudioSource()
        mock.errorToThrow = SystemAudioError.permissionDenied

        await #expect(throws: SystemAudioError.self) {
            _ = try await mock.start()
        }
    }

    // NOTE: Integration tests for actual hardware (real ScreenCaptureKit, audio capture)
    // are run manually, not in CI. ScreenCaptureKit requires a display and user permission.
}
