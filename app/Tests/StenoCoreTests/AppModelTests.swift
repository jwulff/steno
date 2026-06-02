import Testing
import Foundation
@testable import StenoCore

@MainActor
struct AppModelTests {

    private func makeModel() -> AppModel {
        // storeProvider returns nil → no SQLite dependency in these tests.
        AppModel(storeProvider: { nil })
    }

    @Test func partialThenSegmentClearsPartial() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "partial", text: "hel", source: "microphone"))
        #expect(m.partials[.microphone] == "hel")

        m.apply(DaemonEvent(event: "segment", text: "hello", source: "microphone",
                            sequenceNumber: 1, startedAt: 100))
        #expect(m.partials[.microphone] == nil)
        #expect(m.entries.count == 1)
        #expect(m.entries.first?.text == "hello")
    }

    @Test func levelEventUpdatesMeters() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "level", mic: 0.6, sys: 0.3))
        #expect(m.micLevel == 0.6)
        #expect(m.sysLevel == 0.3)
    }

    @Test func segmentsSortChronologically() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "segment", text: "second", source: "microphone",
                            sequenceNumber: 2, startedAt: 200))
        m.apply(DaemonEvent(event: "segment", text: "first", source: "microphone",
                            sequenceNumber: 1, startedAt: 100))
        #expect(m.entries.map(\.text) == ["first", "second"])
    }

    @Test func pauseStateEventSetsPausedAndExpiry() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "pause_state", paused: true,
                            pausedIndefinitely: false, pauseExpiresAt: 1700001800))
        #expect(m.paused)
        #expect(m.status == .paused)
        #expect(m.pauseExpiresAt == Date(timeIntervalSince1970: 1700001800))
    }

    @Test func speakerLabelAppliesToExistingSegment() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "segment", text: "hi", source: "microphone",
                            sequenceNumber: 5, startedAt: 100))
        m.apply(DaemonEvent(event: "speaker_label", sequenceNumber: 5, speakerId: "uuid-A"))
        #expect(m.entries.first?.speakerId == "uuid-A")
        #expect(m.speakerLabel(for: "uuid-A") == "Speaker 1")
    }

    @Test func speakerLabelsNumberByFirstSeen() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "speaker_label", sequenceNumber: 1, speakerId: "A"))
        m.apply(DaemonEvent(event: "speaker_label", sequenceNumber: 2, speakerId: "B"))
        #expect(m.speakerLabel(for: "A") == "Speaker 1")
        #expect(m.speakerLabel(for: "B") == "Speaker 2")
    }

    @Test func transcriptionUnavailableRecorded() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "model_status", component: "transcription",
                            state: "unavailable", reason: "Neural Engine required"))
        #expect(m.transcription.state == .unavailable)
        #expect(m.transcription.reason == "Neural Engine required")
    }

    @Test func recoveringErrorSetsStatusNotLastError() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "error", message: "recovering: display not available",
                            transient: true))
        #expect(m.status == .recovering)
        #expect(m.lastError == nil)
    }

    @Test func systemAudioParkedSetsFlag() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "error",
                            message: "SYSTEM_AUDIO_PARKED_NO_DISPLAY: waiting for display",
                            transient: true))
        #expect(m.systemAudioParkedNoDisplay)
    }

    @Test func nonTransientErrorSurfaces() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "error", message: "disk full", transient: false))
        #expect(m.lastError == "disk full")
    }

    @Test func transientGenericErrorDoesNotSurface() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "error", message: "blip", transient: true))
        #expect(m.lastError == nil)
    }

    @Test func recoveryExhaustedSetsErrorState() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "error",
                            message: "recovery_exhausted: MIC_OR_SCREEN_PERMISSION_REVOKED",
                            transient: false))
        #expect(m.status == .error)
        #expect(m.lastError?.contains("PERMISSION_REVOKED") == true)
    }

    @Test func modelProcessingToggles() {
        let m = makeModel()
        m.apply(DaemonEvent(event: "model_processing", modelProcessing: true))
        #expect(m.modelProcessing)
        m.apply(DaemonEvent(event: "model_processing", modelProcessing: false))
        #expect(!m.modelProcessing)
    }
}
