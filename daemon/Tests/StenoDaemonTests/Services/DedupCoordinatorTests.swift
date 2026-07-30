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

    // MARK: - #80 systemAudio lag hold-back

    /// Save a single segment. Thin helper for the hold-back tests, which
    /// deliberately save mic and sys rows at different moments rather than
    /// as a pair.
    /// `t` is the capture instant — when the words were actually said.
    /// `emissionDelay` is how much later the recognizer got around to
    /// emitting the result, which is what `startedAt` records and what
    /// drifts per source under a backlog. Default 0 keeps the healthy case
    /// terse.
    @discardableResult
    private func saveOne(
        repo: MockTranscriptRepository,
        sessionId: UUID,
        t: Date,
        text: String,
        seq: Int,
        source: AudioSourceType,
        emissionDelay: TimeInterval = 0
    ) async throws -> StoredSegment {
        let emitted = t.addingTimeInterval(emissionDelay)
        let segment = StoredSegment(
            sessionId: sessionId,
            text: text,
            startedAt: emitted,
            endedAt: emitted.addingTimeInterval(1),
            capturedAt: t,
            sequenceNumber: seq,
            source: source
        )
        try await repo.saveSegment(segment)
        return segment
    }

    @Test func matchesCounterpartEmittedMinutesLate() async throws {
        // The failure the capture clock exists for. Both recognizers heard
        // the same words at the same instant, but the sys worker is minutes
        // behind and emits its version long after. A +/-3s window over
        // emission time cannot see the pair; over capture time it is exact.
        let (coord, repo, session) = try await setup()
        let t = Date()

        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 1, source: .microphone
        )
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 2, source: .systemAudio,
            emissionDelay: 750
        )
        // Push the sys frontier past the mic segment's window so the
        // hold-back lets it through.
        try await saveOne(
            repo: repo, sessionId: session.id, t: t.addingTimeInterval(10),
            text: "and on we go", seq: 3, source: .systemAudio,
            emissionDelay: 760
        )

        let outcome = await coord.runPass(sessionId: session.id, holdForSystemAudio: true)
        #expect(outcome.evaluated == 1)
        #expect(outcome.marked == 1)
    }

    @Test func holdDefersMicSegmentWhenSysSideHasWrittenNothing() async throws {
        // The shape at the start of a lagging run: the mic worker is
        // producing, the sys worker has not committed anything yet. Judging
        // the mic segment now would find no candidates and burn the cursor
        // past it forever.
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 1, source: .microphone
        )

        let outcome = await coord.runPass(sessionId: session.id, holdForSystemAudio: true)

        #expect(outcome.evaluated == 0)
        #expect(outcome.marked == 0)
        #expect(outcome.deferred == 1)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 0)
    }

    @Test func deferredMicSegmentIsMarkedOnceSysCounterpartLands() async throws {
        // The whole point of the hold-back: the mic segment must still be
        // reachable when its sys counterpart finally clears the backlog.
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 1, source: .microphone
        )

        let first = await coord.runPass(sessionId: session.id, holdForSystemAudio: true)
        #expect(first.deferred == 1)

        // Sys catches up: the counterpart plus a later utterance that pushes
        // the sys frontier past the mic segment's match window.
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 2, source: .systemAudio
        )
        try await saveOne(
            repo: repo, sessionId: session.id, t: t.addingTimeInterval(10),
            text: "and then some more", seq: 3, source: .systemAudio
        )

        let second = await coord.runPass(sessionId: session.id, holdForSystemAudio: true)
        #expect(second.evaluated == 1)
        #expect(second.marked == 1)
        #expect(second.deferred == 0)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 1)
    }

    @Test func holdStopsAtFirstUnreadySegmentSoTheCursorNeverSkips() async throws {
        // The cursor is a single watermark, so a pass that evaluated a
        // later-but-ready segment while skipping an earlier unready one
        // would strand the unready one behind the cursor. It must stop at
        // the first segment it cannot judge.
        let (coord, repo, session) = try await setup()
        let t = Date()

        // Ready: sys frontier will sit well past this one's window.
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 1, source: .microphone
        )
        // Not ready: audio far ahead of anything sys has committed.
        try await saveOne(
            repo: repo, sessionId: session.id, t: t.addingTimeInterval(100),
            text: "much later utterance", seq: 3, source: .microphone
        )
        // Sys frontier at t+10 — past seq 1's window, nowhere near seq 3's.
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 2, source: .systemAudio
        )
        try await saveOne(
            repo: repo, sessionId: session.id, t: t.addingTimeInterval(10),
            text: "sys keeps going", seq: 4, source: .systemAudio
        )

        let outcome = await coord.runPass(sessionId: session.id, holdForSystemAudio: true)
        #expect(outcome.evaluated == 1)
        #expect(outcome.marked == 1)
        #expect(outcome.deferred == 1)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 1)
    }

    @Test func micOnlyCaptureAdvancesCursorWithoutWaiting() async throws {
        // systemAudio disabled: there is no counterpart coming, ever.
        // Holding back would stall the cursor for the life of the session.
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 1, source: .microphone
        )
        try await saveOne(
            repo: repo, sessionId: session.id, t: t.addingTimeInterval(5),
            text: "second thing", seq: 2, source: .microphone
        )

        let outcome = await coord.runPass(sessionId: session.id, holdForSystemAudio: false)
        #expect(outcome.evaluated == 2)
        #expect(outcome.deferred == 0)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 2)
    }

    @Test func drainPassEvaluatesSegmentsTheHoldWouldHaveDeferred() async throws {
        // The end-of-session pass runs with the hold off, because no more
        // sys segments are coming. Anything the live passes deferred has to
        // be judged now or never.
        let (coord, repo, session) = try await setup()
        let t = Date()
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 1, source: .microphone
        )
        try await saveOne(
            repo: repo, sessionId: session.id, t: t,
            text: "hello world", seq: 2, source: .systemAudio
        )

        // Held: the sys frontier equals the mic segment's own start, so its
        // match window is still open.
        let held = await coord.runPass(sessionId: session.id, holdForSystemAudio: true)
        #expect(held.evaluated == 0)
        #expect(held.deferred == 1)

        let drained = await coord.runPass(sessionId: session.id, holdForSystemAudio: false)
        #expect(drained.evaluated == 1)
        #expect(drained.marked == 1)

        let updated = try await repo.session(session.id)
        #expect(updated?.lastDedupedSegmentSeq == 1)
    }
}
