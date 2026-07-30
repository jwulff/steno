# A clock that survives the backlog

## Why

On 2026-07-29 a ~7-hour recording ran the transcription pipeline into a backlog.
Segments landed in the DB up to 49 minutes after the audio they described. A watcher
subagent polling `WHERE sequenceNumber > :cursor ORDER BY sequenceNumber` every 35–75s saw
the tail stop advancing and read it as the room going quiet. Steno was restarted three
times to clear the lag, so one meeting became four sessions. Dedup, which should have
halved the transcription load, marked 107 of 2115 mic rows and then stopped.

Nothing was lost — 3682 rows, max sequence 3682, zero gaps. The sequencer is contiguous,
just slow.

Full incident writeup, diagnostic queries, and open questions are in #85.

## The actual root cause

A segment carried **no audio timestamp at all**. It had three wall-clock stamps on three
different clocks, and every consumer was treating one of them as if it were the audio:

| Column | Set when |
|---|---|
| `sequenceNumber` | the engine actor handled the result |
| `startedAt` | the recognizer emitted the result |
| `createdAt` / `endedAt` | the row was persisted |

`startedAt` looks like an audio time and was documented as "when this segment started in
the audio", but `RecognizerResult.timestamp` defaults to `Date()` at construction and
`DefaultSpeechRecognizerFactory` never overrides it. It is emission time. A comment in
`RecordingEngine` had already flagged this as a load-bearing *assumption* ("U1 was
skipped") — it turned out to be false.

That matters because the drift is **per source**. Each recognizer emits when it gets around
to it, so under load the two sources' timestamps diverge from each other — 12.5 minutes
apart at one measured instant during the incident. No wall-clock stamp can order a
two-source transcript or match a mic utterance to its systemAudio counterpart.

The fix is a fourth timestamp, on a clock that isn't wall clock at all.

## How

**`captured_at`** — the wall-clock instant audio was captured, recovered from the
analyzer's own input timeline: `analyzerStartWallClock[source] + audio_start`. That
timeline advances with audio *frames*, which arrive at real-time rate no matter how far
behind processing has fallen, so frame N always maps back to the moment it was heard.
`audio_start` already existed (#64) for the diarization join; it just needed anchoring to
wall clock.

`RecordingEngine` stamps `analyzerStartWallClock[source]` immediately before each analyzer
starts consuming — at all four bring-up sites, so a heal or device-change rebuild
re-anchors rather than inheriting a stale zero.

Everything that reasons about *when something was said* now uses it:

- **Ordering** — the Swift repository and all four Go segment reads, including search's
  newest-first.
- **Time-range filters** — "what was said between 2 and 3pm" means audio time.
- **Dedup matching** — `overlappingSegments` windows `mic.capturedAt ± 3s`. This is what
  makes dedup work under lag at all: on the emission axis the counterpart can be minutes
  outside the window.
- **The dedup readiness horizon** (#80, below).
- **Lag** (#82, below) — `createdAt - captured_at` spans the whole path, analyzer time
  included.
- **Demarcation routing** — which finally satisfies U1's assumption. Routing on emission
  time would push audio spoken *before* a demarcate onto the new session.

Three consumer-visible bugs fall out of that foundation:

**#80 — the dedup cursor no longer burns past unjudgeable segments.** `runPass` advanced
`last_deduped_segment_seq` at the top of its loop, before any check. When the systemAudio
counterpart hadn't been written yet, the pass found no candidates, skipped the segment, and
advanced past it anyway; it was never re-evaluated. `runPass` now takes
`holdForSystemAudio`, reads the systemAudio ingest frontier, and **stops** at the first
segment whose match window is still open — the cursor is a single watermark, so skipping
ahead would strand it permanently.

**#81 — transcript reads are chronological.** With `idx_segments_session_captured` so a long
session doesn't sort every row per read.

**#82 — lag is a field.** `Store.SessionLag` reports `FrontierDivergence` (is sequence order
safe to read?) and `RecentIngestLag` (how far behind wall clock is the writer right now?),
surfaced as `lag` on `get_session` and `active_session_lag` on `get_overview`. Both tool
descriptions tell an agent to check it before concluding a session went quiet.

## Key decisions

- **A new column rather than redefining `startedAt`.** `startedAt` has always been emission
  time and other code reads it; silently changing its meaning would leave old and new rows
  incomparable with no way to tell them apart. `captured_at` is explicit, and `startedAt`'s
  doc now says what it actually is instead of what it was assumed to be.
- **Backfilled from `startedAt`, not left NULL.** Prior rows have no analyzer anchor to
  recover and the emission timestamp is the closest thing they carry. A full backfill keeps
  the column effectively NOT NULL so readers can order by it directly and use a plain index —
  a `COALESCE` in `ORDER BY` would have cost the index. The Go scan still falls back to
  `startedAt` on a NULL: a read-only consumer should degrade, not refuse to open a session.
- **`holdForSystemAudio` defaults to `false`** — the pre-existing drain behavior. Both
  terminal paths (session close, orphan sweep) must drain or they strand segments forever.
  Safe-in-all-contexts is the default; the live path opts in with `isSystemAudioEnabled`.
- **A nil sys frontier under the hold defers everything.** The caller asserted systemAudio is
  live, so "no sys rows yet" means the worker is behind, not absent — the start-of-backlog
  case. Mic-only capture is distinguished by the flag, not inferred from data.
- **`sequenceNumber` is unchanged.** Re-basing it on audio time would mean reordering rows
  already written, and it is load-bearing as identity: `UNIQUE(sessionId, sequenceNumber)`,
  plus `segmentRangeStart`/`End` on topics and summaries. `SegmentsForRange` still *selects*
  by sequence range; only its ordering changed.
- **`endedAt` left alone.** It is handling time, not audio end, and could be derived from
  `captured_at + audio_duration` — but nothing reads it as an audio time today, so that is
  noted rather than changed.

## Testing

`make test-daemon`: 502 passed, 0 failed. `go test ./internal/db/ ./internal/mcp/`: ok.

New coverage:

- **Engine** — `capturedAt` is derived from the analyzer timeline, not the emission
  timestamp, for a result emitted 10 minutes late; and falls back to emission when the
  recognizer reports no audio range.
- **Dedup** — a counterpart emitted 12.5 minutes late still matches (the failure the capture
  clock exists for); a mic segment defers when the sys side is silent; the deferred segment
  marks once the counterpart lands; the pass stops at the first unready segment so the cursor
  never skips; mic-only advances without waiting; the drain pass judges what the hold
  deferred.
- **Migration** — the column exists, backfills from `startedAt`, and the partial index serves
  `ORDER BY captured_at` without a temp B-tree.
- **Go store** — all three segment reads return audio order on a fixture carrying all three
  clocks with realistic per-source divergence; pagination slices the chronological sequence;
  `SessionLag` on lagging / healthy / empty-window / no-segment sessions.
- **MCP** — `get_session` reports lag and omits it when there are no segments; `get_overview`
  reports the active session's lag.

## What's next

- **#83** — sequence assignment and segment insert are not atomic, so a reader cursoring on
  `sequenceNumber` can permanently skip a committed row. Found by code reading, not an
  incident signature.
- **#84** — cap audio buffering / shed under backpressure. Now buildable on a lag figure that
  measures the whole path.

The capture clock also makes two things newly possible: a true audio-time `endedAt`, and
stitching a meeting back together across the sessions a restart fragmented it into — both
now have a comparable axis to work on.

Closes #80, closes #81, closes #82. Refs #85.
