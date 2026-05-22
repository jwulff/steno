---
date: 2026-05-22
topic: tui-dedup-rendering
---

# TUI Dedup Rendering

## Summary

Add a `dedup` wire event so the daemon can tell the TUI when it has marked a mic segment as duplicating a system-audio segment, and render those entries inline as dimmed + struck-through with a keybind to hide them. Surfaces the already-working server-side dedup in the live TUI without rebuilding the matcher.

---

## Problem Frame

`DedupCoordinator` has been running in the daemon since v0.3.0 (shipped as U11 of the always-on-recording epic, commit `30f74e9`). When a mic segment text-matches a time-overlapping system-audio segment and passes the `-25 dBFS` audio-level guard, it gets marked in SQLite as `duplicate_of` the canonical sys segment. Post-merge consumers — MCP queries, markdown exports, topic expansion — all filter `WHERE duplicate_of IS NULL` and present a clean transcript.

The TUI does not. The live transcript timeline (`m.entries` in `cmd/steno/internal/app/model.go`) is an in-memory append driven by the `segment` NDJSON event. That event fires when the segment lands; the dedup pass runs on a ~5s debounce after that. The TUI never re-reads the segments table on the live path and never receives any follow-up signal that a row has been marked, so duplicates remain visible in the live scroll indefinitely.

The user-visible cost: the headline UI of the product looks broken for the most-watched scenario (recording a meeting with mic + system audio). The user concludes that dedup isn't working, when in fact every other surface in the app already has the right data. The matcher is correct; only the live render is uninformed.

---

## Key Flows

- F1. Live dedup propagation
  - **Trigger:** Mic segment finalized; ~5s later `DedupCoordinator.runPass` marks it `duplicate_of` a sys segment.
  - **Actors:** Daemon (writer of `dedup` event), TUI (consumer).
  - **Steps:**
    1. Mic segment finalizes. Daemon emits `event:"segment"` as today; TUI appends to `m.entries` and renders normally.
    2. ~5s later, `markDuplicate` flips `duplicate_of` and `dedup_method` in SQLite for that mic segment.
    3. Daemon emits a new `event:"dedup"` carrying the session ID, the marked mic segment's seqNum, the canonical sys segment's seqNum, and the matching method.
    4. TUI locates the entry by `(sessionId, sequenceNumber)` and flags it as a duplicate.
    5. The render path applies a dim + strikethrough treatment and a small `↪ dup of #N` suffix to that entry on the next view tick.
  - **Outcome:** The live transcript visually reflects dedup decisions as they happen.
  - **Failure path:** If the event arrives for a segment not currently in `m.entries` (mid-session subscribe, scrolled out of buffer, TUI restarted), the event is silently dropped — any subsequent re-read from SQLite already filters the duplicate out.
  - **Covered by:** R1, R2, R3, R4, R6.

---

## Requirements

**Daemon (Swift)**
- R1. After `DedupCoordinator.markDuplicate` succeeds for a mic segment, the daemon emits a new `event:"dedup"` carrying at minimum: session ID, the marked mic segment's sequence number, the canonical sys segment's sequence number, and the matching method (`exact` / `normalized` / `fuzzy`).
- R2. The `dedup` event is additive to the existing NDJSON protocol — its absence does not affect any other event, and older clients receiving it ignore it gracefully.
- R3. The event fires per individual `markDuplicate` call (not batched per dedup pass).

**TUI (Go)**
- R4. The TUI subscribes to `event:"dedup"` and, on receipt, marks the matching entry in `m.entries` (keyed by `sessionId` + `sequenceNumber`) as a duplicate of the named sys-segment seqNum. If no matching entry is in memory, the event is silently dropped.
- R5. By default, a marked entry remains in the timeline with a dimmed + strikethrough rendering and a small visual hint (e.g., `↪ dup of #N`) pointing at the canonical sys-segment seqNum.
- R6. A new TUI keybind toggles the display of marked entries between "show dimmed" (default) and "hide entirely." The current mode persists for the lifetime of the TUI session.
- R7. The keybind is discoverable via whatever help affordance the TUI currently exposes (e.g., status-bar hint or `?` overlay).

**Behavior boundaries**
- R8. Segments already emitted before the TUI subscribed (i.e., loaded from SQLite, not the live event stream) need not be retroactively marked via this path — the existing `WHERE duplicate_of IS NULL` filter on DB reads already handles them.

---

## Acceptance Examples

