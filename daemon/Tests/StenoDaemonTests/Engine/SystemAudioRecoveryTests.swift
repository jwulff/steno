import Testing
import Foundation
import AVFoundation
@testable import StenoDaemon

/// End-to-end integration tests for U8's SCStream-error recovery path
/// AND the U8 microphone TCC-revocation surface, exercised through
/// `RecordingEngine`.
///
/// We can't drive a real `SCStream` in unit tests (Screen Recording
/// permission not granted in CI), so the integration tests use the
/// engine's `SystemAudioRecoveryDelegate` conformance directly. The
/// engine routes `systemAudioRequestsRetry(...)` through U5's
/// `restartSystemPipeline` and `systemAudioPermissionRevoked()` through
/// the new `handleSystemAudioPermissionRevoked()` path.
///
/// Mic TCC-revocation is exercised by emitting a synthetic NSError
/// whose description matches `MicrophonePermissionErrorDetector`'s
/// heuristic from the mock recognizer handle.
@Suite("System Audio Recovery (U8)")
struct SystemAudioRecoveryTests {

    // MARK: - Backoff sleep recorder (mirrors PipelineRestartTests)

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

    // MARK: - Helpers

    private static func makeSCError(_ rawCode: Int) -> NSError {
        NSError(
            domain: SystemAudioErrorClassifier.scStreamErrorDomain,
            code: rawCode,
            userInfo: [NSLocalizedDescriptionKey: "synthetic SCStream error \(rawCode)"]
        )
    }

    // MARK: - Sys retry path (single error → backoff → rebuild)

