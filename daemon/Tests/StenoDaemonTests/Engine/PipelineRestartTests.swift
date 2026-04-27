import Testing
import Foundation
import AVFoundation
@testable import StenoDaemon

/// Tests for U5's `restartMicPipeline(reason:)` / `restartSystemPipeline(reason:)`.
///
/// These exercise the bounded-backoff loop end-to-end through the
/// `RecordingEngine` actor. The wall-clock backoff is short-circuited
/// via the engine's injectable `backoffSleep` closure — we record the
/// durations the engine requested (so we can assert the curve) but do
/// NOT actually wait. This keeps the test suite well under a second
/// per case while still exercising the same code path as production.
@Suite("Pipeline Restart Tests (U5)")
struct PipelineRestartTests {

    // MARK: - Backoff sleep recorder

    /// `@Sendable` recorder of the durations the engine requested via
    /// `backoffSleep`. Reads happen after the test has driven the
    /// engine through the path under test, so the lock here is
    /// uncontended in practice.
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

    /// Build a sleep closure that records every requested duration and
    /// returns immediately, but still respects task cancellation so the
    /// "stop during backoff cancels cleanly" test can observe the
    /// CancellationError pathway.
    private static func makeSleep(_ recorder: SleepRecorder)
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
        audioFactory: MockAudioSourceFactory? = nil,
        repo: MockTranscriptRepository? = nil,
        delegate: MockRecordingEngineDelegate? = nil,
        sleep: SleepRecorder = SleepRecorder()
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        audioFactory: MockAudioSourceFactory,
        recognizerFactory: MockSpeechRecognizerFactory,
        delegate: MockRecordingEngineDelegate,
        sleep: SleepRecorder
    ) {
        let actualRepo = repo ?? MockTranscriptRepository()
        let perms = MockPermissionService()
        let summarizer = MockSummarizationService()
        let af = audioFactory ?? MockAudioSourceFactory()
        let del = delegate ?? MockRecordingEngineDelegate()

        let coordinator = RollingSummaryCoordinator(
            repository: actualRepo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )

        let sleepClosure = Self.makeSleep(sleep)
        let engine = RecordingEngine(
            repository: actualRepo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: recognizerFactory,
            delegate: del,
            backoffSleep: sleepClosure
        )

        return (engine, actualRepo, af, recognizerFactory, del, sleep)
    }

    // MARK: - Helpers

    /// Wait until the predicate returns true, polling every `step`
    /// milliseconds, with an overall `timeout`. Returns true on success.
    /// We use this instead of fixed sleeps so tests don't drift with
    /// scheduler timing.
    private func waitFor(
        timeout: Duration = .seconds(2),
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

    // MARK: - Test errors

    private struct TestRecognizerError: Error, LocalizedError {
        let code: Int
        var errorDescription: String? { "test recognizer failure #\(code)" }
        var _domain: String { "TestRecognizer" }
        var _code: Int { code }
    }

    private static func makeNSError(domain: String, code: Int) -> NSError {
        NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: "\(domain)#\(code)"
        ])
    }

    // MARK: - Happy path

    @Test("Mic recognizer throws once → backoff → restart → next segment carries heal_marker")
    func micThrowOnceThenRestartStampsHealMarker() async throws {
        // Setup: factory returns two mic handles in order. First throws
        // immediately, second yields a successful final segment.
        let rf = MockSpeechRecognizerFactory()
        let firstHandle = MockSpeechRecognizerHandle()
        firstHandle.errorToThrow = TestRecognizerError(code: 1)
        let secondHandle = MockSpeechRecognizerHandle()
        // `resultsToYield` are emitted lazily on `transcribe` call; that
        // happens immediately after the rebuild succeeds.
        secondHandle.resultsToYield = [
            RecognizerResult(text: "hello after heal",
                             isFinal: true,
                             confidence: 0.9,
                             source: .microphone)
        ]
        rf.enqueueMicHandle(firstHandle)
        rf.enqueueMicHandle(secondHandle)

        let (engine, repo, _, _, delegate, sleep) =
            await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()

        // Wait until the rebuild lands a segment with a heal marker.
        let healed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return segs.contains { $0.healMarker != nil }
        }
        #expect(healed)

        let segments = try await repo.segments(for: session.id)
        let first = segments.first
        #expect(first?.text == "hello after heal")
        #expect(first?.healMarker?.starts(with: "after_gap:") == true)

        // Backoff curve: first restart consumed 1s.
        let durations = sleep.requestedDurations
        #expect(durations.first == .seconds(1))

        // Status returns to `.recording` once the rebuild completes.
        let status = await engine.status
        #expect(status == .recording)

        // `recovering` event fired once on restart entry; `healed` event
        // fired once on first segment after rebuild.
        let recovering = await delegate.recoveringReasons
        let healedEvents = await delegate.healedGaps
        #expect(recovering.count == 1)
        #expect(healedEvents.count == 1)

        await engine.stop()
    }

    // MARK: - Independence: sys fails while mic continues

    @Test("Sys recognizer fails independently — mic segments keep flowing")
    func sysRestartDoesNotBlockMicSegments() async throws {
        let rf = MockSpeechRecognizerFactory()
        // Mic: a single persistent handle yielding multiple segments.
        let micH = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(micH)
        // Sys: first throws, second succeeds.
        let sysFail = MockSpeechRecognizerHandle()
        sysFail.errorToThrow = TestRecognizerError(code: 7)
        let sysOk = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(sysFail)
        rf.enqueueSysHandle(sysOk)

        let (engine, repo, _, _, delegate, _) =
            await makeEngine(recognizerFactory: rf)

        let session = try await engine.start(systemAudio: true)

        // Drive mic segments while sys is restarting.
        try await Task.sleep(for: .milliseconds(20))
        micH.emit(RecognizerResult(text: "mic1", isFinal: true, confidence: 0.9, source: .microphone))
        try await Task.sleep(for: .milliseconds(10))
        micH.emit(RecognizerResult(text: "mic2", isFinal: true, confidence: 0.9, source: .microphone))

        let micFlowed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return segs.filter { $0.source == .microphone }.count >= 2
        }
        #expect(micFlowed)

        // Sys eventually recovers — `healed` event for sys is observable.
        let recovering = await delegate.recoveringReasons
        #expect(!recovering.isEmpty)

        await engine.stop()
    }

    // MARK: - Backoff curve end-to-end

    @Test("Backoff curve verified end-to-end through the engine")
    func backoffCurveObservedThroughEngine() async throws {
        let rf = MockSpeechRecognizerFactory()
        // 4 failing handles in a row (same error each time), then a success.
        for _ in 0..<4 {
            let h = MockSpeechRecognizerHandle()
            h.errorToThrow = Self.makeNSError(domain: "RecogTest", code: 42)
            rf.enqueueMicHandle(h)
        }
        let healHandle = MockSpeechRecognizerHandle()
        healHandle.resultsToYield = [
            RecognizerResult(text: "healed", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(healHandle)

        let (engine, repo, _, _, _, sleep) =
            await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()

        let healed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return !segs.isEmpty
        }
        #expect(healed)

        // The first 4 attempts of the same error should request delays
        // 1s, 2s, 4s, 8s. The 5th attempt isn't there because the
        // pipeline succeeded on the 5th rebuild (4 failures + 1 success).
        let durations = sleep.requestedDurations
        #expect(durations.count == 4)
        #expect(durations[0] == .seconds(1))
        #expect(durations[1] == .seconds(2))
        #expect(durations[2] == .seconds(4))
        #expect(durations[3] == .seconds(8))

        await engine.stop()
    }

    // MARK: - Different error codes do not count as "same error"

    @Test("Different error codes within 6 attempts do NOT trigger surrender")
    func differentErrorCodesAvoidSurrender() async throws {
        let rf = MockSpeechRecognizerFactory()
        // 6 handles, each throwing a different error code, then success.
        for code in 1...6 {
            let h = MockSpeechRecognizerHandle()
            h.errorToThrow = Self.makeNSError(domain: "RecogTest", code: code)
            rf.enqueueMicHandle(h)
        }
        let okHandle = MockSpeechRecognizerHandle()
        okHandle.resultsToYield = [
            RecognizerResult(text: "ok", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(okHandle)

        let (engine, repo, _, _, delegate, sleep) =
            await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()

        let healed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return !segs.isEmpty
        }
        #expect(healed)

        // No surrender event — each different error reset the counter.
        let surrender = await delegate.recoveryExhaustedReasons
        #expect(surrender.isEmpty)

        // Curve should always look like the front of the curve since
        // each different error resets attempts to 1.
        let durations = sleep.requestedDurations
        #expect(durations.count == 6)
        #expect(durations.allSatisfy { $0 == .seconds(1) })

        await engine.stop()
    }

    // MARK: - Surrender after 6 same-error attempts

    @Test("6 same-error recognizer throws → recoveryExhausted, status .error")
    func sixSameErrorAttemptsSurrender() async throws {
        let rf = MockSpeechRecognizerFactory()
        // 6 handles, all throwing the SAME NSError domain+code. The
        // first 5 each consume a delay (1, 2, 4, 8, 30s — all
        // short-circuited by the test sleep closure); the 6th call
        // surrenders before its own rebuild attempt.
        for _ in 0..<6 {
            let h = MockSpeechRecognizerHandle()
            h.errorToThrow = Self.makeNSError(domain: "RecogTest", code: 1)
            rf.enqueueMicHandle(h)
        }
        // Provide a 7th handle just in case — it should never be consumed.
        let unused = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(unused)

        let (engine, _, _, _, delegate, _) =
            await makeEngine(recognizerFactory: rf)

        _ = try await engine.start()

        let exhausted = await waitFor(timeout: .seconds(3)) {
            !(await delegate.recoveryExhaustedReasons.isEmpty)
        }
        #expect(exhausted)

        let status = await engine.status
        #expect(status == .error)

        // No further recognizer creation past the 6th attempt — verify
        // the unused handle was not consumed.
        let micCalls = rf.micMakeCount
        #expect(micCalls == 6)

        // No segments were finalized because the recognizer never
        // produced results.
        await engine.stop()
    }

    // MARK: - Cancellation during backoff wait

    @Test("stop() during backoff wait cancels cleanly with no extra restart")
    func stopDuringBackoffCancelsCleanly() async throws {
        // A SleepRecorder + a sleep closure that *blocks* for a long time
        // unless cancelled. We need a slow sleep here (real cancellation
        // semantics) — not the zero-duration fast path used elsewhere.
        let recorder = SleepRecorder()
        let slowSleep: @Sendable (Duration) async throws -> Void = { duration in
            recorder.record(duration)
            try await Task.sleep(for: .seconds(5)) // long enough that stop arrives first
        }

        let rf = MockSpeechRecognizerFactory()
        let firstHandle = MockSpeechRecognizerHandle()
        firstHandle.errorToThrow = TestRecognizerError(code: 99)
        rf.enqueueMicHandle(firstHandle)
        // A second handle is enqueued but should NEVER be consumed
        // because stop() cancels the restart before the rebuild fires.
        let unusedHandle = MockSpeechRecognizerHandle()
        rf.enqueueMicHandle(unusedHandle)

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

        _ = try await engine.start()

        // Wait until the engine is actually mid-backoff (sleep was called).
        let entered = await waitFor {
            !recorder.requestedDurations.isEmpty
        }
        #expect(entered)

        // Stop. The slow sleep should be cancelled, and no second
        // mic recognizer should ever be created.
        await engine.stop()

        let status = await engine.status
        #expect(status == .idle)

        // Only 2 makeRecognizer calls: 1 initial + 1 first-handle that
        // was created at start. The post-cancel rebuild was skipped.
        // (Initial start: 1 mic. Restart was scheduled but cancelled
        // before makeRecognizer #2 fired.)
        let micCalls = rf.micMakeCount
        #expect(micCalls == 1)
    }

    // MARK: - Integration: session continuity

    @Test("After restart, next segment's sessionId matches still-current session")
    func restartedPipelineKeepsSameSessionId() async throws {
        let rf = MockSpeechRecognizerFactory()
        let firstHandle = MockSpeechRecognizerHandle()
        firstHandle.errorToThrow = TestRecognizerError(code: 11)
        let secondHandle = MockSpeechRecognizerHandle()
        secondHandle.resultsToYield = [
            RecognizerResult(text: "post-restart", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(firstHandle)
        rf.enqueueMicHandle(secondHandle)

        let (engine, repo, _, _, _, _) =
            await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()

        let landed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return !segs.isEmpty
        }
        #expect(landed)

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 1)
        #expect(segments[0].sessionId == session.id)
        // Heal-in-place: session is still active (U6 will roll the
        // session for long gaps; not U5's responsibility).
        let stillActive = try await repo.session(session.id)
        #expect(stillActive?.status == .active)

        await engine.stop()
    }

    // MARK: - Integration: events broadcast around restart

    @Test("recovering event at restart entry; healed event on first new segment")
    func recoveringAndHealedEventsBracketRestart() async throws {
        let rf = MockSpeechRecognizerFactory()
        let firstHandle = MockSpeechRecognizerHandle()
        firstHandle.errorToThrow = TestRecognizerError(code: 21)
        let secondHandle = MockSpeechRecognizerHandle()
        secondHandle.resultsToYield = [
            RecognizerResult(text: "post-heal", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(firstHandle)
        rf.enqueueMicHandle(secondHandle)

        let (engine, repo, _, _, delegate, _) =
            await makeEngine(recognizerFactory: rf)

        let session = try await engine.start()

        _ = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return !segs.isEmpty
        }

        let recoveringReasons = await delegate.recoveringReasons
        let healedGaps = await delegate.healedGaps
        #expect(recoveringReasons.count == 1)
        #expect(healedGaps.count == 1)
        #expect(healedGaps[0] >= 0)

        // The status timeline includes `.recovering` between
        // `.recording` and the post-restart return to `.recording`.
        let statuses = await delegate.statusChanges
        #expect(statuses.contains(.recovering))
        #expect(statuses.last == .recording)

        await engine.stop()
    }

    // MARK: - PR #35 issues 3 & 4: rebuild-throw reschedules

    /// Regression test for `restartMicPipeline` failing to retry when
    /// the rebuild step itself throws. Before the fix, the catch block
    /// would record the error in the policy and return; with no
    /// recognizer task left to surface a follow-up failure, the mic
    /// pipeline would stay stuck. The fix enqueues a fresh restart
    /// task whenever the rebuild throws and the policy hasn't yet
    /// surrendered.
    @Test("Mic rebuild throws on attempts 1-2, succeeds on 3 — pipeline recovers")
    func micRebuildThrowReschedulesUntilSuccess() async throws {
        // Failure pattern keyed off the existing
        // `MockAudioSourceFactory.micCreateCount` (mutated on the
        // engine actor's serialized execution path). We override
        // `micErrorQueue` with sentinel values: the start path
        // (`micCreateCount == 1`) gets through, but rebuild attempts
        // 1 and 2 (`micCreateCount == 2, 3`) throw via a small
        // wrapper. The 3rd rebuild succeeds.
        final class ThrowOnSecondAndThirdFactory: AudioSourceFactory, @unchecked Sendable {
            let inner = MockAudioSourceFactory()
            // We store the call count using NSNumber-ish atomic-ish
            // semantics through a single-threaded property. Actor
            // isolation on the engine guarantees serial calls into
            // `makeMicrophoneSource`, so a plain `Int` here is fine.
            var calls: Int = 0
            var creates: Int { calls }

            func makeMicrophoneSource(device: String?) async throws
                -> (buffers: AsyncStream<AVAudioPCMBuffer>,
                    format: AVAudioFormat,
                    stop: @Sendable () async -> Void)
            {
                calls += 1
                let n = calls
                if n == 2 || n == 3 {
                    throw MockAudioSourceFactory.InjectedError("rebuild-\(n - 1)")
                }
                return try await inner.makeMicrophoneSource(device: device)
            }
            func makeSystemAudioSource() -> AudioSource { inner.makeSystemAudioSource() }
        }

        let rf = MockSpeechRecognizerFactory()
        // Initial handle throws immediately on iteration so the
        // restart loop kicks in shortly after `start()` returns.
        let initialHandle = MockSpeechRecognizerHandle()
        initialHandle.errorToThrow = Self.makeNSError(domain: "RecogTest", code: 7)
        rf.enqueueMicHandle(initialHandle)
        let healthyHandle = MockSpeechRecognizerHandle()
        healthyHandle.resultsToYield = [
            RecognizerResult(text: "post-rebuild", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(healthyHandle)

        let af = ThrowOnSecondAndThirdFactory()
        let repo = MockTranscriptRepository()
        let perms = await MainActor.run { MockPermissionService() }
        let summarizer = MockSummarizationService()
        let delegate = MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )
        let recorder = SleepRecorder()
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: delegate,
            backoffSleep: Self.makeSleep(recorder)
        )

        _ = try await engine.start()

        // The pipeline must walk the curve: fail rebuild #1, fail
        // rebuild #2, succeed on rebuild #3. Wait until the audio
        // factory has been called for all three rebuild attempts so
        // the restart loop has had a chance to fully run.
        let attemptedAll = await waitFor(timeout: .seconds(3)) { af.creates >= 4 }
        #expect(attemptedAll, "creates=\(af.creates)")

        // After the rebuilds, the engine status settles to .recording.
        let recovered = await waitFor(timeout: .seconds(3)) {
            await engine.status == .recording
        }
        #expect(recovered)

        // No surrender event — the policy stayed under threshold.
        let surrender = await delegate.recoveryExhaustedReasons
        #expect(surrender.isEmpty)

        // 4 mic creates: 1 start + 3 rebuild attempts (2 throws + 1
        // success).
        #expect(af.creates == 4)

        // The sleep recorder shows at least 3 delays (one per restart
        // attempt): the initial-recognizer-failure attempt + the two
        // rebuild-failure reschedules.
        #expect(recorder.requestedDurations.count >= 3)

        await engine.stop()
    }

    @Test("System rebuild throws on attempts 1-2, succeeds on 3 — pipeline recovers")
    func sysRebuildThrowReschedulesUntilSuccess() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())     // mic stays healthy
        // System recognizer: a healthy initial handle (will be torn
        // down by the first failure), then queued failures + one
        // success at the recognizer level. The system audio source's
        // own start path is the analogue of mic source factory throws.
        let initialSysHandle = MockSpeechRecognizerHandle()
        rf.enqueueSysHandle(initialSysHandle)
        // Two queued sys handles both throw at the recognizer
        // factory level — these stand in for "the rebuild's
        // makeRecognizer threw immediately."
        let sysFail1 = MockSpeechRecognizerHandle()
        sysFail1.errorToThrow = Self.makeNSError(domain: "SysRebuild", code: 11)
        rf.enqueueSysHandle(sysFail1)
        let sysFail2 = MockSpeechRecognizerHandle()
        sysFail2.errorToThrow = Self.makeNSError(domain: "SysRebuild", code: 11)
        rf.enqueueSysHandle(sysFail2)
        let sysOk = MockSpeechRecognizerHandle()
        sysOk.resultsToYield = [
            RecognizerResult(text: "sys ok", isFinal: true, source: .systemAudio)
        ]
        rf.enqueueSysHandle(sysOk)

        let (engine, _, _, _, delegate, _) =
            await makeEngine(recognizerFactory: rf)

        _ = try await engine.start(systemAudio: true)

        // Trigger a system recognizer error on the initial handle.
        initialSysHandle.finishWithError(Self.makeNSError(domain: "SysInitial", code: 9))

        // The handler should retry through the rebuild failures and
        // ultimately recover.
        let recovered = await waitFor(timeout: .seconds(3)) {
            await engine.status == .recording
        }
        #expect(recovered)

        // No surrender event.
        let surrender = await delegate.recoveryExhaustedReasons
        #expect(surrender.isEmpty)

        await engine.stop()
    }

    // MARK: - PR #35 issue 2: backoff resets when restarting from .error

    /// Regression test for the "exhausted backoff persists across
    /// restart from .error" bug. After a surrender, the engine ends
    /// up in `.error` with `micBackoff.isExhausted == true`. Without
    /// the fix, calling `start(...)` again succeeds (it allows
    /// transitions out of `.error`) but the policy still reports
    /// exhausted, so the next transient failure short-circuits to
    /// `recoveryExhausted` immediately instead of running the curve.
    @Test("Backoff resets when start() transitions out of .error after a surrender")
    func backoffResetsOnRestartFromError() async throws {
        // Six handles, all throwing the same NSError → forces surrender.
        let rfFail = MockSpeechRecognizerFactory()
        for _ in 0..<6 {
            let h = MockSpeechRecognizerHandle()
            h.errorToThrow = Self.makeNSError(domain: "RecogTest", code: 99)
            rfFail.enqueueMicHandle(h)
        }

        let (engine, _, _, _, delegate, _) =
            await makeEngine(recognizerFactory: rfFail)

        _ = try await engine.start()

        // Surrender fires, status transitions to `.error`.
        let exhausted = await waitFor(timeout: .seconds(3)) {
            !(await delegate.recoveryExhaustedReasons.isEmpty)
        }
        #expect(exhausted)
        let errorStatus = await engine.status
        #expect(errorStatus == .error)
        let surrenderCount = await delegate.recoveryExhaustedReasons.count
        #expect(surrenderCount == 1)

        // Now enqueue a follow-up scenario: one failing handle, then a
        // successful one. If the policy were still exhausted, the very
        // first failure after the new `start()` would emit a SECOND
        // recoveryExhausted event. Instead we expect a single 1s delay
        // from the curve and a healthy rebuild.
        let firstFollowup = MockSpeechRecognizerHandle()
        firstFollowup.errorToThrow = Self.makeNSError(domain: "RecogTest", code: 99)
        rfFail.enqueueMicHandle(firstFollowup)
        let okHandle = MockSpeechRecognizerHandle()
        okHandle.resultsToYield = [
            RecognizerResult(text: "post-restart", isFinal: true, source: .microphone)
        ]
        rfFail.enqueueMicHandle(okHandle)

        // start() must accept a transition from .error.
        _ = try await engine.start()

        let recovered = await waitFor(timeout: .seconds(3)) {
            await engine.status == .recording
        }
        #expect(recovered)

        // No SECOND surrender — only the original one.
        let surrenderAfter = await delegate.recoveryExhaustedReasons.count
        #expect(surrenderAfter == 1)

        await engine.stop()
    }
}
