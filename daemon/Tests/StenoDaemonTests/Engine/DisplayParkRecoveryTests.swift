import Testing
import Foundation
import AVFoundation
@testable import StenoDaemon

/// Integration tests for #42's "park system pipeline until display
/// reappears" recovery path.
///
/// The bug: SCStream `-3815 noCaptureSource` ("Failed to find any
/// display") and the throw of `SystemAudioError.noDisplaysAvailable`
/// from `SystemAudioSource.start()` both used to route into U5's
/// bounded-backoff loop, which burns through its budget (~45s) while
/// the display is still gone and then surrenders to `.error`. The fix
/// is to park the sys pipeline — no backoff advance, no retry timer —
/// and let `DisplayObserver` re-arm it when a display reappears.
///
/// These tests drive the engine through its `SystemAudioRecoveryDelegate`
/// + `DisplayEventTarget` conformances directly, the same way the
/// existing U8 `SystemAudioRecoveryTests` do.
@Suite("Display Park Recovery (#42)")
struct DisplayParkRecoveryTests {

    // MARK: - Sleep recorder (mirrors SystemAudioRecoveryTests)

    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requestedDurations: [Duration] = []

        var requestedDurations: [Duration] {
            lock.lock(); defer { lock.unlock() }
            return _requestedDurations
        }

