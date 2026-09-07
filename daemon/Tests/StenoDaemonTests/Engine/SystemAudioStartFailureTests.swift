import Testing
import Foundation
import AVFoundation
import ScreenCaptureKit
@testable import StenoDaemon

/// Recovery tests for failures thrown by the system-audio *bring-up*
/// path (`startSystemAudio`), as opposed to the *rebuild* path
/// (`restartSystemPipeline`).
///
/// The bug: `restartSystemPipeline` classifies its failures (PR #35
/// review, issue 4 — "without an explicit reschedule, the system
/// pipeline stays stuck after a rebuild throw"), but `startSystemAudio`
/// only ever special-cased the *typed*
/// `SystemAudioError.noDisplaysAvailable`. Every other throw fell into a
/// generic catch that emitted a transient error and returned — no park,
/// no retry, no backoff.
///
/// That leaves the engine in a state no observer can recover:
///
///   - `sysParkedAwaitingDisplay == false` (cleared eagerly at the top
///     of `startSystemAudio`), so `handleDisplayBecameAvailable()`
///     returns at its first guard;
///   - `isSystemAudioEnabled == true`, so status keeps claiming system
///     audio is on;
///   - no `sysRestartTask`, so nothing retries.
///
/// The lid-close/lid-open path hits this directly. Lid-*close* is fine:
/// the display list empties, the typed `noDisplaysAvailable` is thrown,
/// and the #42 park works. Lid-*open* re-arms into `startSystemAudio`,
/// which clears the park flag on entry and then fails because the
/// display is still settling — so system audio stays dead until the
/// user manually stops and restarts. The microphone is unaffected,
/// which is exactly what the bug report describes.
///
/// Note the error *shape* these tests inject. `SystemAudioSource.start()`
/// cannot throw a bare `NSError`; it wraps the ScreenCaptureKit error in
/// `SystemAudioError.captureFailed` to throw it. Injecting a raw
/// `NSError` here would exercise a shape production never produces, so
/// the helper below wraps.
@Suite("System Audio Bring-Up Failure Recovery")
struct SystemAudioStartFailureTests {

