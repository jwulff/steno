# Always-On Recording: Foundation — U2/U3/U4 (PR #33)

## Why

Steno was a "start a session, talk, stop the session" tool. The user had to
remember to launch it before a meeting, and a daemon crash mid-call would
leave segments stranded with no recovery. The always-on-recording plan
(`docs/plans/2026-04-25-001-feat-always-on-recording-plan.md`) reframes the
product as a daemon that's always recording, self-heals around crashes,
sleeps, and TCC revocations, and cleanly demarcates sessions on demand.

That plan is large — 12 units of work (U1–U12). This PR is **Cluster 1**:
the foundation that the supervisor (PR #35), dedup (PR #36), and TUI
surface (PR #37) all need to land on top of.

**U1 (the sleep/wake spike) was skipped** — empirically validating
sleep/wake behavior requires hardware events that can't be automated. The
plan's "Refinements" section pre-defines fallbacks if any of U1's
assumptions break in U5–U8, which is the safer pattern than gating the
whole effort on a manual experiment.

## How

### U2 — schema migration (commit `0374760`)

Added migration `20260425_001_dedup_and_heal` to
`DatabaseConfiguration.swift`:

| Table      | New columns                                                                   |
|------------|-------------------------------------------------------------------------------|
| `segments` | `duplicate_of`, `dedup_method`, `heal_marker`, `mic_peak_db`                  |
| `sessions` | `last_deduped_segment_seq`, `pause_expires_at`, `paused_indefinitely`         |

Plus a partial index `idx_segments_dedup` on the un-deduped subset (the
hot path the dedup coordinator will scan in PR #36), and `PRAGMA
journal_mode=WAL` enabled on the writer connection so future readers
(MCP, TUI) can scan without blocking the daemon.

`dedup_score` and `opened_by` are deferred per the plan — the columns
that land here are exactly the ones U4–U12 need; speculative columns
stay out until something writes to them.

### U3 — version gate + exit-code audit (commit `2e9f9bb`)

Added `MacOSVersionGate` at `RunCommand.run()`. The gate uses a runtime
`OperatingSystemVersion` check (not `#available(macOS 26.0, *)`) because
the binary already targets macOS 26 — `#available` would compile away to
a tautology while runtime check still catches a user copying the binary
onto an older host.

Audited every terminating path through the daemon against launchd's
`KeepAlive { SuccessfulExit = false }` contract: a successful exit must
not be auto-restarted, and a crash must be. The audit found no bugs —
every error path already exits non-zero and every clean shutdown exits
zero. `ProcessType = Interactive` was deferred per the plan; it's a
launchd plist change that doesn't need to land with the code.

### U4 — orphan sweep + auto-open fresh session (commit `90dcc60`)

New repository call `recoverOrphansAndOpenFresh()` does the whole
recovery in a single transaction: any open-but-untouched session from a
prior daemon process is marked stranded (with a heal marker), and a
fresh session is inserted for the new process to write into.

Engine-side, `recoverOrphansAndAutoStart()` calls the repository sweep
and then reuses `bringUpPipelines()` (extracted as a seam so future
healers in U5–U8 can call it the same way). Wired into `RunCommand`
right after init.

**Privacy guard (closes plan risk R-F).** The most-recently-modified
session is inspected before auto-start. If it has
`paused_indefinitely=1` OR `pause_expires_at` in the future, the daemon
sweeps orphans but does **not** auto-start recording. A user who paused
the mic explicitly should never have it silently re-engaged by a daemon
restart. The actual `paused` engine state lands in U10 (PR #37) — until
then, restored pauses leave the engine idle until the user resumes via
the (future) TUI command. The privacy invariant holds either way.

`StenoSettings` gains `lastDevice` and `lastSystemAudioEnabled`,
persisted on every successful start so the auto-open path reproduces
the user's prior config.

## Key Decisions

- **Ship the foundation, defer the spike.** U1 was a hardware-bound
  experiment with no automation path. Cluster 1 hardcodes safe fallbacks
  in U5–U8's design so the spike's outcome is no longer load-bearing.
  Pragmatic — don't gate a large refactor on a manual experiment that
  may never get scheduled.
- **Privacy invariant: pause state survives daemon restart.** If a user
  paused indefinitely yesterday, today's daemon launch does not start
  the mic. This is treated as a load-bearing rule for the whole
  always-on effort, not an optional polish — `AutoStartTests.swift`
  exercises it explicitly across indefinite/future/past pause flags.
- **WAL mode on the writer, set during migration.** The MCP server and
  TUI (readers) already wanted WAL for non-blocking scans, but the
  authoritative place to enable it is the writer's connection. Migration
  is the right moment to flip the pragma — it's a one-shot setting that
  persists in the SQLite file.
- **Runtime version gate, not `#available`.** `#available(macOS 26.0, *)`
  is checked at compile time against the deployment target; since the
  binary already targets macOS 26 it would tautologically pass. A runtime
  `ProcessInfo.processInfo.operatingSystemVersion` check catches the real
  failure mode: a user copying the binary onto an older host.
- **Partial index, not a full index.** `idx_segments_dedup` covers only
  the un-deduped subset — the only rows the dedup coordinator scans.
  Saves index size and write cost on every segment insert.
- **Single-transaction orphan sweep + insert.** Two reasons: the
  invariant "exactly one open session per daemon process" must hold
  even if the daemon crashes mid-sweep, and SQLite WAL transactions are
  cheap enough that one round-trip vs. two is not worth the complexity
  of crash-recovery code that handles a half-applied sweep.
- **`bringUpPipelines()` extracted as a reusable seam.** U5–U8 will all
  want to restart the audio pipeline without redoing recovery. Pulling
  it out now means those PRs add no new entry points — they just
  call this one.

## Plan deviations (each captured in the source commit body)

- **U2** — migration registered inline in `DatabaseConfiguration.swift`
  rather than a separate `Migrations/` file. Matches three established
  precedents in the same enum; introducing a Migrations directory for one
  migration would be premature.
- **U3** — runtime `OperatingSystemVersion` check instead of
  `#available(macOS 26.0, *)`. `#available` is compile-time and the binary
  already targets macOS 26.
- **U4** — default device is `nil` (system default mic), not the
  plan-suggested `"MacBook Pro Microphone"`. That string is a real device
  name that varies per Mac model and locale.

## Testing

- **U2**: fresh DB has new columns + types + defaults; existing-DB row
  migrates with safe defaults; idempotent on re-run; partial index
  selected by `EXPLAIN QUERY PLAN`; on-disk writer is in WAL mode.
- **U3**: version gate accepts 26.0+ and rejects 14.x/25.x with the exact
  stderr message; exit-code policy verified across every subcommand.
- **U4**: orphan sweep against fresh DB, single stranded session,
  multiple stranded sessions, zero-segment orphan, completed-untouched,
  race vs. just-inserted-row; auto-start happy path, permission denied,
  audio-source failure, pause-state-restore across indefinite / future /
  past pause flags.

[steno-tests-passed: 281 tests in 8s]

## What's Next

This is Cluster 1 of four:

- **Cluster 2 (PR #35)** — supervisor + heal: U5 (bounded backoff
  restart), U6 (IOKit power observer + power assertion), U7
  (AVAudioEngine config-change healer), U8 (SCStream error-code recovery
  + TCC-revocation surface).
- **Cluster 3 (PR #36)** — U11 cross-source dedup coordinator + U12
  empty-session prune at close and 90-day retention guard.
- **Cluster 4 (PR #37)** — U9 always-on TUI surface, U10 pause / resume /
  demarcate commands with wall-clock pause timer.

PR #34 lands separately between U4 and Cluster 2 to fix a ghost-daemon
recovery edge case the orphan sweep doesn't cover (PID alive but socket
dead).
