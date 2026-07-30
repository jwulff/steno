# Steno SQLite Schema

This directory documents the SQLite schema shared between Steno's two components:

- **steno-daemon** (Swift) — writes sessions, segments, summaries, topics
- **steno** (Go) — reads for TUI display and MCP queries

## Database Location

`~/Library/Application Support/Steno/steno.sqlite`

WAL mode is used for concurrent read/write access. The Swift writer enables it
explicitly via `PRAGMA journal_mode = WAL` in `DatabaseConfiguration.prepareDatabase`
— without that, the Go reader's WAL DSN does not actually get WAL semantics
(only the writer can switch journal mode).

## Tables

### sessions

| Column                    | Type    | Nullable | Default | Notes                                                                  |
|---------------------------|---------|----------|---------|------------------------------------------------------------------------|
| id                        | TEXT PK | NO       |         | UUID                                                                   |
| locale                    | TEXT    | NO       |         | e.g. "en_US"                                                           |
| startedAt                 | REAL    | NO       |         | Unix timestamp                                                         |
| endedAt                   | REAL    | YES      | NULL    | NULL if active                                                         |
| title                     | TEXT    | YES      | NULL    | Optional user-assigned title                                           |
| status                    | TEXT    | NO       | 'active'| "active", "completed", "interrupted"                                   |
| createdAt                 | REAL    | NO       |         | Unix timestamp                                                         |
| last_deduped_segment_seq  | INTEGER | NO       | 0       | Cursor advanced by `DedupCoordinator` (U11). Highest mic-seg seq evaluated. |
| pause_expires_at          | REAL    | YES      | NULL    | Wall-clock expiry of a timed pause; NULL when not paused or paused indefinitely. |
| paused_indefinitely       | INTEGER | NO       | 0       | `1` = pause has no auto-resume (privacy-critical disambiguator); `0` = either not paused or auto-resume governed by `pause_expires_at`. |

### segments

