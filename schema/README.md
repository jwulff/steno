# Steno SQLite Schema

This directory documents the SQLite schema shared between all three Steno components:

- **steno-daemon** (Swift) — writes sessions, segments, summaries, topics
- **steno** (Go TUI) — reads for display
- **steno-mcp** (TypeScript) — reads for AI queries

## Database Location

`~/Library/Application Support/Steno/steno.sqlite`

WAL mode is used for concurrent read/write access.

## Tables

### sessions

| Column    | Type    | Notes                              |
|-----------|---------|------------------------------------|
| id        | TEXT PK | UUID                               |
| locale    | TEXT    | e.g. "en_US"                       |
| startedAt | REAL    | Unix timestamp                     |
| endedAt   | REAL    | NULL if active                     |
| title     | TEXT    | Optional user-assigned title       |
| status    | TEXT    | "active", "completed", "interrupted" |
| createdAt | REAL    | Unix timestamp                     |

### segments

| Column         | Type    | Notes                                  |
|----------------|---------|----------------------------------------|
| id             | TEXT PK | UUID                                   |
| sessionId      | TEXT FK | References sessions(id) CASCADE DELETE |
| text           | TEXT    | 1-10000 chars                          |
| startedAt      | REAL    | Unix timestamp                         |
| endedAt        | REAL    | Unix timestamp                         |
| confidence     | REAL    | 0.0-1.0 or NULL                       |
| sequenceNumber | INTEGER | Unique per session                     |
| createdAt      | REAL    | Unix timestamp                         |
| source         | TEXT    | "microphone" or "systemAudio"          |

**Indexes:** `idx_segments_session(sessionId)`, `idx_segments_time(startedAt)`
**Constraints:** `UNIQUE(sessionId, sequenceNumber)`, text length 1-10000, confidence 0-1

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
