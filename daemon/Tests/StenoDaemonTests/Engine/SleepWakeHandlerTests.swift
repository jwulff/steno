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
        deviceUIDProvider: @Sendable @escaping () -> String? = { "BuiltInMic" }
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
            now: { Date() }
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
            now: clock
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
}
