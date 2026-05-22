# Fix Dual-Source Segment Munging (PR #23)

## Why

With both mic and system audio active (e.g. a real conversation over a
video call), the TUI's live transcript was visibly garbled:

1. **Partial text flickered between sources.** The TUI held a single
   `partialText` field with a single `partialSrc` label. Whichever
   source emitted the most recent partial overwrote the other one,
   so as mic and sys took turns updating, the visible partial flipped
   between the two speakers — including jumping label color mid-word.

2. **Finalized segments appeared out of order.** The TUI stamped
   each segment with `time.Now()` at arrival. Network and IPC jitter,
   plus the daemon's per-source recognizer concurrency, meant a
   segment that *was spoken first* could *arrive second* and end up
   below a later utterance.

3. **The DB query backed by the topic outline ordered by
   `sequenceNumber`, not speech time.** Segments get monotonic seqnums
   per source, but interleaving the two sources by seqnum produces
   the wrong ordering for any window that mixes them.

The first one was cosmetic but distracting. The second and third
combined to make the recorded transcript chronologically incoherent
once both sources contributed.

## How

### Per-source partial tracking in the TUI

`tui/internal/app/model.go`: the single `partialText` / `partialSrc`
fields are replaced with:

```go
partials map[string]string  // keyed by source: "microphone" | "systemAudio"
```

Each `partial` event from the daemon updates only its source's entry.
The live transcript view renders both partials when both are present,
each with its own label and color. A finalized `segment` event clears
*only* the matching source's partial — finalizing a mic utterance no
longer wipes an in-flight system-audio partial.

### `startedAt` in the wire protocol

`DaemonProtocol.swift` adds a `startedAt: Double` field (epoch seconds
with fractional precision) to the `segment` event. The daemon already
knew when a transcription started — this just plumbs it across the
socket so the TUI doesn't have to guess from arrival time.

`tui/internal/daemon/protocol.go` mirrors the field. The TUI now uses
`startedAt` everywhere it previously used `time.Now()` for segment
timestamps.

Time conversion uses `math.Modf` to split epoch seconds into integer
seconds + nanoseconds — cleaner than manually multiplying the
fractional part by `1e9`, and avoids floating-point rounding drift.

### Chronological DB ordering

`SQLiteTranscriptRepository.segments(for:)` now orders by:

```sql
ORDER BY started_at ASC, sequence_number ASC
```

`startedAt` is primary; `sequenceNumber` is a deterministic tiebreaker
for segments with identical timestamps (which happens in synthetic
test data more than in production).

This unlocked a follow-up fix in `RollingSummaryCoordinator`: it had
been computing `segmentRangeEnd` from `segments.last?.sequenceNumber`,
which worked only because the old ordering was by `sequenceNumber`.
Under speech-time ordering, the last segment isn't necessarily the
highest seqnum. Now uses `segments.map { $0.sequenceNumber }.max()`
to keep the rolling-summary bookkeeping correct.

### Sorted insertion in the TUI's display list

Even with `startedAt` carried end-to-end, segments can arrive
out-of-order over the socket. The TUI now uses `sort.Search` to
insert each incoming segment at its correct chronological position
in the display list, instead of always appending. Costs O(log n) for
the binary search + O(n) for the insertion, which is fine at TUI
scale (thousands of segments at most per session).

## Key Decisions

- **`map[string]string` over per-source struct fields** — extensible
  if a third source ever arrives (e.g. a remote-participant feed),
  no boilerplate per new source.
- **Epoch seconds as `Double` over ISO-8601 strings on the wire** —
  smaller payload, no parsing, monotonic comparison is a primitive
  operation, JSON-native. The trade-off (millisecond precision via
  the fractional part) is fine for a transcript.
- **Sort on display, not on storage** — segments are append-only in
  SQLite (insertion order matches arrival order at the writer); the
  ordering concern is purely about *how the reader sees them*. Doing
  the sort at query time keeps the writer hot path simple.
- **Fix `RollingSummaryCoordinator` in the same PR** — the DB
  ordering change is observable to the coordinator, and a wrong
  `segmentRangeEnd` would silently corrupt rolling summaries.
  Catching it in-PR avoided a follow-up bug.
- **Fixed-epoch test assertion instead of "now"** — `JSON.parse`'s
  round-trip on floats can shave a least-significant bit; comparing
  to a fixed-known value sidesteps the flake. (Copilot review catch.)

## Testing

[steno-tests-passed: 171 tests in 0.7s]

New tests:

- `segmentsOrderedByStartedAtNotSequenceNumber` (daemon storage) —
  inserts segments with inverted seqnum/startedAt order, asserts the
  query returns them chronologically.
- `dualSourceSegmentsPersistIndependently` (daemon engine integration)
  — emits from both `MockSpeechRecognizerFactory` per-source handles,
  verifies both segments persist with the correct `source` field.
- `TestDualSourcePartialsTrackedIndependently` (TUI) — mic and sys
  partials coexist in the model state without clobbering.
- `TestSegmentClearsOnlyItsSourcePartial` (TUI) — finalizing one
  source's partial leaves the other intact.
- `TestSegmentUsesStartedAtTimestamp` (TUI) — model uses daemon's
  `startedAt`, not `time.Now()`, when ingesting segment events.
- Existing `segmentEventMapped` extended to assert the `startedAt`
  field is populated and round-trips cleanly.

`MockSpeechRecognizerFactory` updated to return per-source handles so
dual-source tests can exercise both paths in one engine instance.
`MockTranscriptRepository` ordering updated to match the production
chronological semantics.

## What's Next

- The wall-clock skew between mic recognizer and system-audio
  recognizer is now visible in segment timestamps — worth a
  monitoring assertion if it grows beyond a few hundred ms (would
  imply a recognizer fell behind).
- Consider exposing per-source partial latency in the daemon status
  output to make slow-recognizer cases debuggable from the TUI.
