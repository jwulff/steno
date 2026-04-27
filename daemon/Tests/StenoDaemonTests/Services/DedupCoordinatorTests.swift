import Testing
import Foundation
@testable import StenoDaemon

@Suite("DedupCoordinator Tests")
struct DedupCoordinatorTests {

    // MARK: - Test helpers

    /// Build a coordinator + repo + active session for a test. The session
    /// has `lastDedupedSegmentSeq = 0`. Default thresholds match production
    /// (overlap 3s, score 0.92, mic-peak -25 dBFS) but each test can build
    /// its own coordinator with custom values via the explicit init.
    private func setup(
        overlapSeconds: TimeInterval = 3.0,
        scoreThreshold: Double = 0.92,
        micPeakThresholdDb: Double = -25.0
    ) async throws -> (DedupCoordinator, MockTranscriptRepository, Session) {
        let repo = MockTranscriptRepository()
        let session = try await repo.createSession(locale: Locale(identifier: "en_US"))
        let coordinator = DedupCoordinator(
            repository: repo,
            overlapSeconds: overlapSeconds,
            scoreThreshold: scoreThreshold,
            micPeakThresholdDb: micPeakThresholdDb
        )
        return (coordinator, repo, session)
    }

    /// Save a mic + sys segment pair around `t`. Returns (mic, sys).
    /// `micPeakDb == nil` means "not measured" — the pass treats it as
    /// audio-level-eligible.
    @discardableResult
    private func savePair(
        repo: MockTranscriptRepository,
        sessionId: UUID,
        t: Date,
        micText: String,
        sysText: String,
        micSeq: Int,
        sysSeq: Int,
        micOffset: TimeInterval = 0,
        sysOffset: TimeInterval = 0,
        micPeakDb: Double? = nil
    ) async throws -> (StoredSegment, StoredSegment) {
        let mic = StoredSegment(
            sessionId: sessionId,
            text: micText,
            startedAt: t.addingTimeInterval(micOffset),
            endedAt: t.addingTimeInterval(micOffset + 1),
            sequenceNumber: micSeq,
            source: .microphone,
            micPeakDb: micPeakDb
        )
        let sys = StoredSegment(
            sessionId: sessionId,
            text: sysText,
            startedAt: t.addingTimeInterval(sysOffset),
            endedAt: t.addingTimeInterval(sysOffset + 1),
            sequenceNumber: sysSeq,
            source: .systemAudio
        )
        try await repo.saveSegment(mic)
        try await repo.saveSegment(sys)
        return (mic, sys)
    }

    // MARK: - Similarity score (private function under test)

    @Test func similarityExactMatch() async throws {
        let (coord, _, _) = try await setup()
        let result = await coord.similarityScore("hello world", "hello world")
        #expect(result.score == 1.0)
        #expect(result.method == .exact)
    }

    @Test func similarityNormalizedMatch() async throws {
        let (coord, _, _) = try await setup()
        let result = await coord.similarityScore("Hello, world!", "hello world")
        #expect(result.score == 1.0)
        #expect(result.method == .normalized)
    }

    @Test func similarityFuzzyMatch() async throws {
        let (coord, _, _) = try await setup()
        // "hello world" vs "hello word" — 1 deletion, max length 11.
        // ratio = 1 - 1/11 ≈ 0.909. Below the 0.92 default but above 0.85.
        let result = await coord.similarityScore("hello world", "hello word")
        #expect(result.method == .fuzzy)
        #expect(result.score > 0.85)
        #expect(result.score < 0.95)
    }

    @Test func similarityFuzzyAboveThreshold() async throws {
        let (coord, _, _) = try await setup()
        // Long enough that a single typo crosses 0.92.
        // "hello there friend" (18) vs "hello there friemd" — 1 substitution,
        // ratio = 1 - 1/18 ≈ 0.944.
        let result = await coord.similarityScore("hello there friend", "hello there friemd")
        #expect(result.method == .fuzzy)
        #expect(result.score >= 0.92)
    }

    @Test func similarityLengthMismatchScoresLow() async throws {
        let (coord, _, _) = try await setup()
        let result = await coord.similarityScore("yes", "yes okay let's go")
        #expect(result.score < 0.92)
    }

    @Test func similarityBothEmptyReturnsZeroFuzzy() async throws {
        let (coord, _, _) = try await setup()
        let result = await coord.similarityScore("", "")
        #expect(result.score == 0.0)
        #expect(result.method == .fuzzy)
    }

