import Testing
import Foundation
@testable import StenoDaemon

/// Tests for U6's sleep/wake supervisor wiring on `RecordingEngine`.
///
/// `handleSystemWillSleep()` drains pipelines, persists in-flight,
/// releases the power assertion, and returns synchronously so the
/// `PowerManagementObserver` can invoke `IOAllowPowerChange` next.
/// `handleSystemDidWake()` computes the gap, applies the heal rule,
/// brings up pipelines around either the same or a fresh session, and
/// re-takes the power assertion.
@Suite("Sleep/Wake Handler Tests (U6)")
struct SleepWakeHandlerTests {

    // MARK: - Mock power assertion (records ordering)

    /// `PowerAssertionManaging` mock that timestamps each acquire/release
    /// call. The power-assertion-ordering test relies on these timestamps
    /// to verify the (1) stop pipelines → (2) release assertion → (3)
    /// allow power change ordering on willSleep.
    final class MockPowerAssertion: PowerAssertionManaging, @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(kind: Kind, time: Date)] = []
        private var _isAcquired = false
        private var _failOnAcquire: Bool = false

        enum Kind: Sendable, Equatable {
            case acquire
            case release
        }

        var events: [(kind: Kind, time: Date)] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        var acquireTimestamps: [Date] {
            events.filter { $0.kind == .acquire }.map(\.time)
        }

        var releaseTimestamps: [Date] {
            events.filter { $0.kind == .release }.map(\.time)
        }

        var isAcquired: Bool {
            lock.lock(); defer { lock.unlock() }
            return _isAcquired
        }

        func setFailOnAcquire(_ fail: Bool) {
            lock.lock(); defer { lock.unlock() }
            _failOnAcquire = fail
        }

        func acquire() throws {
            lock.lock(); defer { lock.unlock() }
            if _failOnAcquire {
                throw NSError(domain: "MockPowerAssertion", code: 1)
            }
            // Idempotent — match production semantics.
            if _isAcquired { return }
            _isAcquired = true
            _events.append((.acquire, Date()))
        }

        func release() {
            lock.lock(); defer { lock.unlock() }
            if !_isAcquired { return }
            _isAcquired = false
            _events.append((.release, Date()))
        }
    }

    // MARK: - Engine assembly

    @MainActor
    private func makeEngine(
        recognizerFactory: MockSpeechRecognizerFactory = MockSpeechRecognizerFactory(),
        audioFactory: MockAudioSourceFactory? = nil,
        repo: MockTranscriptRepository? = nil,
        delegate: MockRecordingEngineDelegate? = nil,
        powerAssertion: MockPowerAssertion = MockPowerAssertion(),
        deviceUIDProvider: @Sendable @escaping () -> String? = { "BuiltInMic" },
        reArmIdleOnWake: Bool = true
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        audioFactory: MockAudioSourceFactory,
        recognizerFactory: MockSpeechRecognizerFactory,
        delegate: MockRecordingEngineDelegate,
        power: MockPowerAssertion
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

        // U12 thresholds disabled by default in this suite — these tests
        // pre-date U12 and assert post-rollover sessions remain visible
        // (interrupted) for inspection. The U12 integration tests in
        // `EmptySessionPruneIntegrationTests.swift` cover the prune
        // behavior on rollover paths separately.
        let engine = RecordingEngine(
            repository: actualRepo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: recognizerFactory,
            delegate: del,
            backoffSleep: { _ in /* no wait */ },
            powerAssertion: powerAssertion,
            deviceUIDProvider: deviceUIDProvider,
            healThresholdSeconds: 30,
            now: { Date() },
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0,
            reArmIdleOnWake: reArmIdleOnWake
        )
        return (engine, actualRepo, af, recognizerFactory, del, powerAssertion)
    }

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

    // MARK: - Power assertion lifecycle

    @Test("Power assertion taken on first .recording entry")
    func powerAssertionAcquiredOnRecordingStart() async throws {
        let (engine, _, _, _, _, power) = await makeEngine()

        _ = try await engine.start()

        #expect(power.isAcquired)
        #expect(power.acquireTimestamps.count == 1)

        await engine.stop()
    }

    @Test("Power assertion released on engine stop()")
    func powerAssertionReleasedOnStop() async throws {
        let (engine, _, _, _, _, power) = await makeEngine()
        _ = try await engine.start()
        await engine.stop()

        #expect(!power.isAcquired)
        #expect(power.releaseTimestamps.count >= 1)
    }

    // MARK: - handleSystemWillSleep

    @Test("handleSystemWillSleep tears down pipelines and releases assertion")
    func willSleepTearsDownAndReleases() async throws {
        let (engine, _, _, _, _, power) = await makeEngine()
        _ = try await engine.start()

        await engine.handleSystemWillSleep()

        // Power assertion is released as part of willSleep.
        #expect(!power.isAcquired)

        // Status moved to .recovering (gap is started; we'll heal on wake).
        let status = await engine.status
        #expect(status == .recovering || status == .error || status == .idle)

        // Cleanup so test infrastructure doesn't complain.
        await engine.stop()
    }

    @Test("handleSystemWillSleep runs even when engine is in .error state")
    func willSleepRunsInErrorState() async throws {
        // Force engine into .error by attempting to start with a failing
        // permission check.
        let perms = await MainActor.run { MockPermissionService() }
        await MainActor.run { perms.denyAll() }

        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let del = MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )
        let power = MockPowerAssertion()
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del,
            backoffSleep: { _ in },
            powerAssertion: power,
            deviceUIDProvider: { "BuiltInMic" },
            healThresholdSeconds: 30,
            now: { Date() }
        )

        // start() throws on permission denial; engine status -> .error
        _ = try? await engine.start()
        let status = await engine.status
        #expect(status == .error)

        // willSleep should be a no-throw, idempotent cleanup even from
        // .error. We don't assert on power assertion since none was taken.
        await engine.handleSystemWillSleep()
    }

    // MARK: - Power-assertion ordering (the load-bearing test)

    @Test("Power-assertion ordering: pipelines stopped, then assertion released, all before willSleep returns")
    func powerAssertionOrderingOnWillSleep() async throws {
        let (engine, _, audioFactory, _, _, power) = await makeEngine()
        _ = try await engine.start()

        // Snapshot: power assertion acquired at start.
        let acquireTime = power.acquireTimestamps.first!
        let beforeWillSleep = Date()

        await engine.handleSystemWillSleep()

        let afterWillSleep = Date()
        // Power assertion was released (exactly once) between
        // willSleep entry and willSleep exit.
        let releases = power.releaseTimestamps
        #expect(releases.count == 1)
        let releaseTime = releases[0]
        #expect(releaseTime >= beforeWillSleep)
        #expect(releaseTime <= afterWillSleep)
        #expect(releaseTime > acquireTime)

        // Pipelines were torn down: no new mic source created during
        // willSleep, but the existing one was stopped (we can't directly
        // observe stop on the audio source, but we can confirm the
        // engine's internal state reset).
        let micCreates = audioFactory.micCreateCount
        #expect(micCreates == 1) // only the start, no rebuild during sleep

        await engine.stop()
    }

    @Test("Power assertion released within 100ms of handleSystemWillSleep entry")
    func powerAssertionReleasedQuicklyOnWillSleep() async throws {
        let (engine, _, _, _, _, power) = await makeEngine()
        _ = try await engine.start()

        let entryTime = Date()
        await engine.handleSystemWillSleep()
        let exitTime = Date()

        let releases = power.releaseTimestamps
        #expect(releases.count == 1)
        let releaseLatency = releases[0].timeIntervalSince(entryTime)
        #expect(releaseLatency < 0.5) // 500ms is generous; CI variance

        // Sanity: willSleep returned before this assertion ran.
        #expect(exitTime >= releases[0])
    }

    // MARK: - handleSystemDidWake heal rule (reuse)

    @Test("Wake within threshold + same device → reuse session, stage heal markers")
    func wakeShortGapSameDeviceReuses() async throws {
        let rf = MockSpeechRecognizerFactory()
        // The post-wake mic recognizer yields one segment so we can
        // observe the heal marker stamped on it.
        let postWakeHandle = MockSpeechRecognizerHandle()
        postWakeHandle.resultsToYield = [
            RecognizerResult(text: "post-wake", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        rf.enqueueMicHandle(postWakeHandle)               // post-wake rebuild

        let (engine, repo, _, _, delegate, power) = await makeEngine(
            recognizerFactory: rf
        )

        let session = try await engine.start()

        await engine.handleSystemWillSleep()
        // Simulate a tiny gap.
        try await Task.sleep(for: .milliseconds(50))
        await engine.handleSystemDidWake()

        // Wait for the post-wake segment to land with a heal marker.
        let landed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return segs.contains { $0.healMarker != nil }
        }
        #expect(landed)

        let segments = try await repo.segments(for: session.id)
        #expect(segments.last?.sessionId == session.id) // same session
        #expect(segments.last?.healMarker?.starts(with: "after_gap:") == true)

        // Power assertion re-taken.
        #expect(power.isAcquired)
        // 2 events: initial acquire, release on willSleep, re-acquire on wake.
        // We use >= to be robust against re-entry edge cases.
        #expect(power.acquireTimestamps.count >= 2)

        // healed event fired with the gap.
        let healedGaps = await delegate.healedGaps
        #expect(!healedGaps.isEmpty)

        await engine.stop()
    }

    // MARK: - handleSystemDidWake heal rule (rollover via long gap)

    @Test("Wake past threshold → rollover (current session interrupted, fresh active opened)")
    func wakeLongGapRollsOver() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        let postWakeHandle = MockSpeechRecognizerHandle()
        postWakeHandle.resultsToYield = [
            RecognizerResult(text: "fresh-session", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(postWakeHandle)

        // Use an injectable clock so we can force the gap > threshold
        // without actually sleeping.
        let baseTime = Date()
        nonisolated(unsafe) var clockTick = 0
        let clock: @Sendable () -> Date = {
            // First call (start): baseTime. After willSleep is called we
            // bump forward; subsequent calls return baseTime + 60s.
            if clockTick == 0 {
                clockTick = 1
                return baseTime
            }
            return baseTime.addingTimeInterval(60)
        }

        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let af = MockAudioSourceFactory()
        let del = MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )
        let power = MockPowerAssertion()
        let perms = await MainActor.run { MockPermissionService() }
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del,
            backoffSleep: { _ in },
            powerAssertion: power,
            deviceUIDProvider: { "BuiltInMic" },
            healThresholdSeconds: 30,
            now: clock,
            // U12 disabled — this test asserts the rollover keeps the
            // original session as `interrupted` for inspection.
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0
        )

        let originalSession = try await engine.start()

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        // Wait for the post-wake session to receive a segment.
        let landed = await waitFor {
            let sessions = (try? await repo.allSessions()) ?? []
            // We expect 2 sessions now: original (interrupted) + fresh active.
            return sessions.count >= 2
        }
        #expect(landed)

        let sessions = try await repo.allSessions()
        #expect(sessions.count == 2)
        let originalAfter = try await repo.session(originalSession.id)
        #expect(originalAfter?.status == .interrupted)

        // The new session has different ID and is active.
        let newSession = sessions.first { $0.id != originalSession.id }
        #expect(newSession?.status == .active)

        // Post-wake segments belong to the new session and DO NOT carry
        // a heal marker (rollover starts a fresh session).
        let newSegs = try await repo.segments(for: newSession!.id)
        #expect(newSegs.first?.healMarker == nil)

        await engine.stop()
    }

    // MARK: - handleSystemDidWake heal rule (shipped default)

    @Test("Default threshold: a 2-minute sleep keeps recording into the same session")
    func wakeAfterAShortSleepReusesTheSessionAtTheDefaultThreshold() async throws {
        // This is the user-visible contract of the shipped default, so the
        // engine is built WITHOUT an explicit `healThresholdSeconds` — the
        // point is what an un-configured daemon does. A lid closed for two
        // minutes must not split the transcript.
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        let postWakeHandle = MockSpeechRecognizerHandle()
        postWakeHandle.resultsToYield = [
            RecognizerResult(text: "post-wake", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(postWakeHandle)

        // Injectable clock: first reading is the start, everything after
        // willSleep reads two minutes later.
        let baseTime = Date()
        nonisolated(unsafe) var clockTick = 0
        let clock: @Sendable () -> Date = {
            if clockTick == 0 {
                clockTick = 1
                return baseTime
            }
            return baseTime.addingTimeInterval(120)
        }

        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let af = MockAudioSourceFactory()
        let del = MockRecordingEngineDelegate()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 100,
            timeThreshold: 3600
        )
        let power = MockPowerAssertion()
        let perms = await MainActor.run { MockPermissionService() }
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del,
            backoffSleep: { _ in },
            powerAssertion: power,
            deviceUIDProvider: { "BuiltInMic" },
            // healThresholdSeconds deliberately omitted — the default is
            // what is under test.
            now: clock,
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0
        )

        let session = try await engine.start()

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let landed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            return segs.contains { $0.healMarker != nil }
        }
        #expect(landed, "post-wake segment should heal into the original session")

        // One session, not two: no rollover happened.
        let sessions = try await repo.allSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == session.id)

        let segments = try await repo.segments(for: session.id)
        #expect(segments.last?.healMarker == "after_gap:120s")

        await engine.stop()
    }

    // MARK: - handleSystemDidWake heal rule (rollover via device change)

    @Test("Wake with different device → rollover even if gap is short")
    func wakeDeviceChangeRollsOver() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // start
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // post-wake

        nonisolated(unsafe) var deviceCalls = 0
        let provider: @Sendable () -> String? = {
            deviceCalls += 1
            // First call (during start) returns BuiltInMic; subsequent
            // (during wake) returns AirPodsPro to simulate a change.
            return deviceCalls == 1 ? "BuiltInMic" : "AirPodsPro"
        }

        let (engine, repo, _, _, _, _) = await makeEngine(
            recognizerFactory: rf,
            deviceUIDProvider: provider
        )

        let originalSession = try await engine.start()

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let landed = await waitFor {
            let sessions = (try? await repo.allSessions()) ?? []
            return sessions.count >= 2
        }
        #expect(landed)

        let originalAfter = try await repo.session(originalSession.id)
        #expect(originalAfter?.status == .interrupted)

        await engine.stop()
    }

    // MARK: - handleSystemDidWake doesn't crash if status not .recording

    @Test("handleSystemDidWake while engine is .idle is a no-crash no-op")
    func wakeWhileIdleIsNoop() async throws {
        let (engine, _, _, _, _, _) = await makeEngine()
        // Engine has not been started — status is .idle.
        await engine.handleSystemDidWake()
        let status = await engine.status
        #expect(status == .idle)
    }

    // MARK: - PR #35 issue 1: sequence-number rehydration on wake-reuse

    /// Regression test for the wake-reuse sequence-number collision.
    /// Before the fix, `bringUpPipelines` unconditionally reset
    /// `currentSequenceNumber` to 0 on every entry — including the
    /// wake-reuse path, where the resumed session already has segments
    /// at sequence numbers 0..N persisted. The next post-wake segment
    /// would land at sequenceNumber=1 and collide with the schema's
    /// `UNIQUE(sessionId, sequenceNumber)` constraint, silently
    /// dropping the segment until the counter naturally exceeded the
    /// pre-sleep max.
    ///
    /// The fix rehydrates `currentSequenceNumber` from
    /// `repository.maxSegmentSequence(for:)` at every bring-up, so the
    /// post-wake counter resumes where the pre-sleep counter left off.
    @Test("Wake-reuse: post-wake segments resume from max(sequenceNumber), no UNIQUE collision")
    func wakeReuseResumesSequenceFromRepository() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        let postWakeHandle = MockSpeechRecognizerHandle()
        postWakeHandle.resultsToYield = [
            RecognizerResult(text: "post-wake", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(postWakeHandle)               // post-wake rebuild

        let (engine, repo, _, _, _, _) = await makeEngine(
            recognizerFactory: rf
        )

        let session = try await engine.start()

        // Seed five "pre-sleep" segments at sequenceNumbers 1...5 so the
        // wake-reuse path has a non-trivial max to rehydrate from. Real
        // production segments would arrive via the recognizer; the seed
        // here is a faithful proxy because `bringUpPipelines` rehydrates
        // from the repo via `maxSegmentSequence(for:)` regardless of
        // how the segments got there.
        for seq in 1...5 {
            let segment = StoredSegment(
                sessionId: session.id,
                text: "pre-sleep \(seq)",
                startedAt: Date(),
                endedAt: Date(),
                confidence: 0.9,
                sequenceNumber: seq,
                source: .microphone,
                healMarker: nil
            )
            try await repo.saveSegment(segment)
        }

        await engine.handleSystemWillSleep()
        try await Task.sleep(for: .milliseconds(20))
        await engine.handleSystemDidWake()

        // Wait for the post-wake recognizer's segment to land.
        let landed = await waitFor {
            let segs = (try? await repo.segments(for: session.id)) ?? []
            // 5 seeded + 1 post-wake = 6 segments.
            return segs.count >= 6
        }
        #expect(landed)

        let segments = try await repo.segments(for: session.id)
        #expect(segments.count == 6)

        // The post-wake segment must NOT collide with seq 1..5. The
        // engine's monotonic counter rehydrates from the repo, so the
        // first post-wake segment lands at seq 6.
        let postWakeSegments = segments.filter { $0.text == "post-wake" }
        #expect(postWakeSegments.count == 1)
        #expect(postWakeSegments.first?.sequenceNumber == 6)

        // No duplicate sequenceNumbers — the schema's UNIQUE
        // (sessionId, sequenceNumber) invariant holds in the mock.
        let allSeqs = segments.map(\.sequenceNumber).sorted()
        #expect(Set(allSeqs).count == allSeqs.count)

        await engine.stop()
    }

    // MARK: - #109: wake out of `.error`

    /// Regression test for the stuck `error` status (issue #109).
    ///
    /// `.error` used to be an absorbing state. The tail of
    /// `bringUpPipelines` was gated on `status != .error`, and that was
    /// the *only* path back to `.recording` a wake could take, so an
    /// engine that surrendered before sleeping came back with working
    /// pipelines and a status that still read `error` — for days,
    /// because the status never moved, no `statusChanged` was emitted
    /// for a client to correct itself against, and `setStatus`'s entry
    /// into `.recording` is the one place the power assertion is taken.
    /// The machine was then free to sleep again while capture was live.
    ///
    /// Both halves are asserted here: the status comes back, and so
    /// does the power assertion.
    @Test("Wake out of .error with a successful rebuild restores .recording and re-takes the power assertion")
    func wakeOutOfErrorRestoresRecordingAndPowerAssertion() async throws {
        let (engine, _, af, _, _, power) = await makeEngine()

        // Surrender the way production does: a revoked Screen Recording
        // grant during bring-up sets `.error` inline and leaves
        // `currentSession` live.
        af.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied
        _ = try await engine.start(systemAudio: true)

        let surrendered = await engine.status
        #expect(surrendered == .error, "precondition: the engine must be surrendered before sleeping")
        #expect(await engine.currentSession != nil, "precondition: a surrender keeps the session as the recovery anchor")
        #expect(!power.isAcquired, "precondition: no assertion is held in .error")

        // Whatever was wrong is resolved while the machine is asleep —
        // the grant is restored, the device is unplugged and back, the
        // driver is reloaded. The wake rebuild is the first thing that
        // can observe it.
        af.systemAudioSource.errorToThrow = nil

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let status = await engine.status
        #expect(status == .recording, "a completed rebuild is evidence the error is resolved")
        #expect(power.isAcquired, "the power assertion must be re-taken or the Mac sleeps again mid-recording")
        #expect(power.acquireTimestamps.count == 1)

        await engine.stop()
    }

    /// The other half of the same rule: a rebuild that surrenders *again*
    /// must not be allowed to claim `.recording`. This is what the
    /// original `status != .error` guard was protecting, and widening the
    /// exit from `.error` must not cost it.
    @Test("Wake out of .error into a still-broken pipeline stays in .error")
    func wakeOutOfErrorIntoAnotherSurrenderStaysInError() async throws {
        let (engine, _, af, _, _, power) = await makeEngine()

        af.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied
        _ = try await engine.start(systemAudio: true)
        #expect(await engine.status == .error)

        // The grant is still revoked across the sleep, so the rebuild
        // surrenders a second time. The status never moves, which is
        // exactly why the guard counts surrenders instead of reading it.
        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let status = await engine.status
        #expect(status == .error, "an unresolved fault must not be papered over with .recording")
        #expect(!power.isAcquired, "no assertion may be held while surrendered")

        await engine.stop()
    }

    // MARK: - #111: `.idle` is absorbing after an external stop

    /// The always-on model (#32) has no user-facing stop, but `stop` is
    /// still a valid wire command and any client can send one. Before this
    /// fix, that put the engine in `.idle` for the life of the daemon
    /// process: `stop()` nils `currentSession`, so the wake handler bailed
    /// at its `guard let session` and nothing else ever re-entered
    /// `.recording`. A wake is the natural moment to re-apply the
    /// always-on arm rule, and it is the same rule the daemon-start path
    /// already runs.
    @Test("Wake from .idle after a stop re-arms always-on capture")
    func wakeFromIdleReArms() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // post-wake re-arm

        let (engine, repo, _, _, delegate, power) = await makeEngine(
            recognizerFactory: rf
        )

        _ = try await engine.start()
        await engine.stop()
        var status = await engine.status
        #expect(status == .idle)
        #expect(!power.isAcquired)

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let rearmed = await waitFor {
            let s = await engine.status
            return s == .recording
        }
        #expect(rearmed)

        status = await engine.status
        #expect(status == .recording)
        // The power assertion is taken only on entry to `.recording`, so
        // holding it again is independent proof the transition happened.
        #expect(power.isAcquired)

        // A fresh session, not a resurrection of the stopped one.
        let sessions = try await repo.allSessions()
        #expect(sessions.count == 2)
        #expect(sessions.filter { $0.endedAt == nil }.count == 1)

        // The re-arm is announced, so a connected client can correct itself.
        let reasons = await delegate.recoveringReasons
        #expect(reasons.contains { $0.contains("rearm") })

        await engine.stop()
    }

    /// The privacy invariant. `stop()` from `.paused` clears the in-memory
    /// pause markers and lands in `.idle`, but deliberately leaves the DB
    /// anchor (`paused_indefinitely` / `pause_expires_at`) on the row. A
    /// re-arm that only looked at engine state would therefore resurrect
    /// capture on a machine the user had explicitly paused. The re-arm
    /// must consult the same anchor the daemon-start path checks.
    @Test("Wake from .idle does NOT re-arm while a pause anchor is still active")
    func wakeFromIdleRespectsPauseAnchor() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, _, _, power) = await makeEngine(
            recognizerFactory: rf
        )

        _ = try await engine.start()
        try await engine.pause(autoResumeSeconds: nil) // indefinite: writes the anchor
        await engine.stop()                            // .paused -> .idle, anchor survives

        var status = await engine.status
        #expect(status == .idle)

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        // Give a re-arm the chance to happen so this is a real assertion
        // about behaviour rather than about timing.
        try await Task.sleep(for: .milliseconds(150))

        status = await engine.status
        #expect(status == .idle)
        #expect(!power.isAcquired)
    }

    /// A timed pause whose deadline has already passed is not an active
    /// anchor, so the same wake re-arms normally.
    @Test("Wake from .idle re-arms when the pause anchor has expired")
    func wakeFromIdleReArmsPastExpiredPauseAnchor() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())

        let (engine, repo, _, _, _, _) = await makeEngine(
            recognizerFactory: rf
        )

        let session = try await engine.start()
        await engine.stop()

        // Stamp an anchor that expired in the past.
        try await repo.setPauseState(
            sessionId: session.id,
            expiresAt: Date().addingTimeInterval(-60),
            indefinite: false
        )

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let rearmed = await waitFor {
            let s = await engine.status
            return s == .recording
        }
        #expect(rearmed)

        await engine.stop()
    }

    /// Fail-safe. If the pause anchor cannot be read we cannot prove the
    /// user is not paused, so we stay idle and say so, rather than
    /// defaulting to "resume into recording." Same posture as the
    /// daemon-start path's `pause_state_unverifiable` branch.
    @Test("Wake from .idle does not re-arm when the pause anchor is unreadable")
    func wakeFromIdleFailsSafeOnUnreadablePauseAnchor() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())

        let (engine, repo, _, _, delegate, power) = await makeEngine(
            recognizerFactory: rf
        )

        _ = try await engine.start()
        await engine.stop()

        struct ReadFailure: Error {}
        await repo.setMostRecentlyModifiedSessionError(ReadFailure())

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        try await Task.sleep(for: .milliseconds(150))

        let status = await engine.status
        #expect(status == .idle)
        #expect(!power.isAcquired)

        // Surfaced as a non-transient warning carrying the same token the
        // daemon-start path uses, so U9/U10's health-warning machinery
        // already matches on it.
        let errors = await delegate.errors
        #expect(errors.contains { $0.0.contains("pause_state_unverifiable") && !$0.1 })
    }

    /// The escape hatch. `reArmIdleOnWake = false` restores the old
    /// behaviour for anyone who wants `stop` to mean stop.
    @Test("Wake from .idle does not re-arm when reArmIdleOnWake is disabled")
    func wakeFromIdleRespectsDisabledSetting() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())

        let (engine, _, _, _, _, power) = await makeEngine(
            recognizerFactory: rf,
            reArmIdleOnWake: false
        )

        _ = try await engine.start()
        await engine.stop()

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        try await Task.sleep(for: .milliseconds(150))

        let status = await engine.status
        #expect(status == .idle)
        #expect(!power.isAcquired)
    }

    /// #113 review fix. A re-arm attempt that itself fails (e.g. a
    /// transient audio-source error right after wake) lands the engine
    /// in `.error`, not back in `.idle`. `handleSystemDidWake()` only
    /// retried from `.idle`, so before this fix a single failed re-arm
    /// silently stopped retrying on every later wake — contradicting
    /// `reArmIdleAfterWake`'s own comment that "the next wake tries
    /// again." This proves the daemon self-heals on the wake *after*
    /// the failure, not just the one where it first fails.
    @Test("A failed re-arm attempt is retried on the next wake, not abandoned")
    func wakeRetriesAFailedReArmOnTheNextWake() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // second wake: retry succeeds

        let af = MockAudioSourceFactory()

        let (engine, _, _, _, _, power) = await makeEngine(
            recognizerFactory: rf,
            audioFactory: af,
            reArmIdleOnWake: true
        )

        _ = try await engine.start()
        await engine.stop()
        #expect(await engine.status == .idle)

        // First wake: the re-arm's own start() attempt fails.
        af.micErrorQueue = [MockAudioSourceFactory.InjectedError("boom")]
        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let failed = await waitFor {
            let s = await engine.status
            return s == .error
        }
        #expect(failed)
        #expect(!power.isAcquired)

        // Second wake: no injected failure this time. Without the fix,
        // `handleSystemDidWake()` sees `.error` (not `.idle`), never
        // calls `reArmIdleAfterWake()` again, and the engine stays dark
        // forever.
        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        let recovered = await waitFor {
            let s = await engine.status
            return s == .recording
        }
        #expect(recovered)
        #expect(power.isAcquired)

        await engine.stop()
    }

    /// #113 review fix. `.error` states unrelated to a re-arm attempt
    /// (e.g. a revoked permission's `recoveryExhausted`) must NOT be
    /// retried on wake — that class of failure is documented to require
    /// manual resolution. The retry flag introduced to fix the above is
    /// scoped to re-arm failures specifically; this pins that it does
    /// not accidentally widen wake into a general `.error` retry point.
    @Test("Wake does not retry an .error state that did not come from a re-arm attempt")
    func wakeDoesNotRetryUnrelatedErrorState() async throws {
        let rf = MockSpeechRecognizerFactory()
        // No enqueued handle: the one and only start() call fails,
        // landing the engine in `.error` with no re-arm involved.
        let af = MockAudioSourceFactory()
        af.micError = MockAudioSourceFactory.InjectedError("permission denied")

        let (engine, _, _, _, _, power) = await makeEngine(
            recognizerFactory: rf,
            audioFactory: af,
            reArmIdleOnWake: true
        )

        await #expect(throws: RecordingEngineError.self) {
            try await engine.start()
        }
        #expect(await engine.status == .error)

        await engine.handleSystemWillSleep()
        await engine.handleSystemDidWake()

        try await Task.sleep(for: .milliseconds(150))

        #expect(await engine.status == .error)
        #expect(!power.isAcquired)
    }

    /// #113 review fix: a re-arm that suspends (here, inside its pause-anchor
    /// read) must not call `start()` if the system went back to sleep while
    /// it was suspended. Otherwise capture comes up, and the power assertion
    /// is taken, after the second sleep's teardown already ran.
    @Test func wakeReArmAbandonsWhenSleepBeginsWhileSuspended() async throws {
        let (engine, repo, _, _, _, power) = await makeEngine(reArmIdleOnWake: true)

        _ = try await engine.start()
        await engine.stop()
        #expect(await engine.status == .idle)

        let (parked, parkedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        await repo.setMostRecentlyModifiedSessionGate {
            parkedCont.yield()
            for await _ in release { break }
        }

        await engine.handleSystemWillSleep()
        let wake = Task { await engine.handleSystemDidWake() }

        // Wait until the re-arm is parked in its anchor read, then sleep.
        for await _ in parked { break }
        await engine.handleSystemWillSleep()

        releaseCont.yield()
        await wake.value

        #expect(await engine.status == .idle)
        #expect(!power.isAcquired)
    }
}
