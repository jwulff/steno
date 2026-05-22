---
title: TUI Dedup Rendering
type: feat
status: active
date: 2026-05-22
origin: docs/brainstorms/2026-05-22-tui-dedup-rendering-brainstorm.md
---

# TUI Dedup Rendering

## Summary

Plumb a new `dedup` NDJSON event from the daemon's existing `DedupCoordinator` through the broadcaster pipeline to the TUI, then render matched mic segments dim + struck-through with a `d` keybind to hide them entirely. Six units, dependency-ordered, TDD throughout.

---

## Problem Frame

`DedupCoordinator` has been silently marking duplicate mic segments since v0.3.0, but the live TUI never learns about it. The brainstorm at `docs/brainstorms/2026-05-22-tui-dedup-rendering-brainstorm.md` carries the full pain narrative; this plan is the HOW.

---

## Requirements

Carried from origin (`docs/brainstorms/2026-05-22-tui-dedup-rendering-brainstorm.md`):

- R1. Daemon emits `event:"dedup"` after each `markDuplicate`, carrying session ID, mic sequence number, canonical sys sequence number, and method.
- R2. `dedup` event is additive to NDJSON — older clients ignore it gracefully.
- R3. One event per `markDuplicate` call (not batched per pass).
- R4. TUI handles `dedup` by marking the matching entry by `sequenceNumber`; silently drops if entry not in memory.
- R5. Default rendering: dim + strikethrough + `↪ dup of #N` suffix; entry stays in timeline.
- R6. Keybind toggles between "show dimmed" (default) and "hide entirely"; persists for TUI session lifetime.
- R7. Keybind discoverable via existing help affordance (footer hint).
- R8. Pre-subscribe segments need no retroactive marking — DB filter already handles them.

**Origin acceptance examples:**
- AE1 (Covers R1, R4, R5): dedup event lands → matching entry rendered dim + strikethrough with `↪ dup of #12`.
- AE2 (Covers R4): event for unknown seqNum is silently no-op.
- AE3 (Covers R6): toggle keybind flips three duplicates between dimmed-visible and hidden.
- AE4 (Covers R2): older client ignores unknown event type.

---

## Scope Boundaries

- Schema changes to the `segments` table (already covered; the `duplicate_of` / `dedup_method` columns exist).
- Tuning the dedup matcher itself (threshold, audio-level guard, overlap window).
- LLM-based or semantic-similarity matchers.
- Match score / confidence inline in the UI.
- Collapse-style ("+N duplicates hidden") rendering.
- An undo / unmark affordance in the TUI for wrongly-flagged duplicates.
- Persisting the toggle mode across TUI restarts.
- Adding a `SessionID` field to `TranscriptEntry` — research confirmed it isn't needed because `m.entries` clears on session change.

---

## Context & Research

### Relevant Code and Patterns