- AE1. **Covers R1, R4, R5.** Given mic segment seq=17 finalizes and the daemon later marks it `duplicate_of` sys segment seq=12 with method `fuzzy`, when the daemon emits `{"event":"dedup","sessionId":"…","sequenceNumber":17,"duplicateOfSequence":12,"method":"fuzzy"}` and the TUI has entry seq=17 in `m.entries`, the entry is rendered dim + strikethrough with the suffix `↪ dup of #12`.
- AE2. **Covers R4.** Given a `dedup` event arrives for `sequenceNumber=99` and no entry with that seqNum is currently in `m.entries`, the TUI takes no visible action and does not error.
- AE3. **Covers R6.** Given the default "show dimmed" mode is active and three entries in the visible scroll are marked duplicates, when the user presses the toggle keybind, those three entries disappear from the timeline; a subsequent press restores them in dim + strikethrough.
- AE4. **Covers R2.** Given a steno client built against a pre-`dedup`-event protocol version connects to a daemon that emits `dedup` events, the client ignores the unknown event type and continues processing other events normally.

---

## Success Criteria

- Running steno with mic + system audio capturing the same source (e.g., recording while a video plays) shows the mic-side duplicate visibly de-emphasized within ~5-10 seconds of its arrival, with no manual action.
- The user can spot the rare cases where dedup mis-marks a real spoken utterance as a duplicate, and can switch to "hide all duplicates" with one key when noise tolerance drops.
- A downstream agent or implementer reading this doc and `DedupCoordinator` can build the daemon + TUI changes without inventing scope — event shape, render treatment, default mode, and toggle behavior are all specified here.

---

## Scope Boundaries

- Tuning the dedup matcher itself — the 0.92 fuzzy threshold, the `-25 dBFS` mic-peak guard, the ±3s overlap window. The current matcher is treated as a black box.
- LLM-based or semantic-similarity replacements for the current Levenshtein matcher.
- Collapse-style rendering ("+3 duplicates hidden" expandable rows). Considered as an approach option but rejected as over-engineered for v1.
- Inline display of match score or confidence next to the `↪ dup of #N` hint.
- Changes to the SQLite schema, the dedup cursor, or the post-merge consumers (MCP, markdown export, topic expansion) — all of those already do the right thing.
- An undo / unmark affordance in the TUI for wrongly-flagged duplicates. Visibility is the v1 escape hatch; reversal is a future iteration.
- Retroactive cleanup of duplicates that were emitted before this feature shipped and remain stale in a long-lived TUI buffer (not a meaningful product scenario — buffers are session-scoped).

---

## Key Decisions

- **Push event over polling or buffer-before-emit.** Matches the existing event-driven architecture, gives live latency bounded by the current 5s dedup debounce, keeps the daemon's emit pipeline straightforward. Polling was rejected for introducing DB coupling on the live path; buffer-before-emit was rejected for adding ~3s blanket latency on the most-watched segment moment and for removing visibility into dedup decisions.
- **Mark visible by default, not hidden.** Dedup can be wrong (false positives at the audio-level guard boundary, edge cases in fuzzy matching). Keeping marked entries visible-but-dimmed makes the system's behavior auditable at a glance and lets the user catch misfires. Hidden-by-default is one keybind away for users who want the clean view.
- **Composite key `(sessionId, sequenceNumber)` over surfacing segment UUIDs on the wire.** SeqNum is unique within a session and already present on the wire for `segment` events. Avoids new identifier plumbing in the TUI and any wire-protocol churn beyond the one new event type.
- **One event per `markDuplicate`, not batched per pass.** A typical pass marks 1-3 entries; wire chatter is negligible; single-event semantics keep the daemon side simpler and the TUI handler trivially incremental.

---

## Dependencies / Assumptions

- `(sessionId, sequenceNumber)` is unique across all segments. Verified by the schema's `UNIQUE(sessionId, sequenceNumber)` constraint (see `cmd/steno/internal/db/testutil.go`).
- Existing `DedupCoordinator` correctness is taken as given. Any matcher-quality concerns surface as a separate brainstorm.
- The TUI's existing render path (`Model.View` in `cmd/steno/internal/app/model.go`) can carry per-entry styling decisions without architectural rework — confirmed by inspection: entries are styled inline, not via a precomputed list.

---

## Outstanding Questions

### Resolve Before Planning

- *(none — all scope-shaping questions resolved during brainstorm)*

### Deferred to Planning

- [Affects R6][Technical] Exact letter for the toggle keybind. `d` is a natural fit but the planner should audit current bindings (`p`, `space`, `?`, etc.) before locking it in.
- [Affects R5][Technical] Exact rendering treatment — lipgloss `Strikethrough(true)` vs an inline strike character, dim color choice — left to the planner to harmonize with the existing `cmd/steno/internal/ui` palette.
- [Affects R1][Technical] Final JSON field names on the `dedup` event (`duplicateOfSequence` vs `dupOfSeq` vs other). Examples in this doc are illustrative.
- [Affects R3][Needs research] Whether `markDuplicate` should emit synchronously or via the broadcaster's existing event pipeline — depends on how `DedupCoordinator`'s actor model interacts with `EventBroadcaster`.
