# Always-On Recording: Cluster 3 — Dedup + Prune (PR #36)

## Why

By this point Cluster 1 (PR #33, see
`changes/2026-04-26-1200-always-on-recording-foundation.md`) and Cluster 2
(PR #35, see `changes/2026-04-26-1814-always-on-cluster-2-supervisor-heal.md`)
have the daemon recording continuously and self-healing across crashes,
sleep/wake, device changes, and SCStream contention. That solves
durability. It does not solve the *signal-to-noise* problem the always-on
plan called out (`docs/plans/2026-04-25-001-feat-always-on-recording-plan.md`):

1. **Mic + system audio capture the same speaker twice.** On a Zoom call,
   the remote participant's voice arrives both as system audio (clean,
   the canonical version) and via the laptop mic (passive pickup from
   the speakers). Cluster 1's schema added `duplicate_of` / `dedup_method`
   / `last_deduped_segment_seq` (U2) and `mic_peak_db` precisely so a
   background coordinator could mark the mic side as the duplicate without
   blocking the audio path.
2. **Wall-to-wall always-on capture creates lots of empty sessions.**
   Every spacebar-demarcate, sleep-wake rollover, and device-change
   rollover creates a new session. If the daemon was running while no
   one was speaking — laptop idle in a quiet room, a 2-second false
   start before a sleep — those sessions are noise. They need to be
   pruned at the moment they close.
3. **Unbounded growth.** A continuously-on daemon writing segments
   forever needs *some* retention story before the always-on default
   ships, even if a more sophisticated policy lands later.

This is units **U11/U12** of the plan.

## How

### U11 — DedupCoordinator background pass (commit `30f74e9`)

- New actor `Services/DedupCoordinator.swift`, mirroring the structural
  pattern of `RollingSummaryCoordinator` so it's familiar at a glance.
- Similarity is tiered, computed by a private
  `similarityScore(_:_:) -> (score: Double, method: DedupMethod)` function
  on the coordinator itself (no separate scorer type — pure function):
  1. **Exact** — string equality.
  2. **Normalized** — lowercase, strip punctuation, collapse whitespace.
  3. **Fuzzy** — `1.0 - Levenshtein(a, b) / max(len(a), len(b))`.
  Returns the highest-tier method that matched and its score.
- `runPass(sessionId:)` does the loop:
  - Load segments WHERE `seq > sessions.last_deduped_segment_seq AND
    source = 'microphone'`.
  - For each mic segment, query overlapping sys segments WHERE `sessionId
    = ? AND source = 'systemAudio' AND startedAt BETWEEN micStart - 3 AND
    micStart + 3`.
  - Score; if `score >= 0.92` (default `dedupScoreThreshold`) AND the
    mic-side audio-level guard passes (see below) →
    `UPDATE segments SET duplicate_of=?, dedup_method=? WHERE id=?`.
  - **Cursor advancement is per-mic-seq, NOT pass-max.** Advance
    `last_deduped_segment_seq` only to the maximum `seq` of mic segments
    actually evaluated in this pass — not to `max(seq)` over all
    sources. Mic and sys share `RecordingEngine.currentSequenceNumber`;
    a pass-max advance could skip a mic segment that arrives out-of-order
    after a faster sys segment.
- **Audio-level guard (the user-repeats-the-speaker safety net):**
  before marking a mic segment as duplicate, require its `mic_peak_db`
  (computed at finalize: per-segment max of the existing per-buffer peak,
  linear-PCM → dBFS, -90 dBFS floor) to be below the "passive pickup"
  threshold, default `-25 dBFS`. The case this protects:
  "Did you say merge or merch?" / "Merge" — both sides say "merge" on a
  Zoom call simultaneously and the system audio version would otherwise
  swallow the user's own contribution. A `NULL` `mic_peak_db` skips the
  level guard entirely (back-compat with pre-Cluster-2 segments).
  *When in doubt, KEEP the mic segment.*
- **Per-session reentrance guard.** `DedupCoordinator` holds
  `isProcessing: [UUID: Bool]` keyed by sessionId. Concurrent triggers
  for the same session collapse to a single in-flight pass. Cross-session
  passes can run in parallel.
- **Debounce.** `RecordingEngine` triggers the coordinator from
  `saveSegment()`; multiple triggers within a 5s window collapse to a
  single pass per session.
- Failure-safe: if a pass throws partway, the cursor is NOT bumped — the
  next pass re-evaluates the same segments idempotently. Borderline
  scores produce no DB write (KEEP).

### U12 — empty-session prune at close + retention guard (commit `599b5ed`)

- `SQLiteTranscriptRepository.maybeDeleteIfEmpty(sessionId:) -> Bool`
  cascade-deletes the session and its segments + topics if it meets ANY of:
  - 0 segments.
  - Non-duplicate text < `emptySessionMinChars` (default 20).
  - Duration < `emptySessionMinDurationSeconds` (default 3).
- Safety check: only operates on sessions with `endedAt IS NOT NULL` —
  refuses to prune an `active` session.
- **Wired into every close path.** Engine calls
  `repository.maybeDeleteIfEmpty(sessionId:)` from `stop()`, the
  orphan-sweep close paths, sleep/wake rollover, and device-change
  rollover. Sequencing matters: dedup runs synchronously before pruner
  for the just-closed session so "non-duplicate text length" reflects the
  post-dedup truth — otherwise a Zoom call session full of mic-side
  duplicates of sys content could survive the empty check.
- **Topic extraction is now pruner-aware.** Two changes:
  1. `RollingSummaryCoordinator` gates LLM invocation by a minimum
     segment count — no point burning a 45s LLM call on a session about
     to be deleted.
  2. Topic and summary writes pre-check session existence inside the
     same write transaction. If `RollingSummaryCoordinator` is mid-LLM
     when the session gets pruned, the write becomes a silent no-op,
     not an FK violation. Tested explicitly.