    // MARK: - Sleep recorder (mirrors DisplayParkRecoveryTests)

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
        return (engine, af, del, sleep)
    }

    private func waitFor(
        timeout: Duration = .seconds(3),
        step: Duration = .milliseconds(10),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        _ = timeout
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: step)
        }
        return false
    }

    private func scStreamError(_ code: Int) -> NSError {
        NSError(
            domain: SystemAudioErrorClassifier.scStreamErrorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "synthetic SCStream \(code)"]
        )
    }

    /// The shape a bring-up failure actually has in production.
    ///
    /// `SystemAudioSource.start()` cannot throw a bare `NSError` — it
    /// wraps the ScreenCaptureKit error so the throw is typed. Tests
    /// that inject a raw `NSError` therefore exercise a shape the real
    /// source never produces; these use the wrapped form.
    private func bringUpFailure(
        _ code: Int,
        stage: SystemAudioError.CaptureStage = .startCapture
    ) -> SystemAudioError {
        .captureFailed(stage: stage, underlying: scStreamError(code))
    }

    // MARK: - The lid bug

    @Test("-3815 at bring-up parks the sys pipeline (mic unaffected)")
    func noCaptureSourceAtBringUp_parks() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, delegate, _) = await makeEngine(recognizerFactory: rf)

        // Lid-open: the display is mid-transition, so `startCapture()`
        // fails with `-3815 noCaptureSource`. It arrives wrapped, which
        // is why the classifier has to unwrap before dispatching.
        af.systemAudioSource.errorToThrow = bringUpFailure(SCStreamError.noCaptureSource.rawValue)

        _ = try await engine.start(systemAudio: true)

        let parked = await waitFor {
            let errs = await delegate.errors
            return errs.contains { $0.0.contains(RecordingEngine.systemAudioParkedNoDisplayToken) }
        }
        #expect(parked, "-3815 at bring-up must park the sys pipeline, not silently die")

        // The mic pipeline is untouched — the engine keeps recording.
        let status = await engine.status
        #expect(status == .recording)

        // Nothing surrendered.
        let exhausted = await delegate.recoveryExhaustedReasons
        #expect(exhausted.isEmpty)

        await engine.stop()
    }

    @Test("after a parked bring-up, displayBecameAvailable() re-arms system audio")
    func parkedBringUp_isRecoveredByDisplayEvent() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, delegate, _) = await makeEngine(recognizerFactory: rf)

        af.systemAudioSource.errorToThrow = bringUpFailure(SCStreamError.noCaptureSource.rawValue)
        _ = try await engine.start(systemAudio: true)

        _ = await waitFor {
            let errs = await delegate.errors
            return errs.contains { $0.0.contains(RecordingEngine.systemAudioParkedNoDisplayToken) }
        }

        // The bring-up threw before reaching `makeRecognizer`.
        #expect(rf.sysMakeCount == 0)

        // Lid opens for real: the display settles and SCStream works.
        af.systemAudioSource.errorToThrow = nil
        await engine.displayBecameAvailable()

        let rearmed = await waitFor { rf.sysMakeCount == 1 }
        #expect(rearmed, "the display event must rebuild the parked sys pipeline")

        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    // MARK: - Transient (non-display) bring-up failures

    @Test("a transient bring-up failure schedules a bounded retry instead of dying")
    func transientBringUpFailure_schedulesRetry() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, _, sleep) = await makeEngine(recognizerFactory: rf)

        // A retryable SCStream code (connection interrupted), which the
        // classifier routes to the bounded-backoff path.
        af.systemAudioSource.errorToThrow = bringUpFailure(
            SCStreamError.failedApplicationConnectionInterrupted.rawValue
        )

        _ = try await engine.start(systemAudio: true)

        // The retry is observable as a backoff sleep request; before the
        // fix nothing was ever scheduled.
        let retried = await waitFor { !sleep.requestedDurations.isEmpty }
        #expect(retried, "a retryable bring-up failure must enter the bounded backoff")

        await engine.stop()
    }

    @Test("a transient bring-up failure that clears is recovered by the retry")
    func transientBringUpFailure_recoversWhenErrorClears() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, _, _) = await makeEngine(recognizerFactory: rf)

        af.systemAudioSource.errorToThrow = bringUpFailure(
            SCStreamError.failedApplicationConnectionInterrupted.rawValue
        )
        _ = try await engine.start(systemAudio: true)

        // Whatever was wrong resolves before the backoff elapses.
        af.systemAudioSource.errorToThrow = nil

        let recovered = await waitFor { rf.sysMakeCount == 1 }
        #expect(recovered, "the scheduled retry must rebuild the sys pipeline once start() succeeds")

        await engine.stop()
    }

    // MARK: - Permission

    @Test("permissionDenied at bring-up surfaces the load-bearing revoked token")
    func permissionDeniedAtBringUp_surfacesRevokedToken() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, delegate, sleep) = await makeEngine(recognizerFactory: rf)

        af.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied

        _ = try await engine.start(systemAudio: true)

        let surfaced = await waitFor {
            await delegate.recoveryExhaustedReasons.contains("MIC_OR_SCREEN_PERMISSION_REVOKED")
        }
        #expect(surfaced, "a denied Screen Recording grant must be reported, not swallowed as transient")

        // Retrying a TCC denial is pointless — it must not burn backoff.
        #expect(sleep.requestedDurations.isEmpty)

        // The surrender must survive the rest of `bringUpPipelines`.
        // `handleSystemAudioPermissionRevoked()` runs inline, so its
        // `.error` is set before `startSystemAudio` returns and used to
        // be overwritten by the unconditional `setStatus(.recording)`
        // at the end of bring-up — leaving the engine claiming to
        // record with the sys pipeline torn down.
        let status = await engine.status
        #expect(status == .error, "a revoked grant must not be overwritten by .recording")

        await engine.stop()
    }

    /// Regression guard for the mapping this fix removed.
    ///
    /// `SystemAudioSource.start()` used to turn *every*
    /// `SCShareableContent.current` failure into
    /// `SystemAudioError.permissionDenied`, including the transient one
    /// a display produces while it wakes. Routing that to the revoked
    /// path drives the engine to a terminal `.error`, and
    /// `handleDisplayBecameAvailable()` refuses to re-arm from `.error`
    /// — so the lid bug would become permanently unrecoverable and the
    /// TUI would claim a permission problem that does not exist.
    @Test("a transient display-enumeration failure retries and never reports revoked")
    func transientShareableContentFailure_isNotTreatedAsRevoked() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, delegate, sleep) = await makeEngine(recognizerFactory: rf)

        af.systemAudioSource.errorToThrow = bringUpFailure(
            SCStreamError.failedApplicationConnectionInterrupted.rawValue,
            stage: .shareableContent
        )

        _ = try await engine.start(systemAudio: true)

        // The display finishes waking before the backoff elapses.
        af.systemAudioSource.errorToThrow = nil

        let recovered = await waitFor { rf.sysMakeCount == 1 }
        #expect(recovered, "a transient content-fetch failure must be recoverable")
        #expect(!sleep.requestedDurations.isEmpty, "recovery must go through the bounded backoff")

        let exhausted = await delegate.recoveryExhaustedReasons
        #expect(
            !exhausted.contains("MIC_OR_SCREEN_PERMISSION_REVOKED"),
            "a transient display-enumeration failure is not a revoked grant"
        )

        let status = await engine.status
        #expect(status == .recording)

        await engine.stop()
    }

    /// The other half of that mapping: a grant that really is denied
    /// arrives as SCStream `userDeclined`, and must still be reported
    /// as revoked rather than retried forever.
    @Test("userDeclined at bring-up surfaces the revoked token and burns no backoff")
    func userDeclinedAtBringUp_surfacesRevokedToken() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueSysHandle(MockSpeechRecognizerHandle())

        let (engine, af, delegate, sleep) = await makeEngine(recognizerFactory: rf)

        af.systemAudioSource.errorToThrow = bringUpFailure(
            SCStreamError.userDeclined.rawValue,
            stage: .shareableContent
        )

        _ = try await engine.start(systemAudio: true)

        let surfaced = await waitFor {
            await delegate.recoveryExhaustedReasons.contains("MIC_OR_SCREEN_PERMISSION_REVOKED")
        }
        #expect(surfaced, "a genuinely declined grant must be reported as revoked")
        #expect(sleep.requestedDurations.isEmpty, "retrying a TCC denial is pointless")

        let status = await engine.status
        #expect(status == .error, "a revoked grant must not be overwritten by .recording")

        await engine.stop()
    }
    @Test("a wrapped missing-display error during retry parks until a display returns")
    func wrappedRebuildFailure_parksAndRearms() async throws {
        let rf = MockSpeechRecognizerFactory()
        let (engine, af, delegate, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)
        af.systemAudioSource.errorToThrow = bringUpFailure(SCStreamError.noCaptureSource.rawValue)

        await engine.restartSystemPipeline(reason: "test", errorCode: "transient")

        let errors = await delegate.errors
        #expect(errors.contains { $0.0.contains(RecordingEngine.systemAudioParkedNoDisplayToken) })
        #expect(sleep.requestedDurations.count == 1)
        af.systemAudioSource.errorToThrow = nil
        let previousCount = rf.sysMakeCount
        await engine.displayBecameAvailable()
        #expect(rf.sysMakeCount == previousCount + 1)
        await engine.stop()
    }

    @Test("a wrapped permission denial during retry reports revocation without further retries")
    func wrappedRebuildFailure_reportsRevocation() async throws {
        let rf = MockSpeechRecognizerFactory()
        let (engine, af, delegate, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)
        af.systemAudioSource.errorToThrow = bringUpFailure(SCStreamError.userDeclined.rawValue)

        await engine.restartSystemPipeline(reason: "test", errorCode: "transient")

        let reasons = await delegate.recoveryExhaustedReasons
        #expect(reasons.contains("MIC_OR_SCREEN_PERMISSION_REVOKED"))
        #expect(sleep.requestedDurations.count == 1)
        #expect(await engine.status == .error)
        await engine.stop()
    }

}
