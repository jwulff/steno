import Testing
import AVFoundation
@testable import StenoDaemon

@Suite("AudioSource Protocol Tests")
struct AudioSourceProtocolTests {

    @Test func mockSourceHasCorrectProperties() {
        let source = MockAudioSource(name: "Test Source", sourceType: .systemAudio)

        #expect(source.name == "Test Source")
        #expect(source.sourceType == .systemAudio)
    }

    @Test func startReturnsBufferStreamAndFormat() async throws {
        let source = MockAudioSource()
        let (buffers, format) = try await source.start()

        #expect(source.startCalled)
        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)

        // Clean up
        await source.stop()
        _ = buffers  // suppress unused warning
    }

    @Test func stopCleansUpResources() async throws {
        let source = MockAudioSource()
        _ = try await source.start()

        await source.stop()

        #expect(source.stopCalled)
    }

    @Test func startThrowsWhenErrorSet() async {
        let source = MockAudioSource()
        source.errorToThrow = SpeechRecognitionError.audioInputUnavailable

        await #expect(throws: SpeechRecognitionError.self) {
            _ = try await source.start()
        }

        #expect(source.startCalled)
    }

    @Test func buffersReceiveEmittedData() async throws {
        let source = MockAudioSource()
        let (buffers, _) = try await source.start()

        let testBuffer = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: 1024
        )!
        testBuffer.frameLength = 1024

        source.emit(testBuffer)
        source.finish()

        var receivedCount = 0
        for await _ in buffers {
            receivedCount += 1
        }

        #expect(receivedCount == 1)
        await source.stop()
    }

    @Test func microphoneSourceType() {
        let source = MockAudioSource(name: "Mic", sourceType: .microphone)

        #expect(source.sourceType == .microphone)
    }
}
