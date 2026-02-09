# Persistent, Stable Topics (PR #10)

## Why

Topics were re-extracted from scratch on every LLM call, causing them to flicker and reshuffle as the conversation progressed. A user watching the topic panel would see topics appear, disappear, and reorder — making it impossible to track the conversation structure.

## How

Topics are now immutable once established. New LLM calls only extract topics from segments not yet covered by existing topics. Topics are persisted to SQLite and survive app restarts.

### Architecture

```
New segment arrives
  → RollingSummaryCoordinator loads existing topics from DB
  → Filters to segments NOT covered by any existing topic
  → If uncovered segments exist:
      → LLM extracts topics (with existing topics as context)
      → New topics appended and persisted
  → Returns combined list (existing + new)
```

### Key Changes

- `Topic` model gains `sessionId` for DB association
- New `TopicRecord` (GRDB record) with migration `20260207_002_create_topics_table`
- `TranscriptRepository` protocol gains `saveTopic`/`topics(for:)`
- `RollingSummaryCoordinator` becomes topic-aware: load → filter → extract → persist → return
- LLM prompts updated to emphasize incremental extraction

## Key Decisions

- **Immutable topics** — Once a topic is created, it never changes. This eliminates flicker and gives users a stable reference point. The tradeoff is that early topics might be slightly less refined than if they were continuously updated, but stability is more valuable.
- **Segment range tracking** — Each topic records which segments it covers (`segmentRangeStart`/`segmentRangeEnd`). This enables the "uncovered segments" filter that prevents re-extraction.
- **Existing topics as LLM context** — The LLM sees what topics already exist so it can avoid creating duplicates and can recognize when a new segment continues an existing topic rather than starting a new one.

## Testing

- 137 tests pass (17 new: TopicRecordTests, TopicPersistenceTests, TopicStabilityTests)
- TopicStabilityTests specifically verify: existing topics not re-extracted, new topics appended, no uncovered segments = no extraction, extraction failure preserves existing topics
