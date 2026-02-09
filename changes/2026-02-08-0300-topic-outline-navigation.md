# Topic Outline Navigation (PR #9)

## Why

The old AI Analysis panel showed a wall of text — the rolling summary and meeting notes were useful but hard to scan. Users needed a way to quickly see what topics had been discussed and drill into the ones they care about.

## How

Replaced the static AI Analysis panel with an interactive topic outline on the left (30% width) and live transcript on the right (70%). Topics are extracted from transcript segments via the existing LLM pipeline (both Apple Intelligence and Anthropic backends).

### New Files

| File | Purpose |
|------|---------|
| `Sources/Steno/Models/Topic.swift` | Topic model (title, summary, segment range) |
| `Sources/Steno/Services/TopicParser.swift` | JSON parser for LLM topic extraction output |
| `Sources/Steno/Views/HeaderView.swift` | App header, mic selector, AI status |
| `Sources/Steno/Views/StatusBarView.swift` | Recording indicator + level meters |
| `Sources/Steno/Views/TopicPanelView.swift` | Navigable topic outline with expansion |
| `Sources/Steno/Views/TranscriptPanelView.swift` | Live transcript with scroll controls |
| `Sources/Steno/Views/KeyboardShortcutsView.swift` | Footer keyboard shortcut bar |

### Key Changes

- `SummarizationService` protocol gains `extractTopics(segments:previousTopics:)`
- `RollingSummaryCoordinator` runs topic extraction concurrently with summary/notes
- MainView decomposed into 5 smaller view components
- Old AI Analysis panel code removed

## Key Decisions

- **Split-panel layout** — 30/70 split gives topics enough room to be scannable while keeping the transcript as the primary focus
- **View decomposition** — Breaking MainView into HeaderView, StatusBarView, TopicPanelView, TranscriptPanelView, and KeyboardShortcutsView makes each piece independently understandable
- **Topic extraction is non-critical** — Failures return `[]` rather than propagating errors; the transcript always works even if AI is unavailable

## Testing

- 120 tests pass across 12 suites (14 new tests added)
- TopicTests, TopicParserTests (valid, malformed, code fences), TopicNavigationTests (j/k navigation, expand/collapse, panel focus)

## What's Next

- Topic persistence across sessions (PR #10)
- Headless daemon extraction (PR #11)