    @Test("connectionInterrupted (-3805) → engine schedules sys restart with 1s backoff")
    func connectionInterruptedTriggersSysRestart() async throws {
        let rf = MockSpeechRecognizerFactory()
        // Initial sys handle (created by engine.start), plus a
        // post-rebuild handle.
        let initialSys = MockSpeechRecognizerHandle()
        let rebuildSys = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(initialSys)
        rf.enqueueSysHandle(rebuildSys)

        let (engine, _, _, _, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        // Drive the SCStream error path through the engine's
        // SystemAudioRecoveryDelegate conformance directly.
        let key = "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3805"
        await engine.systemAudioRequestsRetry(
            errorCode: key,
            reason: "scstream:\(key):connection interrupted"
        )

        // The sys restart task should fire backoff once, then rebuild.
        let rebuilt = await waitFor {
            rf.sysMakeCount >= 2
        }
        #expect(rebuilt)

        // First backoff entry is 1s.
        let durations = sleep.requestedDurations
        #expect(durations.first == .seconds(1))

        await engine.stop()
    }

    // MARK: - Sys ignore path (delegate not driven for ignore)

    @Test("attemptToStopStreamState (-3808) is classified .ignore — engine.systemAudioRequestsRetry not called")
    func ignorePathDoesNotInvokeEngineRetry() async throws {
        // The classifier never routes .ignore through the delegate,
        // so we don't have an explicit engine-level path to assert.
        // Verify via the source's dispatch table directly: an ignore
        // error must NOT increment the retry-call count.
        let source = SystemAudioSource()
        let recovery = RecordingRecoveryDelegate()
        source.recoveryDelegate = recovery

        let err = Self.makeSCError(-3808)
        source.handleStreamStopForTesting(error: err)

        try await Task.sleep(for: .milliseconds(50))
        let calls = await recovery.retryCalls
        let revoked = await recovery.permissionRevokedCount
        #expect(calls.isEmpty)
        #expect(revoked == 0)
    }

    // MARK: - Sys surrender after 5 same-error attempts

    @Test("5 consecutive systemStoppedStream errors → recoveryExhausted, mic continues")
    func fiveSameErrorsSurrender() async throws {
        let rf = MockSpeechRecognizerFactory()
        // Mic: persistent passing handle so mic stays up across the
        // sys storm.
        let micH = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(micH)
        // Sys: initial handle from engine.start, then 5 fresh handles
        // for the rebuild path. Each rebuild succeeds (handle does not
        // throw), then the next external SCStream error retriggers a
        // restart with the SAME backoff key. After 5 same-error calls
        // the policy surrenders and emits recoveryExhausted.
        let initialSys = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(initialSys)
        let sysErrorCode = "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3821"
        for _ in 0..<5 {
            rf.enqueueSysHandle(MockSpeechRecognizerHandle())
        }

        let (engine, _, _, delegate, _) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        // Drive 5 SCStream error events with the same backoff key.
        // Each call schedules a sys restart; the policy advances on
        // each `record(error:)` and surrenders on the 5th call.
        //
        // Test pacing: each call schedules a Task<Void, Never>. To
        // ensure the next call doesn't get dropped by the
        // `if sysRestartTask != nil { return }` gate, we wait for
        // the recovering-event count to reach `i + 1` (proves the
        // restart task entered) AND for the status to leave
        // `.recovering` (proves the restart task has finished).
        for i in 0..<5 {
            await engine.systemAudioRequestsRetry(
                errorCode: sysErrorCode,
                reason: "scstream:\(sysErrorCode):systemStoppedStream attempt \(i)"
            )
            _ = await waitFor(timeout: .seconds(2)) {
                let recoverings = await delegate.recoveringReasons.count
                return recoverings >= i + 1
            }
            _ = await waitFor(timeout: .seconds(2)) {
                let s = await engine.status
                return s != .recovering
            }
        }

        // Surrender event observed.
        let surrendered = await waitFor {
            !(await delegate.recoveryExhaustedReasons.isEmpty)
        }
        #expect(surrendered)

        // Engine is in error state (sys side surrendered).
        let status = await engine.status
        #expect(status == .error)

        // Mic still has its initial handle and was never recreated.
        // U5 sys restarts must NOT touch mic state.
        let micCalls = rf.micMakeCount
        #expect(micCalls == 1)

        await engine.stop()
    }

    // MARK: - SCStream rebuild does NOT touch mic pipeline

    @Test("Sys retry path does not rebuild the mic pipeline")
    func sysRetryDoesNotRebuildMic() async throws {
        let rf = MockSpeechRecognizerFactory()
        let micH = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(micH)
        let initialSys = MockSpeechRecognizerHandle()
        let rebuildSys = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(initialSys)
        rf.enqueueSysHandle(rebuildSys)

        let (engine, _, _, _, _) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start(systemAudio: true)

        let micCallsBefore = rf.micMakeCount

        let key = "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3821"
        await engine.systemAudioRequestsRetry(errorCode: key, reason: "scstream:\(key)")

        // Wait for sys rebuild to land.
        let rebuilt = await waitFor { rf.sysMakeCount >= 2 }
        #expect(rebuilt)

        let micCallsAfter = rf.micMakeCount
        #expect(micCallsAfter == micCallsBefore)

        await engine.stop()
    }

    // MARK: - SCStream userDeclined → recoveryExhausted with permission token

    @Test("SCStream userDeclined → recoveryExhausted with MIC_OR_SCREEN_PERMISSION_REVOKED")
    func userDeclinedEmitsLoadBearingToken() async throws {
        let rf = MockSpeechRecognizerFactory()
        let initialSys = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(initialSys)

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

    // MARK: - Mic TCC revocation (heuristic) → recoveryExhausted, no backoff

    @Test("Mic permission-revocation error → recoveryExhausted with token, no backoff loop")
    func micPermissionRevocationDoesNotBackoff() async throws {
        let rf = MockSpeechRecognizerFactory()
        // Initial mic handle that fails immediately with a
        // permission-class error. The engine MUST surface this as a
        // non-transient `recoveryExhausted` and NOT enter U5's backoff
        // loop.
        let permErr = NSError(
            domain: "AVFoundationErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
        )
        let firstHandle = MockSpeechRecognizerHandle()
        firstHandle.errorToThrow = permErr
        rf.enqueueMicHandle(firstHandle)
        // A second handle is enqueued purely to assert it is NEVER
        // consumed (no rebuild attempts).
        let unused = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(unused)

        let (engine, _, _, delegate, sleep) = await makeEngine(recognizerFactory: rf)
        _ = try await engine.start()

        let exhausted = await waitFor {
            !(await delegate.recoveryExhaustedReasons.isEmpty)
        }
        #expect(exhausted)

        // Load-bearing token check.
        let reasons = await delegate.recoveryExhaustedReasons
        #expect(reasons.contains("MIC_OR_SCREEN_PERMISSION_REVOKED"))

        // Status is `.error`.
        let status = await engine.status
        #expect(status == .error)

        // No backoff sleeps were requested (no U5 cycle).
        let durations = sleep.requestedDurations
        #expect(durations.isEmpty)

        // No second mic handle consumed — no rebuild.
        let micCalls = rf.micMakeCount
        #expect(micCalls == 1)

        await engine.stop()
    }

    // MARK: - Cancellation during sys backoff

    @Test("stop() during sys backoff cancels the in-flight restart cleanly")
    func stopDuringSysBackoffCancels() async throws {
        // Slow sleep so we can observe stop() cancelling it.
        let recorder = SleepRecorder()
        let slowSleep: @Sendable (Duration) async throws -> Void = { duration in
            recorder.record(duration)
            try await Task.sleep(for: .seconds(5))
        }

        let rf = MockSpeechRecognizerFactory()
        let micH = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(micH)
        let initialSys = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(initialSys)
        // A second sys handle is enqueued; if cancellation works, it
        // is NEVER consumed.
        let unused = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(unused)

        let repo = MockTranscriptRepository()
        let perms = await MainActor.run { MockPermissionService() }
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
            speechRecognizerFactory: rf,
            delegate: del,
            backoffSleep: slowSleep
        )

        _ = try await engine.start(systemAudio: true)

        let key = "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3821"
        await engine.systemAudioRequestsRetry(errorCode: key, reason: "scstream:\(key)")

        // Wait until the engine actually entered the backoff sleep.
        let entered = await waitFor {
            !recorder.requestedDurations.isEmpty
        }
        #expect(entered)

        // Stop. The slow sleep should be cancelled, and no second
        // sys recognizer should ever be created.
        await engine.stop()

        let status = await engine.status
        #expect(status == .idle)

        // sys recognizer creations: 1 initial. The post-cancel
        // rebuild was skipped.
        let sysCalls = rf.sysMakeCount
        #expect(sysCalls == 1)
    }
}