| Column         | Type    | Nullable | Default       | Notes                                                                    |
|----------------|---------|----------|---------------|--------------------------------------------------------------------------|
| id             | TEXT PK | NO       |               | UUID                                                                     |
| sessionId      | TEXT FK | NO       |               | References `sessions(id)` ON DELETE CASCADE                              |
| text           | TEXT    | NO       |               | 1-10000 chars                                                            |
| startedAt      | REAL    | NO       |               | Unix timestamp. **Recognizer emission time, not audio time** — see "Reading segments". |
| endedAt        | REAL    | NO       |               | Unix timestamp. When the row was handed to persistence; like `startedAt`, not an audio time. |
| confidence     | REAL    | YES      | NULL          | 0.0-1.0 or NULL                                                          |
| sequenceNumber | INTEGER | NO       |               | Unique per session. **Engine-handling order, not audio order** — see "Reading segments". |
| captured_at    | REAL    | YES      | NULL          | Unix timestamp: wall-clock instant the audio was **captured**, recovered from the analyzer's frame timeline (#85). The audio axis — order, window, and cursor on this. Always populated in practice: the writer falls back to `startedAt` when no audio range was reported, and the migration backfills prior rows. |
| createdAt      | REAL    | NO       |               | Unix timestamp                                                           |
| source         | TEXT    | NO       | 'microphone'  | "microphone" or "systemAudio"                                            |
| duplicate_of   | TEXT    | YES      | NULL          | FK to `segments(id)` ON DELETE SET NULL. Set by `DedupCoordinator` (U11) when this row is a duplicate of another segment. NULL = canonical / not yet evaluated. |
| dedup_method   | TEXT    | YES      | NULL          | One of `'exact'` / `'normalized'` / `'fuzzy'` when `duplicate_of` is set; NULL otherwise. |
| heal_marker    | TEXT    | YES      | NULL          | Free-text annotation written by U5/U6 when an in-place pipeline restart preserves the session across a gap (e.g. `'after_gap:12s'`). |
| mic_peak_db    | REAL    | YES      | NULL          | Peak dBFS observed during this mic segment. Used by U11's audio-level heuristic to avoid dropping actively-spoken mic content. NULL for non-mic segments and pre-migration rows. |
| audio_start    | REAL    | YES      | NULL          | Audio-frame start in seconds on the source's capture clock (#64). Frame-accurate join axis for diarization, distinct from the wall-clock `startedAt`. NULL when the recognizer reported no valid range or for pre-migration rows. |
| audio_end      | REAL    | YES      | NULL          | Audio-frame end (`audio_start + duration`) in capture-clock seconds (#64). NULL under the same conditions as `audio_start`. |
| speaker_id     | TEXT    | YES      | NULL          | Global speaker UUID assigned by the diarization merge (#61). NULL until a covering diarization window finalizes; may be revised as windows backfill. Display label is derived from this ID separately, not stored. |

**Indexes:**
- `idx_segments_session(sessionId)`
- `idx_segments_time(startedAt)`
- `idx_segments_dedup(sessionId, sequenceNumber) WHERE duplicate_of IS NULL` — partial index over the non-duplicate rows, keyed for sequence-range selection (`SegmentsForRange`, the dedup cursor scan).
- `idx_segments_session_captured(sessionId, captured_at) WHERE duplicate_of IS NULL` — partial index that backs the default TUI/MCP query (`WHERE sessionId = ? AND duplicate_of IS NULL ORDER BY captured_at`).

**Constraints:**
- `UNIQUE(sessionId, sequenceNumber)`
- text length 1-10000
- confidence 0-1
- `dedup_method` ∈ {NULL, `'exact'`, `'normalized'`, `'fuzzy'`}

#### Reading segments

A segment carries three timestamps on three different clocks, and only one of
them is the audio:

| Column | Clock | Set when |
|---|---|---|
| `captured_at` | **audio** — advances with frames | the audio was captured (derived) |
| `startedAt` | wall clock | the recognizer emitted the result |
| `createdAt` / `endedAt` | wall clock | the engine handled and persisted it |

`sequenceNumber` is a fourth ordering: it is assigned in
`RecordingEngine.handleRecognizerResult` from a single counter shared by the
microphone and systemAudio workers, so it orders *handlings*.

Under a transcription backlog all three wall-clock orderings drift apart, and
they drift **per source**, because each recognizer emits when it gets around to
it. On 2026-07-29 the two sources' emission timestamps were 12.5 minutes apart
at the same instant (see #85). `captured_at` is the only axis on which the two
workers are comparable, because it is derived from the analyzer's frame timeline
(`analyzerStartWallClock[source] + audio_start`) rather than from when anything
was processed.

Three rules for any consumer:

1. **Order by `captured_at`.** `ORDER BY sequenceNumber` interleaves the sources
   by whichever finished transcribing first. `ORDER BY startedAt` is better but
   still emission order, not audio order.
2. **Window on `captured_at`.** A time-range query ("what was said between 2 and
   3pm") means audio time. Matching a mic utterance to its systemAudio
   counterpart likewise only works on this axis — on the emission axis the pair
   can be minutes apart.
3. **Cursor on `captured_at`, and treat a stalled sequence frontier as a lag
   signal rather than as silence.** A consumer polling
   `WHERE sequenceNumber > :cursor ORDER BY sequenceNumber` under a backlog sees
   the tail stop advancing and reads it as the room having gone quiet. It has
   not; the rows are queued.

`sequenceNumber` remains the right key for *identity* and for range addressing —
`UNIQUE(sessionId, sequenceNumber)`, and the `segmentRangeStart`/`segmentRangeEnd`
columns on `topics` and `summaries` both refer to it.

`captured_at` is nullable only so the migration could add it in place. The daemon
always writes it and the migration backfilled every prior row from `startedAt`,
so readers may order by it directly; the Go store still falls back to `startedAt`
on a NULL rather than failing a query.

To measure how far behind the writer is, compare the two frontiers. The Go store
exposes this as `SessionLag`, surfaced on the MCP `get_session` and
`get_overview` tools; in raw SQL it is:

```sql
SELECT
  (SELECT captured_at FROM segments WHERE sessionId = :sid
     ORDER BY sequenceNumber DESC LIMIT 1) AS ts_at_max_seq,
  (SELECT MAX(captured_at) FROM segments WHERE sessionId = :sid) AS max_ts;
```

Equal values mean sequence order is currently safe. Divergence means it is not.
For how far behind wall clock the writer is right now, use
`MAX(createdAt - captured_at)` over recently-written rows — that spans the whole
path, analyzer time included.

### summaries

| Column            | Type    | Notes                                  |
|-------------------|---------|----------------------------------------|
| id                | TEXT PK | UUID                                   |
| sessionId         | TEXT FK | References sessions(id) CASCADE DELETE |
| content           | TEXT    | Summary text                           |
| summaryType       | TEXT    | "rolling" or "final"                   |
| segmentRangeStart | INTEGER | First segment sequence number          |
| segmentRangeEnd   | INTEGER | Last segment sequence number           |
| modelId           | TEXT    | Model identifier                       |
| createdAt         | REAL    | Unix timestamp                         |

**Indexes:** `idx_summaries_session(sessionId)`

### topics

| Column            | Type    | Notes                                  |
|-------------------|---------|----------------------------------------|
| id                | TEXT PK | UUID                                   |
| sessionId         | TEXT FK | References sessions(id) CASCADE DELETE |
| title             | TEXT    | 2-5 word topic name                    |
| summary           | TEXT    | 1-3 sentence description               |
| segmentRangeStart | INTEGER | First segment sequence number          |
| segmentRangeEnd   | INTEGER | Last segment sequence number           |
| createdAt         | REAL    | Unix timestamp                         |

**Indexes:** `idx_topics_session(sessionId)`

## Migrations

Migrations are managed by GRDB in the daemon. Other components should treat the schema as read-only.

1. `20260131_001_initial` — sessions, segments, summaries tables
2. `20260207_001_add_segment_source` — adds `source` column to segments
3. `20260207_002_create_topics_table` — topics table
4. `20260425_001_dedup_and_heal` — adds dedup pointer (`duplicate_of`, `dedup_method`), in-place heal marker (`heal_marker`), mic peak dBFS (`mic_peak_db`) to segments; adds dedup cursor (`last_deduped_segment_seq`) and pause-state-survives-restart fields (`pause_expires_at`, `paused_indefinitely`) to sessions; adds the `idx_segments_dedup` partial index. All additions are nullable or have safe defaults.
5. `20260525_001_segment_audio_time` — adds audio-frame time (`audio_start`, `audio_end`) to segments for the diarization join axis (#64). Both nullable.
6. `20260525_002_segment_speaker` — adds `speaker_id` (global speaker UUID) to segments for diarization speaker labels (#61). Nullable.
7. `20260730_001_segment_captured_at` — adds `captured_at` (wall-clock audio capture time, recovered from the analyzer frame timeline) to segments, backfills it from `startedAt` for prior rows, and adds the `idx_segments_session_captured` partial index so the default transcript read — now ordered on the capture axis (#85) — does not sort a long session's rows on every query. Nullable with a full backfill, so no reader breaks.