- **90-day retention guard.** At daemon start, run `DELETE FROM sessions
  WHERE endedAt IS NOT NULL AND endedAt < (now - retentionDays * 86400)`
  with cascade. Default 90 days, configurable via `StenoSettings`. This
  is the minimum hedge against unbounded growth so the always-on default
  can ship; a more sophisticated retention policy is still deferred.

## Key Decisions

- **Background coordinator, not inline at insert time.** The dedup work
  is `O(mic_segments × overlapping_sys_segments)` per pass; running
  inline would block the audio write path with no upside. As long as
  the default TUI/MCP query filters `duplicate_of IS NULL`, the user
  never sees pre-dedup state — eventual consistency is fine.
- **Threshold `0.92` (default).** Empirically: exact matches score 1.0,
  normalized matches usually 1.0, fuzzy matches on real transcription
  noise tend to land in `[0.9, 0.99]`. `0.92` cuts off the long tail of
  "same length, different content" pairs.
- **Audio-level guard at -25 dBFS.** Passive room pickup from laptop
  speakers is consistently below -25; actively-spoken content from the
  laptop user is consistently above. The threshold isn't sacred — it's
  in `StenoSettings` — but the default lands in the right region from
  bench testing.
- **NULL `mic_peak_db` skips the guard.** Pre-Cluster-2 segments don't
  have peak data, and we shouldn't refuse to dedup them just because
  they predate the column. Skipping the guard for NULL means the worst
  case is "we marked content the user spoke as a duplicate" — which is
  recoverable: `duplicate_of` is a column, not a destructive write, so
  any SQLite client (or the MCP surface against the read-only WAL) can
  query the unfiltered rows directly. Cluster 4's plan originally
  included a `d` keybind to toggle the duplicate-inclusive view in the
  TUI; that keybind was deliberately cut as YAGNI (see the Cluster 4
  changes file), so the recovery path is "read the column" rather than
  "press a key".
- **Per-mic-seq cursor, not pass-max.** Documented above — closes the
  interleaved-seq trap. The plan called this out explicitly; the
  implementation matches.
- **Repository-level prune, not a separate `SessionPruner` class.**
  `maybeDeleteIfEmpty` is one conditional query-then-delete. A separate
  service would have meant a new injection target with no behavioral
  benefit.
- **Dedup before prune.** Sequencing is explicit at every close path,
  not hoped-for. A 60s Zoom-call session where every mic segment is a
  duplicate of a sys segment should be *kept* (non-dup text from the
  sys side is well over 20 chars); the order matters or you'd drop it.
- **90-day retention as a hedge.** The plan called this "minimum hedge
  against unbounded growth, configurable, replaceable later". Shipping
  with *some* cap is the cheap way to make always-on safe to default-on.
  See "What's Next" for the follow-up.

## Plan deviations (each captured in the relevant commit body)

- **U11** — both-empty similarity returns `(0.0, .fuzzy)` rather than
  `(1.0, ...)`. Schema CHECK already rejects empty text at storage; the
  mock test exercises the path and asserts KEEP, matching the
  "borderline → KEEP" spirit.
- **U12** — sentinel "U12 disabled" mode (`emptySessionMinChars=0`,
  `emptySessionMinDurationSeconds=0`) added so the pre-existing U6/U7
  rollover tests don't need to be rewritten — they still assert the
  post-rollover session presence they were designed for. A new
  `EmptySessionPruneIntegrationTests` covers the prune-on-rollover
  semantic separately. Pragmatic choice; the alternative was rewriting
  every rollover test.
- **U12** — defensive topic/summary writes use option (a): explicit
  session-existence pre-check inside the same write transaction.
  Doesn't swallow non-FK constraint violations.

## Testing

- **U11**: exact / normalized / fuzzy match thresholds; KEEP on
  borderline; cursor idempotency (re-running produces 0 updates);
  per-mic-seq cursor advancement against interleaved sys segments;
  partial-failure idempotency; debounce collapses 10 saves within 5s
  into 1 pass; default `WHERE duplicate_of IS NULL` query returns 1 row
  per logical utterance after the pass; audio-level guard (loud mic =
  KEEP, passive mic = mark, NULL = no guard).
- **U12**: all 8 empty-criteria scenarios (0 segs, <20 chars,
  ≥3s+50chars KEEP, exactly 3s KEEP, all-duplicate segs, `status=active`
  refused, `endedAt IS NULL` refused). Engine integration: `stop()` on a
  1s session deletes it via dedup-then-prune; topic extraction skipped
  on too-few-segment session; mid-LLM-call prune is a silent no-op (no
  FK violation); 90-day retention deletes 100d-old sessions and keeps
  30d-old.

`[steno-tests-passed: 442 tests in 5.3s]` (352 Swift + 90 Go) per commit
attestation.

## What's Next

- **Cluster 4 (PR #37)** — the final cluster: U10 daemon
  `pause`/`resume`/`demarcate` commands with wall-clock pause timer, and
  U9 the user-facing TUI surface (spacebar = demarcate, `p` / `shift-p`
  for pause, full health-state status bar, default-filter on dedup'd
  segments, first-launch consent banner). After Cluster 4 ships, all 12
  units of the plan are in production.
- **Retention follow-up (PR #38).** The 90-day cap added here was
  reverted in PR #38 to indefinite retention (`retentionDays = nil` /
  `0` semantics, depending on representation). The 90-day default
  proved more aggressive than users wanted given how cheap SQLite + WAL
  is on modern disks; the more nuanced retention policy that would
  justify a default cap is still a deferred follow-up.
