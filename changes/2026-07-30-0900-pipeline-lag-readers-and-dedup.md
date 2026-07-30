# Pipeline lag: honest readers, a dedup pass that survives it, and a number to look at

## Why

On 2026-07-29 a ~7-hour recording ran the transcription pipeline into a backlog.
Segments landed in the DB up to 49 minutes after the audio they described. A watcher
subagent polling `WHERE sequenceNumber > :cursor ORDER BY sequenceNumber` every 35–75s
saw the tail stop advancing and read it as the room going quiet. Steno was restarted
three times to clear the lag, so one meeting became four sessions.

Nothing was lost — 3682 rows, max sequence 3682, zero gaps. The sequencer is contiguous,
just slow. But three things about the read and dedup paths turned a throughput problem
into a silent-wrong-answer problem, and those are fixable here. The throughput problem
itself is not: on-device SpeechAnalyzer's rate is not ours to tune, and the machine was
running three other AI tools at the time.

Full incident writeup, diagnostic queries, and the open questions live in the epic
(#85). This PR is its first three children.

## How

**#80 — the dedup cursor no longer burns past unjudgeable segments.**
`DedupCoordinator.runPass` walks mic segments past `last_deduped_segment_seq` and marks
the ones matching an overlapping systemAudio segment. The cursor advanced
unconditionally, at the top of the loop, before any check. Under lag the sys counterpart
of a mic segment simply *had not been written yet* — the sys worker was 12.5 minutes
behind — so the pass found no candidates, skipped the segment, and advanced past it
anyway. When the counterpart finally landed, that mic segment was behind the cursor and
was never re-evaluated. Dedup didn't degrade under lag; it burned through the backlog
marking nothing, at exactly the moment its 2x transcription saving mattered most (107 of
2115 mic rows marked, against 1567 systemAudio rows).

`runPass` now takes `holdForSystemAudio`. When set, it reads the systemAudio ingest
frontier (`latestSegmentTime(sessionId:source:)`, new on the repository) and only judges
mic segments whose match window has closed on that side. It **stops** at the first
unjudgeable segment rather than skipping it, because the cursor is a single watermark —
evaluating a later ready segment would strand the earlier one behind the cursor
permanently. The engine's live debounced trigger passes `isSystemAudioEnabled`; the
terminal end-of-session pass passes `false`, so anything the live passes deferred gets
judged before the session closes.

**#81 — transcript reads order by `startedAt`.** `RecordingEngine` assigns
`sequenceNumber` when a recognizer result *finalizes*, from one counter shared by the mic
and systemAudio workers. It orders finalizations, not audio. The Swift repository already
ordered `startedAt ASC, sequenceNumber ASC`; the three Go reads backing the MCP
transcript surface and the TUI did not. They do now. A new partial index
`idx_segments_session_time(sessionId, startedAt) WHERE duplicate_of IS NULL` keeps the
new ordering off a temp B-tree — without it, a long session sorts thousands of rows per
read, and long sessions are the whole point here.

**#82 — lag is a field now, not a folk query.** `Store.SessionLag` reports two things,
because they answer different questions: `FrontierDivergence` (newest audio minus the
audio at `MAX(sequenceNumber)`) says whether sequence order is safe to read; and
`RecentIngestLag` (worst `createdAt - startedAt` over recently-written rows) says how far
behind wall clock the writer is right now. It surfaces on MCP `get_session` as `lag` and
on `get_overview` as `active_session_lag`, and both tool descriptions now tell an agent
to check it before concluding a session went quiet.

## Key decisions

- **`holdForSystemAudio` defaults to `false`** — the pre-existing drain behavior. The
  hold is only correct while a sys worker is actually expected to produce more; both
  terminal paths (session close, orphan sweep at daemon start) must drain or they strand
  segments forever. Making the safe-in-all-contexts behavior the default and having the
  live path opt in keeps every existing call site correct.
- **A nil sys frontier under the hold defers everything**, rather than falling through to
  "evaluate freely". The caller has asserted systemAudio is live, so "no sys rows yet"
  means the worker is behind, not absent — which is exactly the start-of-backlog case.
  Mic-only capture is distinguished by the flag, not by inferring from the data.
- **`sequenceNumber` stays as it is.** Re-basing it on audio time would mean reordering
  rows already written, and it is load-bearing as identity:
  `UNIQUE(sessionId, sequenceNumber)`, plus `segmentRangeStart`/`End` on topics and
  summaries address segments by it. `SegmentsForRange` still *selects* by sequence range —
  that's its contract — and only the ordering of the result changed.
- **`SessionLag` returns nil, not a zero value, for a session with no segments.** A
  zero-valued lag reads as a healthy pipeline; the fields are omitted from the JSON
  instead, so "empty" and "healthy" stay distinguishable.
- **`SessionLag` does not filter `duplicate_of IS NOT NULL`.** Lag is a property of the
  writer, and a row the dedup pass later discards still cost transcription time.
- **`now` is injected into `SessionLag`** so the recent-writes window is deterministic in
  tests rather than wall-clock dependent.

## Testing

`make test-daemon`: 457 passed, 0 failed. (The reported count varies 455–459 run to run
with zero failures — the harness's documented macOS 26 teardown abort truncates the log.
Stable on this branch and on `origin/main` alike.)

`go test ./internal/db/ ./internal/mcp/`: ok.

New coverage:

- `DedupCoordinatorTests` — a mic segment defers when the sys side has written nothing;
  the deferred segment marks once the counterpart lands; the pass stops at the first
  unready segment so the cursor never skips; mic-only capture advances without waiting;
  the drain pass judges what the hold deferred.
- `MigrationTests` — the new partial index exists with its WHERE clause, serves the
  `ORDER BY startedAt` plan, and does so without a temp B-tree.
- `internal/db` — all three segment reads return audio order on a fixture shaped like the
  incident (a high-sequence row carrying older audio); pagination slices the chronological
  sequence; `SessionLag` on a lagging session, a healthy session, a window that samples
  nothing, and a session with no segments.
- `internal/mcp` — `get_session` reports lag and omits it when there are no segments;
  `get_overview` reports the active session's lag.

Not covered by automated tests: `internal/app` and `internal/daemon` hold live-socket
integration tests that need a running signed daemon. They fail on this machine — verified
identical failures on the unmodified branch, so pre-existing and environmental.

## What's next

The remaining epic children, both deliberately out of this PR:

- **#83** — sequence assignment and segment insert are not atomic, so a reader cursoring
  on `sequenceNumber` can permanently skip a committed row. Found by code reading, not
  from an incident signature. Needs a decision about where sequence assignment belongs.
- **#84** — cap audio buffering / shed under backpressure. For a live watcher,
  fresh-and-lossy beats complete-and-50-minutes-late, and there is currently no way to
  make that trade. Best done on top of #82's measurement.

Still open: whether a backlog ever drains on its own once the room goes quiet, or whether
a restart is always required; and whether the garbling observed during the incident is the
same CPU starvation or a separate model-quality issue that merely correlates.

Refs #85. Closes #80, closes #81, closes #82.