        func record(_ duration: Duration) {
            lock.lock(); defer { lock.unlock() }
            _requestedDurations.append(duration)
        }
    }

    private static func makeFastSleep(_ recorder: SleepRecorder)
        -> @Sendable (Duration) async throws -> Void {
        return { duration in
            recorder.record(duration)
            try Task.checkCancellation()
        }
    }

    // MARK: - Engine assembly

    @MainActor
    private func makeEngine(
        recognizerFactory: MockSpeechRecognizerFactory,
        sleep: SleepRecorder = SleepRecorder()
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        audioFactory: MockAudioSourceFactory,
        delegate: MockRecordingEngineDelegate,
        sleep: SleepRecorder
    ) {
        let repo = MockTranscriptRepository()
        let perms = MockPermissionService()
        let summarizer = MockSummarizationService()
        let af = MockAudioSourceFactory()
        let del = MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: recognizerFactory,
            delegate: del,
            backoffSleep: Self.makeFastSleep(sleep)
        )
        return (engine, repo, af, del, sleep)
    }

    private func waitFor(
        timeout: Duration = .seconds(3),
        step: Duration = .milliseconds(10),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds(timeout))
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: step)
        }
        return false
    }

    private func seconds(_ duration: Duration) -> TimeInterval {
        let comps = duration.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
    }

    // MARK: - Path-1: SCStream -3815 → park, not exhaust

    @Test("scstream -3815 → engine parks sys, mic continues, NO recoveryExhausted, NO backoff sleep")
    func park_doesNotAdvanceBackoff_orExhaust() async throws {
        let rf = MockSpeechRecognizerFactory()
        let micH = MockSpeechRecognizerHandle()
        let initialSys = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(micH)
        rf.enqueueSysHandle(initialSys)

        let (engine, _, _, delegate, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        // Drive the park path through the engine's
        // `SystemAudioRecoveryDelegate` conformance directly. Mirrors
        // what `SystemAudioSource.dispatchDelegateError(.parkUntilDisplay)`
        // does in production for a `-3815` SCStream stop.
        await engine.systemAudioParkedUntilDisplay(
            reason: "scstream:com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3815:Failed to find any display"
        )

        // Engine must NOT have advanced the bounded backoff. No sleeps
        // were requested.
        let durations = sleep.requestedDurations
        #expect(durations.isEmpty)

        // No `recoveryExhausted` event — parking is non-fatal.
        let exhausted = await delegate.recoveryExhaustedReasons
        #expect(exhausted.isEmpty)

        // The TUI's load-bearing token surfaces via a *transient* error
        // event (so the engine state machine treats it as recoverable).
        let landed = await waitFor {
            !(await delegate.errors.isEmpty)
        }
        #expect(landed)
        let errors = await delegate.errors
        let parkedErrors = errors.filter {
            $0.0.contains(RecordingEngine.systemAudioParkedNoDisplayToken)
        }
        #expect(!parkedErrors.isEmpty)
        // Every parked error is transient (matches the "waiting for
        // stimulus" semantic — not a hard surrender).
        #expect(parkedErrors.allSatisfy { $0.1 == true })

        // Status stays `.recording` — mic pipeline is still healthy.
        let status = await engine.status
        #expect(status == .recording)

        // Mic was not rebuilt.
        #expect(rf.micMakeCount == 1)

        await engine.stop()
    }

    // MARK: - Repeated parks do not exhaust (the load-bearing fix)

    @Test("Six consecutive park events do NOT exhaust the engine (vs the U5 surrender at 6)")
    func sixConsecutiveParksDoNotExhaust() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, delegate, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        // Six parks in a row — same number the U5 backoff curve would
        // surrender on for `.retry` errors. The whole point of this
        // PR is that parking does NOT surrender, no matter how many
        // park events arrive.
        for i in 0..<6 {
            await engine.systemAudioParkedUntilDisplay(
                reason: "scstream:-3815:burst attempt \(i)"
            )
        }

        // No recoveryExhausted event, ever.
        let exhausted = await delegate.recoveryExhaustedReasons
        #expect(exhausted.isEmpty)

        // No backoff sleeps were issued.
        #expect(sleep.requestedDurations.isEmpty)

        // Status stays `.recording`.
        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    // MARK: - Display becomes available → re-arm sys pipeline

    @Test("Parked sys pipeline re-arms when displayBecameAvailable() fires")
    func displayBecameAvailableRearmsSysPipeline() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        // One sys handle for the initial bring-up, one for the re-arm.
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, _, _) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        // Initial bring-up consumed one sys recognizer.
        #expect(rf.sysMakeCount == 1)

        // Park the sys pipeline.
        await engine.systemAudioParkedUntilDisplay(reason: "scstream:-3815")

        // Simulate the DisplayObserver firing after a display reappears.
        // This routes through the engine's DisplayEventTarget conformance.
        await engine.displayBecameAvailable()

        // The re-arm should call `startSystemAudio(locale:)`, which
        // creates a fresh sys recognizer via the factory.
        let rebuilt = await waitFor {
            rf.sysMakeCount >= 2
        }
        #expect(rebuilt)

        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    // MARK: - Display event when NOT parked is a no-op

    @Test("displayBecameAvailable() while not parked is a no-op (no extra sys rebuild)")
    func displayBecameAvailableNoOpWhenNotParked() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())
        // Enqueue an extra sys handle — its consumption would prove an
        // unwanted rebuild happened.
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, _, _) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        let baselineSysCount = rf.sysMakeCount

        // Engine is happy and recording — a display event arriving now
        // must NOT re-arm anything.
        await engine.displayBecameAvailable()

        // Give any spurious rebuild a chance to land.
        try await Task.sleep(for: .milliseconds(100))

        #expect(rf.sysMakeCount == baselineSysCount)

        await engine.stop()
    }

    // MARK: - Path-2: rebuild throw of noDisplaysAvailable → park, not exhaust

    @Test("rebuild that throws SystemAudioError.noDisplaysAvailable → park (no exhaust, no backoff burn)")
    func rebuildNoDisplaysAvailable_routesToPark() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())
        // Enqueue a second handle so we can prove no second consumption
        // happens — if the engine had advanced into a U5 rebuild loop
        // it would have consumed this one.
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, _, audioFactory, delegate, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)
        #expect(rf.sysMakeCount == 1)

        // Pre-arm the mock system source so its NEXT start() call
        // throws noDisplaysAvailable. The mock factory returns the
        // same source instance each time `makeSystemAudioSource()` is
        // called, so this affects the rebuild attempt.
        audioFactory.systemAudioSource.errorToThrow = SystemAudioError.noDisplaysAvailable

        // Drive a sys restart via a normal retry path; the rebuild
        // will throw noDisplaysAvailable, which the engine's
        // catch-block routes to the park helper instead of advancing
        // the bounded backoff.
        let key = "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3821"
        await engine.systemAudioRequestsRetry(errorCode: key, reason: "scstream:\(key)")

        // The parked-error token must surface on the delegate.
        let parked = await waitFor {
            let errs = await delegate.errors
            return errs.contains { $0.0.contains(RecordingEngine.systemAudioParkedNoDisplayToken) }
        }
        #expect(parked)

        // No recoveryExhausted, no further sys rebuild, no surrender.
        let exhausted = await delegate.recoveryExhaustedReasons
        #expect(exhausted.isEmpty)

        // Exactly the original 1s backoff sleep (the entry into the
        // restart task records the error once before the rebuild) —
        // but NOT five sleeps. The park path bails out of the loop
        // immediately after the throw.
        let durations = sleep.requestedDurations
        #expect(durations.count <= 1)

        // No second sys recognizer was created — the rebuild attempt
        // threw before reaching `makeRecognizer`.
        #expect(rf.sysMakeCount == 1)

        // Status is `.recording` (mic is still healthy).
        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    // MARK: - Permission revocation path is unaffected

    @Test("SCStream userDeclined still emits MIC_OR_SCREEN_PERMISSION_REVOKED (#42 changes do not regress U8)")
    func permissionRevocationStillSurrenders() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, delegate, _) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        await engine.systemAudioPermissionRevoked()

        let exhausted = await waitFor {
            !(await delegate.recoveryExhaustedReasons.isEmpty)
        }
        #expect(exhausted)

        let reasons = await delegate.recoveryExhaustedReasons
        #expect(reasons.contains("MIC_OR_SCREEN_PERMISSION_REVOKED"))

        let status = await engine.status
        #expect(status == .error)

        await engine.stop()
    }

    // MARK: - stop() clears parked state

    @Test("stop() while parked clears the parked flag (the next start() is fresh)")
    func stopClearsParkedFlag() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())
        // Second start cycle.
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, _, _) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        await engine.systemAudioParkedUntilDisplay(reason: "scstream:-3815")
        await engine.stop()

        // Re-start. The new bring-up consumes a fresh sys handle.
        _ = try await engine.start(systemAudio: true)
        #expect(rf.sysMakeCount == 2)

        // After stop+start the parked flag is reset — a display event
        // arriving now must be a no-op (sys is happily running, not
        // parked).
        let baseline = rf.sysMakeCount
        await engine.displayBecameAvailable()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rf.sysMakeCount == baseline)

        await engine.stop()
    }
}
