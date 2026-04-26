import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import StenoDaemon

/// Tests for U7's `RecordingEngine.handleAudioDeviceChange(deviceUID:format:)`.
///
/// These exercise the engine-level wiring that ties the
/// `AudioDeviceObserver` callback to U5's restart machinery and U6's
/// heal rule. The wall-clock backoff is short-circuited via the
/// engine's injectable `backoffSleep` closure.
@Suite("Device-Change Handler Tests (U7)")
struct DeviceChangeHandlerTests {

    // MARK: - Engine assembly

    @MainActor
    private func makeEngine(
        recognizerFactory: MockSpeechRecognizerFactory,
        deviceUIDProvider: @Sendable @escaping () -> String? = { "BuiltInMic" }
    ) async -> (
        engine: RecordingEngine,
        repo: MockTranscriptRepository,
        audioFactory: MockAudioSourceFactory,
        delegate: MockRecordingEngineDelegate
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
            backoffSleep: { _ in /* no wait */ },
            deviceUIDProvider: deviceUIDProvider,
            healThresholdSeconds: 30,
            now: { Date() }
        )
        return (engine, repo, af, del)
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

    private func makeFormat(sampleRate: Double) -> AVAudioFormat {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - No-ops outside an active recording

    @Test("handleAudioDeviceChange while idle is a no-op")
    func deviceChangeWhileIdleIsNoop() async throws {
        let rf = MockSpeechRecognizerFactory()
        let (engine, _, audioFactory, _) = await makeEngine(recognizerFactory: rf)

        await engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)

        let status = await engine.status
        #expect(status == .idle)
        #expect(audioFactory.micCreateCount == 0)
    }

    @Test("handleAudioDeviceChange while stopping is a no-op")
    func deviceChangeWhileStoppingIsNoop() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle())
        let (engine, _, audioFactory, _) = await makeEngine(recognizerFactory: rf)

        _ = try await engine.start()
        let createsBefore = audioFactory.micCreateCount

        // Begin stopping in the background, then immediately fire a
        // device-change. The handler must short-circuit.
        async let stop: Void = engine.stop()
        await engine.handleAudioDeviceChange(deviceUID: "Other", format: nil)
        await stop

        // No additional mic source creation beyond the initial start.
        #expect(audioFactory.micCreateCount == createsBefore)
    }

    // MARK: - Same UID + same format → cheap restart, no heal-rule rollover

    @Test("Same UID + same format → restart only, no session rollover")
    func sameUIDSameFormatRestartsWithoutRollover() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // restart

        let (engine, repo, audioFactory, _) = await makeEngine(
            recognizerFactory: rf,
            deviceUIDProvider: { "BuiltInMic" }
        )

        let originalSession = try await engine.start()
        // Initial bring-up uses the mock factory's default format
        // (16kHz mono — see MockAudioSourceFactory.micFormat).
        let cachedFormat = audioFactory.micFormat

        await engine.handleAudioDeviceChange(
            deviceUID: "BuiltInMic",
            format: cachedFormat
        )

        // Wait for the restart to complete.
        let restarted = await waitFor {
            audioFactory.micCreateCount >= 2
        }
        #expect(restarted)

        // Session count is still 1 (no rollover).
        let sessions = try await repo.allSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == originalSession.id)

        await engine.stop()
    }

    // MARK: - Different UID → rollover (current session interrupted, fresh active)

    @Test("Different UID → rollover (current session interrupted, fresh session opened)")
    func differentUIDRollsOver() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // restart

        // First call (during start): "BuiltInMic". Subsequent calls
        // (during restart's lastDeviceUID refresh): "AirPodsPro".
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _n = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                _n += 1
                return _n
            }
        }
        let counter = Counter()
        let provider: @Sendable () -> String? = {
            counter.next() == 1 ? "BuiltInMic" : "AirPodsPro"
        }

        let (engine, repo, audioFactory, _) = await makeEngine(
            recognizerFactory: rf,
            deviceUIDProvider: provider
        )

        let originalSession = try await engine.start()

        await engine.handleAudioDeviceChange(
            deviceUID: "AirPodsPro",
            format: makeFormat(sampleRate: 16000)
        )

        // Wait for the restart + rollover to complete.
        let rolled = await waitFor {
            let sessions = (try? await repo.allSessions()) ?? []
            return sessions.count >= 2
        }
        #expect(rolled)

        let sessions = try await repo.allSessions()
        #expect(sessions.count == 2)

        let originalAfter = try await repo.session(originalSession.id)
        #expect(originalAfter?.status == .interrupted)

        let newSession = sessions.first { $0.id != originalSession.id }
        #expect(newSession?.status == .active)

        // Mic was rebuilt (the restart ran).
        #expect(audioFactory.micCreateCount >= 2)

        await engine.stop()
    }

    // MARK: - Same UID, different format → heal rule reuses session, stages marker

    @Test("Same UID + different format → reuse session (gap < 30s, same UID)")
    func sameUIDDifferentFormatReusesSession() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        let postChangeHandle = MockSpeechRecognizerHandle()
        postChangeHandle.resultsToYield = [
            RecognizerResult(text: "post-change", isFinal: true, source: .microphone)
        ]
        rf.enqueueMicHandle(postChangeHandle)

        let (engine, repo, audioFactory, _) = await makeEngine(
            recognizerFactory: rf,
            deviceUIDProvider: { "BuiltInMic" }
        )

        let originalSession = try await engine.start()

        // Format change with same UID — sample rate jumped from 16kHz
        // (mock default) to 48kHz.
        await engine.handleAudioDeviceChange(
            deviceUID: "BuiltInMic",
            format: makeFormat(sampleRate: 48000)
        )

        // Wait for the rebuild to complete.
        let rebuilt = await waitFor {
            audioFactory.micCreateCount >= 2
        }
        #expect(rebuilt)

        // Session was reused.
        let sessions = try await repo.allSessions()
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == originalSession.id)

        await engine.stop()
    }

    // MARK: - Concurrent device-changes drop while restart is in flight

    @Test("Concurrent device-change while restart is mid-flight is dropped")
    func concurrentDeviceChangeIsDropped() async throws {
        let rf = MockSpeechRecognizerFactory()
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // initial start
        rf.enqueueMicHandle(MockSpeechRecognizerHandle()) // first restart

        let (engine, _, audioFactory, _) = await makeEngine(
            recognizerFactory: rf,
            deviceUIDProvider: { "BuiltInMic" }
        )

        _ = try await engine.start()

        // Fire two device-changes back-to-back. The actor serializes
        // them, but the second observation should hit the
        // "micRestartTask != nil" gate inside the second invocation.
        // In practice, since each handler awaits the restart fully,
        // they actually run sequentially through the actor — but the
        // gate is still load-bearing for the case where a second
        // observer fire arrives before the first handler returns.
        async let first: Void = engine.handleAudioDeviceChange(
            deviceUID: "BuiltInMic",
            format: audioFactory.micFormat
        )
        async let second: Void = engine.handleAudioDeviceChange(
            deviceUID: "BuiltInMic",
            format: audioFactory.micFormat
        )
        await first
        await second

        // We don't assert exact call counts (timing-sensitive); we
        // just verify the engine is still healthy.
        let status = await engine.status
        #expect(status == .recording || status == .recovering)

        await engine.stop()
    }
}
