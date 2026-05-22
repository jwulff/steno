# Topic Detail Segments and Session Summary in TUI (PR #22)

## Why

The topic outline (PR #9) gave the TUI a list of topics with j/k
navigation and Enter to "expand" — but expanding only showed the topic's
LLM-generated summary. The underlying segments that *produced* the
topic were one query away in SQLite, yet the TUI never went and got
them. So the navigation existed, but drilling in didn't show useful
detail; you could see *that* a topic was discussed but not *what was
said* during it.

Separately, the daemon's `RollingSummaryCoordinator` was writing a
rolling session-wide summary to SQLite every N segments, and nothing
in the TUI rendered it. The data was there; the UI surface wasn't.

This PR closes both gaps: expanding a topic now lists its segments
inline, and pressing `s` toggles a session-summary overlay in the
transcript panel.

## How

### Two new read-only DB queries

In `tui/internal/db/store.go`:

| Query                 | Purpose                                                                  |
|-----------------------|--------------------------------------------------------------------------|
| `SegmentsForRange()`  | All segments in `(sessionID, seqStart..seqEnd)` for a topic's range      |
| `LatestSummary()`     | Most recent rolling summary for a session (ordered by `createdAt DESC`, `rowid DESC` tiebreaker) |

The `rowid` tiebreaker on `LatestSummary` came out of review feedback —
without it, two summaries with the same `createdAt` (which happens at
SQLite's second-resolution timestamps) could swap on re-query, making
the UI flicker between two values.

### TUI wiring

In `tui/internal/app/`:

- New `tea.Msg` types: `topicSegmentsLoadedMsg`, `sessionSummaryLoadedMsg`.
- Expanding a topic (Enter) dispatches `loadTopicSegmentsCmd`. The loaded
  segments are cached on the topic model so re-expanding the same topic
  doesn't re-query.
- New `s` key binding toggles `showSummary` state. When true, the
  transcript panel renders the latest `LatestSummary()` result instead
  of the live transcript. Same panel, switched content.
- Footer keybindings bar gains `s Summary`.

### Indentation fix

Segments rendered inside an expanded topic use `[MIC]` / `[SYS]`
prefixes and then the segment text. The naive implementation wrapped
the whole "`prefix + text`" string at the panel width — but wrapping
treated the prefix as content, so wrapped lines lost their indent.
Fixed by wrapping the text separately and re-prefixing each visual
line with the indent (not the label), so the alignment is consistent
across wrapped output.

### Empty-result caching

`loadTopicSegmentsCmd` returns a non-nil empty slice when a topic has
no segments. Without that, every Enter on an empty topic re-queried
the DB — visually invisible but a real cost for sessions with many
short topics.

## Key Decisions

- **Inline expansion, not a separate detail screen** — keeps the
  navigation mental model simple: one panel, j/k, Enter to expand /
  collapse. A separate screen would have meant a router, breadcrumbs,
  and a back key for very little gain.
- **`s` reuses the transcript panel, doesn't add a third panel** — the
  TUI already has the focus-switching dance between topics and
  transcript (Tab); adding a third panel would have forced a layout
  rethink. Toggling content within a panel is a one-keystroke
  overlay that costs nothing.
- **`rowid` as deterministic tiebreaker** — SQLite's `INTEGER PRIMARY
  KEY` rowid is monotonic and free. Cheaper than adding a millisecond
  column to the summary table.
- **Cache by topic ID, not by `(sessionID, range)`** — topics are
  identity-stable; ranges shift if a topic gets extended. Caching by
  topic ID means the cache stays valid as long as the topic exists.

## Testing

[steno-tests-passed: 343 tests (169 daemon + 37 TUI + 137 legacy)]

New tests in `tui/internal/db/store_test.go`:

- `SegmentsForRange` returns segments in the requested range only
- `SegmentsForRange` returns empty slice (not nil) when no segments match
- `LatestSummary` returns the most recent summary, with `rowid` breaking
  ties on equal `createdAt`

## What's Next

- Scroll the expanded segment list when it overflows the panel
  (current behavior: truncates to panel height)
- Highlight the segment range belonging to the currently-selected topic
  in the live transcript view, even without expanding
- Per-topic copy-to-clipboard for sharing what was discussed in one
  topic