**Daemon (Swift):**
- `daemon/Sources/StenoDaemon/Services/DedupCoordinator.swift` — `markDuplicate` is the emission hook (called in `runPass`'s per-segment loop).
- `daemon/Sources/StenoDaemon/Engine/RecordingEngineDelegate.swift` — `EngineEvent` enum; this is where the new case lands.
- `daemon/Sources/StenoDaemon/Engine/RecordingEngine.swift` — owns the only delegate pipe (`emit(_ event: EngineEvent)`); receives the coordinator's callback during init.
- `daemon/Sources/StenoDaemon/Dispatch/EventBroadcaster.swift` — `EventType` enum + `mapEvent` switch; canonical wire-surface registration.
- `daemon/Sources/StenoDaemon/Socket/DaemonProtocol.swift` — `DaemonEvent` struct; extend with optional fields.
- Precedent: the `pause_state` event (recently added in U10 of the always-on-recording epic) is the template — every touch point this plan changes was changed for pause_state too.

**TUI (Go):**
- `cmd/steno/internal/daemon/protocol.go` — `Event` struct (extend additively with new optional fields).
- `cmd/steno/internal/app/model.go`:
  - `TranscriptEntry` definition (add duplicate fields here).
  - `handleEvent` switch (add `case "dedup":`).
  - `renderTranscriptPanel` per-entry loop (apply conditional styling; respect hide-mode).
  - `renderFooter` (add keybind hint matching the existing `e Errors` pattern).
- `cmd/steno/internal/app/keymap.go` — central keybind constants; `d` is unbound.
- `cmd/steno/internal/ui/styles.go` — central lipgloss styles; add `DuplicateStyle`.

**Tests:**
- `daemon/Tests/StenoDaemonTests/Services/DedupCoordinatorTests.swift` — coordinator unit tests.
- `daemon/Tests/StenoDaemonTests/Dispatch/EventBroadcasterTests.swift` — mapping tests (`segmentEventMapped` is the template).
- `daemon/Tests/StenoDaemonTests/Engine/PauseTests.swift` — engine-emit path test pattern.
- `cmd/steno/internal/daemon/protocol_test.go` — wire-protocol roundtrip (`TestEventPauseState` is the template).
- `cmd/steno/internal/app/model_test.go` — TUI handler tests (`TestPauseStateEventTransitionsToPaused` is the template).

### Institutional Learnings

- New wire events must mirror in lockstep across Swift `DaemonProtocol.swift` and Go `protocol.go` in the same PR (always-on plan flagged this as the failure mode to avoid).
- Backward compatibility is free in NDJSON — older clients drop unknown events at the switch in `handleEvent`. AE4 already covers this; no version negotiation needed.
- Centralize new lipgloss styles in `styles.go`, not inline at the render site (TUI change-doc convention).
- Late-arrival event ordering is the default case for dedup (~5s debounce), not an edge case. Drop misses silently per AE2.
- Project convention: every commit needs `[steno-tests-passed: X tests in Ys]` attestation; pre-push hook runs `make test`.

### External References

- None used — codebase has strong local patterns (the `pause_state` precedent is a near-exact template).

---

## Key Technical Decisions

- **Emit via `EventBroadcaster`, not a synchronous side channel.** Resolves the brainstorm's deferred question on emit pipeline. Every other event does this; going synchronous would mean teaching `DedupCoordinator` about `EventBroadcaster`, which breaks the layering and has no precedent.
- **Coordinator → engine wiring via optional callback closure.** `DedupCoordinator` gains an optional `onDuplicateMarked` async callback property; `RecordingEngine` sets it during init to call `self.emit(.duplicateMarked(...))`. Matches the codebase's existing DI convention; no new module-level coupling.
- **Per-mark emission, not per-pass batching.** The callback fires inside `markDuplicate`'s loop in `runPass`. Matches R3. Returning a list from `runPass` would batch — wrong shape.
- **Match TUI entries by `SeqNum` alone.** `m.entries` is session-scoped (cleared on session change), so a `sessionId` check would be redundant. Add only `Duplicate bool` and `DuplicateOfSeq int` to `TranscriptEntry`. If a `dedup` event somehow arrives for a wrong session, the silently-drop-on-miss rule (R4 + AE2) makes it a no-op.
- **JSON field names: `duplicateOfSequence` and `method`.** Matches AE1 in the brainstorm and Swift's default camelCase encoder. Lower-case JSON tags on the Go side mirror.
- **No new bubbletea `Msg` type.** Wire events ride the existing `DaemonEventMsg` envelope and mutate the model synchronously in `handleEvent` (research confirmed via the `pause_state` precedent). `Msg` types are reserved for async `tea.Cmd` resolution (DB loads, etc.).
- **Hide-mode is per-TUI-session, not persisted.** Trade-off: simpler code, no settings plumbing. If the user reopens steno, defaults to "show dimmed" again. Easy to change later.
- **TDD posture throughout.** Project CLAUDE.md mandates "every feature starts with a failing test." Each feature-bearing unit names its tests explicitly.

---

## Open Questions

### Resolved During Planning

- **Synchronous emit vs broadcaster pipeline** (origin doc, Affects R3): Route via broadcaster. Matches every other event.
- **Keybind letter** (origin doc, Affects R6): `d`. Free in current keymap.
- **JSON field naming** (origin doc, Affects R1): `duplicateOfSequence` + `method`. Matches AE1.
- **Render treatment specifics** (origin doc, Affects R5): lipgloss `DuplicateStyle` = dim gray foreground + `Strikethrough(true)`. Inline suffix `↪ dup of #N` rendered with the same style.

### Deferred to Implementation

- Exact JSON field name for the canonical sys sequence number: stay with `duplicateOfSequence` unless implementation reveals a clash with existing naming.
- Whether to emit the event from `DedupCoordinator` synchronously inside `markDuplicate` (after the repository UPDATE succeeds) or batched at end-of-pass: per-mark inside the loop, immediately after the await, is the current intent — confirm at implementation time that nothing in the cursor-advance path requires deferral.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```mermaid
sequenceDiagram
    participant Engine as RecordingEngine
    participant Coord as DedupCoordinator
    participant Repo as TranscriptRepository
    participant Bcast as EventBroadcaster
    participant TUI as Go TUI (model.go)

    Engine->>Coord: runPass(sessionId)
    loop per mic segment
        Coord->>Repo: overlappingSegments / scoring
        alt match above threshold
            Coord->>Repo: markDuplicate(...)
            Coord->>Engine: onDuplicateMarked(...) callback
            Engine->>Bcast: emit(.duplicateMarked)
            Bcast->>TUI: NDJSON {"event":"dedup",...}
            TUI->>TUI: find entry by seqNum; mark Duplicate=true
            TUI->>TUI: re-render with DuplicateStyle
        end
    end
```

**Per-entry render decision (inside `renderTranscriptPanel` loop):**

| Entry state         | hideDuplicates=false (default) | hideDuplicates=true |
|---------------------|--------------------------------|----------------------|
| `Duplicate=false`   | Normal style                   | Normal style         |
| `Duplicate=true`    | DuplicateStyle + `↪ dup of #N` suffix | `continue` (skip) |

---

## Implementation Units

### U1. Daemon: engine event + coordinator callback

**Goal:** Define the new engine-level event and wire `DedupCoordinator` to emit it through `RecordingEngine`'s existing delegate pipe.

**Requirements:** R1, R3.

**Dependencies:** None.

**Files:**
- Modify: `daemon/Sources/StenoDaemon/Engine/RecordingEngineDelegate.swift` (add `EngineEvent.duplicateMarked` case carrying session ID, mic sequence, sys sequence, dedup method).
- Modify: `daemon/Sources/StenoDaemon/Services/DedupCoordinator.swift` (add optional `onDuplicateMarked` callback property; invoke after `markDuplicate` succeeds inside the per-mic loop in `runPass`).
- Modify: `daemon/Sources/StenoDaemon/Engine/RecordingEngine.swift` (in init, set `dedupCoordinator?.onDuplicateMarked` to a closure that calls `self.emit(.duplicateMarked(...))`).
- Test: `daemon/Tests/StenoDaemonTests/Services/DedupCoordinatorTests.swift` (extend to assert the callback fires once per mark with correct args).

**Approach:**
- The callback is set once during engine construction and persists for the engine's lifetime. The coordinator's `runPass` invokes it inside its existing per-mic loop, after the `markDuplicate` await returns successfully.
- Cursor advance is unaffected — the callback runs before the trailing `advanceDedupCursor` and is not awaited from a critical section.
- Engine's existing reentrance guard on `dedupCoordinator` ensures one callback per mark per pass.

**Execution note:** Start with a failing test in `DedupCoordinatorTests.swift` that injects an `onDuplicateMarked` closure capturing args, runs a pass that should mark one mic segment, and asserts the closure fired exactly once with the expected `(sessionId, micSeq, sysSeq, method)`.

**Patterns to follow:**
- `RecordingEngine.swift` injection pattern for `dedupCoordinator` and similar collaborators.
- Existing async-closure properties on actors in this codebase (search for `var on...` on actor types).

**Test scenarios:**
- Happy path: single mic segment matched against single sys segment → callback fires once with correct args.
- Happy path: multiple matches in one pass → callback fires once per `markDuplicate`, in order.
- Edge case: pass runs but no segments match → callback never fires.
- Edge case: pass with `onDuplicateMarked == nil` → no crash, behavior unchanged.
- Error path (existing): `markDuplicate` throws → callback does NOT fire for that mark; subsequent marks in the pass also do not fire (existing cursor-advance failure semantics preserved).

**Verification:**
- Test suite passes; the new test exercises the callback hook end-to-end inside the coordinator.

---

### U2. Daemon: broadcaster mapping + protocol struct

**Goal:** Map `EngineEvent.duplicateMarked` to a wire `dedup` event with the agreed JSON shape.

**Requirements:** R1, R2.

**Dependencies:** U1.

**Files:**
- Modify: `daemon/Sources/StenoDaemon/Dispatch/EventBroadcaster.swift` (add `EventType.dedup` case; add a `mapEvent` switch arm producing the new `DaemonEvent`).
- Modify: `daemon/Sources/StenoDaemon/Socket/DaemonProtocol.swift` (extend `DaemonEvent` with optional `duplicateOfSequence: Int?` and `method: String?` fields; existing `sessionId` and `sequenceNumber` carry the rest).
- Test: `daemon/Tests/StenoDaemonTests/Dispatch/EventBroadcasterTests.swift` (extend to cover the new mapping; mirror `segmentEventMapped`).

**Approach:**
- The mic segment's sequence number goes into the existing `sequenceNumber` field. The sys segment's sequence number goes into the new `duplicateOfSequence` field.
- The dedup method (`exact` / `normalized` / `fuzzy`) is serialized via its existing `RawValue` string.
- `EventType` is `CaseIterable` and gates subscriptions — adding here is the canonical surface registration.

**Execution note:** Failing mapping test first; then add the `EventType` case + `mapEvent` arm.

**Patterns to follow:**
- `segment` and `pause_state` event mapping in `EventBroadcaster.swift`.
- `DaemonEvent` field-addition pattern from the pause-state work — optional fields with `Encodable` default omission.

**Test scenarios:**
- Happy path: `EngineEvent.duplicateMarked(sessionId, micSeq=17, sysSeq=12, method=.fuzzy)` maps to a `DaemonEvent` with `event == "dedup"`, `sessionId` set, `sequenceNumber == 17`, `duplicateOfSequence == 12`, `method == "fuzzy"`.
- Happy path: each of `.exact`, `.normalized`, `.fuzzy` serializes to its expected lowercase string.
- Edge case: serialized JSON contains no spurious fields; absent-by-default optional fields stay absent.

**Verification:**
- Mapping test passes; JSON roundtrip via `JSONEncoder` produces the expected wire shape.

---

### U3. Go: protocol mirror + roundtrip test

**Goal:** Extend the Go `Event` struct to carry the new fields and verify JSON parity with the daemon.

**Requirements:** R1, R2.

**Dependencies:** U2.

**Files:**
- Modify: `cmd/steno/internal/daemon/protocol.go` (add `DuplicateOfSequence *int` and `Method string` with appropriate `json:"...,omitempty"` tags).
- Test: `cmd/steno/internal/daemon/protocol_test.go` (add `TestEventDedup` paralleling `TestEventPauseState`).

**Approach:**
- Field names mirror the Swift `DaemonEvent` JSON shape exactly: `duplicateOfSequence` and `method`. Pointer for the int to distinguish "absent" from "zero"; bare string for `method` (empty string == absent).
- No changes to any other struct or to the existing `Event` field order — append at the end after the pause-state block.

**Execution note:** Roundtrip test first.

**Patterns to follow:**
- `TestEventPauseState` in `protocol_test.go`.
- The optional-pointer pattern already used for `Paused`, `PausedIndefinitely`, etc.

**Test scenarios:**
- Happy path (decode): A NDJSON line `{"event":"dedup","sessionId":"...","sequenceNumber":17,"duplicateOfSequence":12,"method":"fuzzy"}` decodes into an `Event` with the expected fields.
- Happy path (encode): An `Event` with the dedup fields set encodes to the expected JSON line, with no extraneous keys.
- Edge case: Missing optional fields (e.g., `method` absent) decodes without error, leaves `Method` empty.

**Verification:**
- `go test ./cmd/steno/internal/daemon/...` passes; manual byte-comparison shows JSON parity with the Swift `DaemonEvent` encoding.

---

### U4. TUI: event handler + TranscriptEntry shape

**Goal:** Handle the `dedup` event in the TUI by flagging the matching transcript entry; drop silently if the entry isn't in memory.

**Requirements:** R4.

**Dependencies:** U3.

**Files:**
- Modify: `cmd/steno/internal/app/model.go`:
  - `TranscriptEntry` struct: add `Duplicate bool` and `DuplicateOfSeq int` fields.
  - `handleEvent`: add `case "dedup":` block immediately after the `pause_state` case; locates the matching entry in `m.entries` by `SeqNum`, sets `Duplicate=true` and `DuplicateOfSeq=ev.DuplicateOfSequence`.
  - A small helper (e.g., `markEntryDuplicate`) is fine if it keeps `handleEvent` readable, but is not required.
- Test: `cmd/steno/internal/app/model_test.go` (add cases for mark-on-match and silent-drop-on-miss).

**Approach:**
- Match purely on `SeqNum`. `m.entries` is session-scoped — when a new session starts the slice is reset, so a dedup event for a prior session that races a session change is harmless (no match → silent drop).
- The handler is synchronous: in-place mutation of `m.entries[i]`. No new `tea.Cmd` is returned.
- `m.lastSegmentAt` is not touched (dedup is not a "new activity" signal).

**Execution note:** Failing tests first — both the happy mark-an-existing-entry case and the silent-drop-unknown case (AE2 verbatim).

**Patterns to follow:**
- `case "pause_state":` in `handleEvent` (line ~954) for synchronous in-place model mutation.
- `case "segment":` block for how the loop walks `m.entries`.

**Test scenarios:**
- Covers AE1, R4. Happy path: entry with `SeqNum=17` exists in `m.entries`; dedup event arrives with `sequenceNumber=17`, `duplicateOfSequence=12`, `method="fuzzy"` → entry has `Duplicate=true` and `DuplicateOfSeq=12`.
- Covers AE2. Edge case: dedup event arrives with `sequenceNumber=99`; no matching entry → no error, no model mutation, no `tea.Cmd` returned.
- Edge case: event with absent (nil) `duplicateOfSequence` → silently treat as no-op (defensive; shouldn't happen on the wire but tests guard the decoder).
- Integration: a `segment` event followed by a `dedup` event for the same seqNum results in a marked entry; the event order is preserved.

**Verification:**
- `go test ./cmd/steno/internal/app/...` passes; entry-state assertions match expectations.

---

### U5. TUI: render styling for marked entries

**Goal:** Render entries with `Duplicate=true` using dim foreground + strikethrough + `↪ dup of #N` suffix.

**Requirements:** R5.

**Dependencies:** U4.

**Files:**
- Modify: `cmd/steno/internal/ui/styles.go` (add `DuplicateStyle` — gray foreground, `Strikethrough(true)`; mirror the style-declaration pattern used by existing styles like `DimStyle` or `HealMarkerStyle`).
- Modify: `cmd/steno/internal/app/model.go` (`renderTranscriptPanel` per-entry loop): apply `DuplicateStyle` to timestamp, source label, and wrapped text lines for marked entries; append the `↪ dup of #N` suffix (rendered through the same style).
- Test: `cmd/steno/internal/app/model_test.go` or a new `view_test.go` — assert that the rendered string for a marked entry contains the suffix and the expected ANSI styling cues, or use snapshot-style assertions on the View output if a precedent exists.

**Approach:**
- The duplicate suffix is rendered inline after the entry's wrapped text; it does NOT push the entry onto a separate line.
- Hide-mode behavior (`m.hideDuplicates == true`) is NOT implemented in this unit — U6 adds the toggle and the `continue` branch. This unit only adds the dim/strike visual treatment.
- Style declaration goes alongside existing styles; the conditional render check goes inline in the per-entry loop (`if e.Duplicate { ... }`).

**Execution note:** TDD where practical — if a view-rendering test pattern exists, follow it; if not, hand-verify with `make run-steno` against a session that has known marked entries and fall back to a unit test asserting the rendered string contains the expected substring + ANSI escape pattern.

**Patterns to follow:**
- Existing style declarations in `cmd/steno/internal/ui/styles.go`.
- The `IsBoundary` branch in `renderTranscriptPanel` (around line 1825) as the precedent for conditional per-entry treatment.

**Test scenarios:**
- Happy path: an entry with `Duplicate=true` and `DuplicateOfSeq=12` renders with the dim+strike escape sequences and the literal substring `↪ dup of #12`.
- Happy path: an entry with `Duplicate=false` renders unchanged from the pre-feature output.
- Edge case: a duplicate entry with very long text wraps correctly with styling preserved on each wrapped line.
- Edge case: a duplicate entry with `DuplicateOfSeq=0` (sentinel for absent) still renders sensibly — either with `↪ dup of #0` or with the suffix omitted, depending on the decoder behavior settled in U4.

**Verification:**
- Manual run-through: launch the TUI against a session known to have marked duplicates (or arrange one via the test harness) and confirm the visual treatment.
- Test suite passes.

---

### U6. TUI: toggle keybind for duplicates

**Goal:** Add the `d` keybind that toggles between "show dimmed" (default) and "hide entirely"; surface the keybind in the footer help line.

**Requirements:** R6, R7.

**Dependencies:** U5.

**Files:**
- Modify: `cmd/steno/internal/app/keymap.go` (add `KeyToggleDuplicates = "d"` constant).
- Modify: `cmd/steno/internal/app/model.go`:
  - Add `hideDuplicates bool` field on `Model`.
  - Add a key-handler branch (alongside the existing `KeyErrorHistory` block around line 1107+) that flips `hideDuplicates`.
  - In `renderTranscriptPanel`'s per-entry loop: when `hideDuplicates == true` and `e.Duplicate == true`, `continue` past the entry entirely.
  - In `renderFooter` (around line 1909): add a conditional hint mirroring the `"e Errors"` style — `"d Hide dups"` when `!hideDuplicates`, `"d Show dups"` when `hideDuplicates`.
- Test: `cmd/steno/internal/app/model_test.go` (add toggle-behavior tests).

**Approach:**
- `hideDuplicates` defaults to `false`. Not persisted across TUI restarts.
- Toggle does not affect `m.entries` itself — only the render loop. Re-toggling restores visibility instantly.
- Footer hint visibility doesn't require any new help-overlay plumbing; the inline conditional label is enough.

**Execution note:** TDD — add the model_test cases first.

**Patterns to follow:**
- Existing keybind constants in `keymap.go`.
- The `KeyErrorHistory` key-handler in `model.go` for the routing pattern.
- The `e Errors` footer-hint pattern in `renderFooter` (using `FooterKeyStyle` + `FooterDescStyle`).

**Test scenarios:**
- Covers AE3. Happy path: three entries in `m.entries` with `Duplicate=true`; pressing `d` once → none of the three render; pressing `d` again → all three render with dim+strike.
- Happy path: `m.entries` has no marked entries; pressing `d` is a no-op visually but the footer label flips.
- Edge case: pressing `d` while focus is in an input field (e.g., search) does NOT toggle — existing keymap routing should already gate this, but assert it explicitly.
- Edge case: footer hint correctly reflects the current mode (`Hide dups` vs `Show dups`).

**Verification:**
- Test suite passes; manual run-through confirms toggle behavior and footer hint.
- `make test` passes (pre-push hook); commit message includes `[steno-tests-passed: X tests in Ys]`.

---

## System-Wide Impact

- **Interaction graph:** New event flows through the existing engine → broadcaster → socket → TUI path. No new sockets, no new files, no new processes.
- **Error propagation:** A failure in `onDuplicateMarked` (the closure) should be logged but not abort the dedup pass. The closure is `async` and runs on the engine actor; if it throws, the engine catches per existing event-emit error handling.
- **State lifecycle risks:** `m.entries` is in-memory only; the new `Duplicate` flag dies with the TUI process. The persistent state (`duplicate_of` in SQLite) is unchanged and already correct.
- **API surface parity:** MCP, markdown export, and topic expansion already filter `WHERE duplicate_of IS NULL` — no change needed on those surfaces.
- **Integration coverage:** The end-to-end happy path (mic segment → dedup pass → wire event → TUI render) is worth one integration-style test, even if the existing test patterns are unit-per-layer. Consider adding a single test in either `cmd/steno/internal/app/live_test.go` or a new integration file that drives a real `Event` through `handleEvent` and asserts the rendered output.
- **Unchanged invariants:** The existing `duplicate_of` write, the `dedup_method` column, the dedup cursor, and the post-merge DB filters are all unchanged. This plan adds a *signal* about those writes; it does not change the writes themselves.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| The `onDuplicateMarked` callback adds a non-Sendable closure capture on the coordinator actor and triggers a Swift 6 concurrency warning. | Use an `@Sendable` closure; mirror the existing async-closure patterns elsewhere in the coordinator. If concurrency warnings surface, lift them into the design rather than papering over with `nonisolated(unsafe)`. |
| Wire-protocol field name skew between Swift and Go. | The roundtrip test in U3 is the canary. If the test fails, fix the name on whichever side hasn't shipped yet (none have at this point). |
| A `dedup` event arrives for an entry the user has scrolled past — does the toggle still hide it correctly? | Yes: the toggle operates over `m.entries` in the render loop, not over the visible viewport. Mark-and-render is correct regardless of viewport position. |
| Adding the `d` keybind collides with an input-mode key consumer (search, etc.). | Existing keymap routing gates global bindings when input modes are active. U6 adds an explicit test for this. |
| The dim color choice is unreadable on some terminal themes. | Use the existing `DimStyle` color (gray foreground) — already proven readable on the project's tested terminal palette. |

---

## Documentation / Operational Notes

- Update the NDJSON protocol block in `CLAUDE.md` (project root) to include the new `dedup` event under "Events (daemon → subscribed clients, streaming)" — the existing list includes `partial`, `segment`, `level`, `status`, `topics`, `error`, plus `pause_state` (which is in `model.go` but not in the CLAUDE.md list — fix that omission while at it).
- After merge, write `changes/2026-MM-DD-tui-dedup-rendering.md` per project convention. Cover: why (TUI was the missing surface), what shipped (event + render + toggle), wire-protocol additions, and any UX trade-offs (e.g., hide-mode is per-session).
- No migration, no runtime config, no rollout flag. New event is additive; older clients ignore it.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-22-tui-dedup-rendering-brainstorm.md](docs/brainstorms/2026-05-22-tui-dedup-rendering-brainstorm.md)
- **Sibling plan (dedup matcher):** docs/plans/2026-04-25-001-feat-always-on-recording-plan.md (U11 originally introduced `DedupCoordinator`)
- **Pause-state precedent:** changes/ and `daemon/Tests/StenoDaemonTests/Engine/PauseTests.swift` for the engine-emit pattern; `cmd/steno/internal/daemon/protocol.go` and `protocol_test.go` for the wire-protocol mirroring.
- **Pre-push convention:** `.githooks/pre-push` runs `make test`; commits need `[steno-tests-passed: X tests in Ys]` attestation.
