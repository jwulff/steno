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
| startedAt      | REAL    | NO       |               | Unix timestamp                                                           |
| endedAt        | REAL    | NO       |               | Unix timestamp                                                           |
| confidence     | REAL    | YES      | NULL          | 0.0-1.0 or NULL                                                          |
| sequenceNumber | INTEGER | NO       |               | Unique per session                                                       |
| createdAt      | REAL    | NO       |               | Unix timestamp                                                           |
| source         | TEXT    | NO       | 'microphone'  | "microphone" or "systemAudio"                                            |
| duplicate_of   | TEXT    | YES      | NULL          | FK to `segments(id)` ON DELETE SET NULL. Set by `DedupCoordinator` (U11) when this row is a duplicate of another segment. NULL = canonical / not yet evaluated. |
| dedup_method   | TEXT    | YES      | NULL          | One of `'exact'` / `'normalized'` / `'fuzzy'` when `duplicate_of` is set; NULL otherwise. |
| heal_marker    | TEXT    | YES      | NULL          | Free-text annotation written by U5/U6 when an in-place pipeline restart preserves the session across a gap (e.g. `'after_gap:12s'`). |
| mic_peak_db    | REAL    | YES      | NULL          | Peak dBFS observed during this mic segment. Used by U11's audio-level heuristic to avoid dropping actively-spoken mic content. NULL for non-mic segments and pre-migration rows. |

**Indexes:**
- `idx_segments_session(sessionId)`
- `idx_segments_time(startedAt)`
- `idx_segments_dedup(sessionId, sequenceNumber) WHERE duplicate_of IS NULL` — partial index that backs the default TUI/MCP query (`WHERE sessionId = ? AND duplicate_of IS NULL ORDER BY sequenceNumber`).

**Constraints:**
- `UNIQUE(sessionId, sequenceNumber)`
- text length 1-10000
- confidence 0-1
- `dedup_method` ∈ {NULL, `'exact'`, `'normalized'`, `'fuzzy'`}

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