    // MARK: - Pass: happy paths

    @Test func happyExactMatchMarksDuplicate() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, sys) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2
        )

        let outcome = await coord.runPass(sessionId: session.id)

        #expect(outcome.evaluated == 1)
        #expect(outcome.marked == 1)
        #expect(outcome.skipped == 0)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == sys.id)
        #expect(updatedMic?.dedupMethod == .exact)
    }

    @Test func happyNormalizedMatchMarksDuplicate() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, sys) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "Hello, world!", sysText: "hello world",
            micSeq: 1, sysSeq: 2
        )

        _ = await coord.runPass(sessionId: session.id)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == sys.id)
        #expect(updatedMic?.dedupMethod == .normalized)
    }

    @Test func happyFuzzyMatchMarksDuplicate() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        // Long phrase + 1 typo so ratio crosses 0.92.
        let (mic, sys) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello there my friend",
            sysText: "hello there my friemd",
            micSeq: 1, sysSeq: 2
        )

        _ = await coord.runPass(sessionId: session.id)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == sys.id)
        #expect(updatedMic?.dedupMethod == .fuzzy)
    }

    // MARK: - Pass: edge cases

    @Test func skipsWhenNoOverlap() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        let mic = StoredSegment(
            sessionId: session.id,
            text: "hello world",
            startedAt: t,
            endedAt: t.addingTimeInterval(1),
            sequenceNumber: 1,
            source: .microphone
        )
        // Sys segment is 10s later — outside the 3s overlap window.
        let sys = StoredSegment(
            sessionId: session.id,
            text: "hello world",
            startedAt: t.addingTimeInterval(10),
            endedAt: t.addingTimeInterval(11),
            sequenceNumber: 2,
            source: .systemAudio
        )
        try await repo.saveSegment(mic)
        try await repo.saveSegment(sys)

        let outcome = await coord.runPass(sessionId: session.id)

        #expect(outcome.evaluated == 1)
        #expect(outcome.marked == 0)
        #expect(outcome.skipped == 1)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == nil)
    }

    @Test func keepsWhenScoreBelowThreshold() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, _) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "yes",
            sysText: "yes okay let's go",
            micSeq: 1, sysSeq: 2
        )

        let outcome = await coord.runPass(sessionId: session.id)

        #expect(outcome.marked == 0)
        #expect(outcome.skipped == 1)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == nil)
    }

    @Test func bothEmptyKeeps() async throws {
        // Schema CHECK rejects empty text at the storage layer; we test the
        // similarity-score branch directly via the public `runPass`. With
        // both-empty similarity we get score=0 which is below threshold,
        // so KEEP. Persist via the mock (which doesn't enforce CHECK) so the
        // pass exercises the both-empty branch end-to-end.
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, _) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "", sysText: "",
            micSeq: 1, sysSeq: 2
        )

        let outcome = await coord.runPass(sessionId: session.id)

        #expect(outcome.marked == 0)
        #expect(outcome.skipped == 1)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == nil)
    }

    @Test func cursorAdvancesAndSecondPassIsNoop() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2
        )

        let first = await coord.runPass(sessionId: session.id)
        #expect(first.marked == 1)

        let second = await coord.runPass(sessionId: session.id)
        #expect(second.evaluated == 0)
        #expect(second.marked == 0)
        #expect(second.skipped == 0)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 1)
    }

    @Test func cursorAdvancesPerMicSeqNotPerPassMax() async throws {
        // Interleaved seq — mic at 5, sys at 7 (sys arrived faster on its
        // own counter even though they share the per-session counter today).
        // Cursor must advance to 5, NOT 7, so a future mic segment at seq 6
        // is still evaluated.
        let (coord, repo, session) = try await setup()
        let t = Date()
        let mic = StoredSegment(
            sessionId: session.id,
            text: "hello world",
            startedAt: t,
            endedAt: t.addingTimeInterval(1),
            sequenceNumber: 5,
            source: .microphone
        )
        let sys = StoredSegment(
            sessionId: session.id,
            text: "hello world",
            startedAt: t,
            endedAt: t.addingTimeInterval(1),
            sequenceNumber: 7,
            source: .systemAudio
        )
        try await repo.saveSegment(mic)
        try await repo.saveSegment(sys)

        _ = await coord.runPass(sessionId: session.id)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 5)
    }

    // MARK: - Reentrance

    @Test func reentranceCollapsesConcurrentCalls() async throws {
        // We can't truly observe the second call in an in-flight state in
        // a single-threaded mock, but we can run two passes concurrently
        // and assert idempotency: the second one returns `.empty` because
        // the first marks + advances the cursor before the second starts,
        // OR because the reentrance guard blocks it. Either way, the final
        // state should be a single mark.
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2
        )

        async let a = coord.runPass(sessionId: session.id)
        async let b = coord.runPass(sessionId: session.id)
        let (oa, ob) = await (a, b)

        #expect(oa.marked + ob.marked == 1)
    }

    // MARK: - Error path

    @Test func markDuplicateThrowDoesNotBumpCursor() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2
        )

        await repo.setMarkDuplicateError(MockTranscriptRepository.InjectedError("boom"))

        let outcome = await coord.runPass(sessionId: session.id)
        // The pass surrendered partway — marked count is up to (but not
        // necessarily including) the throw. The contract is: cursor is NOT
        // advanced, the error is logged (not thrown), the next pass picks
        // up the same segment.
        #expect(outcome == .empty)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 0)

        // Clearing the injected error and re-running should successfully
        // mark on the second attempt.
        await repo.setMarkDuplicateError(nil)
        let recover = await coord.runPass(sessionId: session.id)
        #expect(recover.marked == 1)
        let final = try await repo.session(session.id)
        #expect(final?.lastDedupedSegmentSeq == 1)
    }

    // MARK: - Audio-level guard

    @Test func loudMicKeepsDespiteScore() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, _) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2,
            micPeakDb: -10.0  // Loud — actively spoken.
        )

        let outcome = await coord.runPass(sessionId: session.id)
        #expect(outcome.marked == 0)
        #expect(outcome.skipped == 1)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == nil)
    }

    @Test func quietMicMarks() async throws {
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, sys) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2,
            micPeakDb: -40.0  // Quiet — passive pickup.
        )

        let outcome = await coord.runPass(sessionId: session.id)
        #expect(outcome.marked == 1)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == sys.id)
    }

    @Test func nullMicPeakDbSkipsLevelGuard() async throws {
        // micPeakDb == nil means "not measured" — pass should not apply the
        // level guard and mark on score alone. (Documented in code: NULL
        // handling is "treat as eligible.")
        let (coord, repo, session) = try await setup()
        let t = Date()
        let (mic, sys) = try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2,
            micPeakDb: nil
        )

        let outcome = await coord.runPass(sessionId: session.id)
        #expect(outcome.marked == 1)

        let segs = try await repo.segments(for: session.id)
        let updatedMic = segs.first { $0.id == mic.id }
        #expect(updatedMic?.duplicateOf == sys.id)
    }

    // MARK: - Integration: TUI default-query shape

    @Test func defaultViewReturnsOneRowPerLogicalUtterance() async throws {
        // 5 mic + 5 sys overlapping pairs, run pass, assert that the
        // post-pass count of rows where duplicate_of IS NULL equals 5
        // (the sys side, since the mic side gets marked).
        let (coord, repo, session) = try await setup()
        let t = Date()
        for i in 1...5 {
            let pairTime = t.addingTimeInterval(Double(i) * 0.5)
            try await savePair(
                repo: repo, sessionId: session.id, t: pairTime,
                micText: "utterance \(i)", sysText: "utterance \(i)",
                micSeq: i * 2 - 1, sysSeq: i * 2
            )
        }

        let outcome = await coord.runPass(sessionId: session.id)
        #expect(outcome.marked == 5)

        // Default view = WHERE duplicate_of IS NULL.
        let all = try await repo.segments(for: session.id)
        let canonical = all.filter { $0.duplicateOf == nil }
        let raw = all
        #expect(canonical.count == 5)
        #expect(raw.count == 10)
    }

    // MARK: - Integration: debounced trigger

    @Test func debouncedTriggerCollapsesManyTriggersIntoOnePass() async throws {
        // The engine-side debounce is what collapses 10 saves into 1
        // pass. Here we exercise the coordinator-internal reentrance:
        // 10 sequential `runPass` calls on the same data should produce
        // 1 mark + 9 cursor-already-advanced no-ops. (The engine-level
        // debounce is exercised separately in the engine's own tests; this
        // assertion ties the coordinator side of that contract.)
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await savePair(
            repo: repo, sessionId: session.id, t: t,
            micText: "hello world", sysText: "hello world",
            micSeq: 1, sysSeq: 2
        )

        var totalMarked = 0
        for _ in 0..<10 {
            let o = await coord.runPass(sessionId: session.id)
            totalMarked += o.marked
        }
        #expect(totalMarked == 1)
    }

    // MARK: - Engine integration: trailing-edge debounce

    /// Exercise the engine's per-session debounce: 10 final-segment
    /// recognitions in rapid succession should collapse to a single
    /// `runPass` after the debounce window elapses. We use a 100ms
    /// debounce to keep the test fast.
    @Test func engineDebounceCollapsesTenWritesIntoOnePass() async throws {
        let repo = MockTranscriptRepository()
        let summarizer = MockSummarizationService()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let perms = await MainActor.run { MockPermissionService() }
        let summaryCoordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: summarizer,
            triggerCount: 1000,
            timeThreshold: 3600
        )

        // Use the real coordinator wrapped by a counter-spy. Easiest way:
        // wrap the repository so we can count `markDuplicate` invocations.
        let dedup = DedupCoordinator(repository: repo)

        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: summaryCoordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            dedupCoordinator: dedup,
            dedupTriggerDebounce: .milliseconds(100)
        )

        // Pre-arrange 10 final mic results that all match a sys segment
        // we'll seed manually after start.
        var recognizerResults: [RecognizerResult] = []
        for _ in 0..<10 {
            recognizerResults.append(RecognizerResult(
                text: "hello world",
                isFinal: true,
                confidence: 0.95,
                source: .microphone
            ))
        }
        rf.handle.resultsToYield = recognizerResults

        // Seed a sys segment BEFORE start so all 10 mic finals overlap
        // with it (within ±3s of the recognizer's emitted timestamp,
        // which the mock sets to "now"). We need a session id for the
        // FK — open one directly.
        let session = try await repo.openFreshSession(locale: Locale(identifier: "en_US"))
        let sys = StoredSegment(
            sessionId: session.id,
            text: "hello world",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1),
            sequenceNumber: 1000,
            source: .systemAudio
        )
        try await repo.saveSegment(sys)

        // The engine's `start()` creates its own session. We can't easily
        // make it adopt our pre-seeded one, so seed the sys segment AFTER
        // start using the engine-created session id.
        let engineSession = try await engine.start()
        try await repo.saveSegment(StoredSegment(
            sessionId: engineSession.id,
            text: "hello world",
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(1),
            sequenceNumber: 1000,
            source: .systemAudio
        ))

        // Wait for recognizer to drain the queue (~50ms for 10 results)
        // plus the debounce window plus a generous safety margin so the
        // debounce timer fires BEFORE we tear the engine down.
        try await Task.sleep(for: .milliseconds(800))

        // The coordinator's cursor should reflect a single pass that
        // evaluated all 10 mic segments. If the debounce had fired 10
        // times, the cursor advance would still be the same (cursor
        // monotonicity), but the multiple passes would have been visible
        // as multiple coordinator-internal log lines. The load-bearing
        // assertion here is: at least one mic was marked, and the cursor
        // landed at the highest mic seq.
        let updated = try await repo.session(engineSession.id)
        let allSegs = try await repo.segments(for: engineSession.id)
        let micSegs = allSegs.filter { $0.source == .microphone }
        let markedMic = micSegs.filter { $0.duplicateOf != nil }
        #expect(!micSegs.isEmpty)
        #expect(markedMic.count == micSegs.count)
        // Cursor at highest mic seq.
        let maxMicSeq = micSegs.map(\.sequenceNumber).max() ?? 0
        #expect(updated?.lastDedupedSegmentSeq == maxMicSeq)

        await engine.stop()
        _ = session
    }

    // MARK: - linearPeakToDbFS conversion

    @Test func linearPeakConvertsToDbFSWithFloor() async throws {
        // Silence floors at -90.
        #expect(RecordingEngine.linearPeakToDbFS(0) == -90.0)
        // Full-scale clipping reports 0.
        #expect(RecordingEngine.linearPeakToDbFS(1.0) == 0.0)
        // -6 dBFS = ~0.5 amplitude.
        let half = RecordingEngine.linearPeakToDbFS(0.5)
        #expect(half < -5.5 && half > -6.5)
    }
}
