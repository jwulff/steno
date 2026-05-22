# Always-On Recording: Cluster 4 — TUI Surface + Daemon Pause/Demarcate (PR #37)

## Why

The previous three clusters made the daemon always-on, self-healing, and
clean about what it stores:

- **Cluster 1 (PR #33)** — daemon starts recording immediately, orphan
  sweep, schema for dedup + pause + heal markers. See
  `changes/2026-04-26-1200-always-on-recording-foundation.md`.
- **Cluster 2 (PR #35)** — supervisor + heal across recognizer crashes,
  sleep/wake, device changes, SCStream contention. See
  `changes/2026-04-26-1814-always-on-cluster-2-supervisor-heal.md`.
- **Cluster 3 (PR #36)** — cross-source dedup + empty-session prune. See
  `changes/2026-04-26-2234-always-on-cluster-3-dedup-prune.md`.

What's missing is the *user-facing* part of always-on. The TUI still
shows binary `● REC` / `IDLE`. Spacebar still toggles recording (which
makes no sense once recording is always on). There's no way to pause for
privacy. There's no way to mark a session boundary atomically. The
seven engine states the supervisor can produce (recording / paused /
recovering / failed / mic-or-screen permission revoked / disconnected /
stopping) are all collapsed onto two indicators.

This PR is the user-facing payoff. After it merges, **all 12 implementation
units of `docs/plans/2026-04-25-001-feat-always-on-recording-plan.md` are
shipped** (U1 spike skipped per the agreed predefined fallbacks).

This is units **U10/U9** of the plan — U10 first so U9 has commands to
talk to.

## How

### U10 — daemon-side pause / resume / demarcate (commit `89047bc`)

- New `Infrastructure/PauseTimer.swift`: thin wrapper around
  `DispatchSourceTimer.schedule(wallDeadline:)`. **`wallDeadline:` is
  load-bearing** — `DispatchWallTime` is clock-based and advances during
  sleep, where `DispatchTime` (monotonic) would freeze. A user who pauses
  for 30 minutes and then closes the lid for 25 minutes should wake to a
  resumed session, not to "still 5 minutes left".
- Engine actor gains:
  - `pause(autoResumeSeconds:)` — close current session cleanly, tear
    down pipelines, release power assertion, set status `.paused`,
    persist `pause_expires_at = now + autoResumeSeconds` (or `NULL` +
    `paused_indefinitely = 1` for indefinite), arm `PauseTimer` at
    `pause_expires_at`.
  - `resume()` — cancel timer, clear `pause_expires_at`, clear
    `paused_indefinitely`, open new active session, rebuild pipelines,
    take power assertion. Triggered by user command OR by timer expiry.
  - `demarcate()` — timestamp `T = now`. Mark current session
    `endedAt = T`. Open new active session at `T`. Audio pipelines
    continue uninterrupted; segment routing uses start-timestamp
    comparison against `T` (segments started < T → old session, ≥ T →
    new). Empty-session pruner (U12) runs against the just-closed
    session.
  - `restorePausedState()` — replaces the U4-era idle placeholder.
    Called from the daemon-start path: if the most-recently-modified
    session has `paused_indefinitely = 1` → enter `.paused`, no timer.
    If `pause_expires_at` is in the future → enter `.paused`, re-arm
    the timer. If expired and `paused_indefinitely = 0` → resume
    immediately into a new session.
- `EngineStatus.paused` added. New `pauseStateChanged` event.
- `CommandDispatcher` routes `pause`, `resume`, `demarcate` to the
  engine actor.

**Privacy invariant — load-bearing across the whole always-on effort.**
The U4 daemon-start path (PR #33) was the first place this was enforced;
U10 is where it gets its full engine-side machinery. The contract:

> A user who paused indefinitely yesterday must not have their mic
> silently re-engage today, regardless of how the daemon got restarted
> (crash, reboot, launchd, manual).

The implementation honors this in three layers:

1. `paused_indefinitely = 1` is the fixed source of truth. `pause_expires_at`
   stays `NULL` during indefinite pause.
2. **Daemon-start rule** — if `paused_indefinitely = 1` on the
   most-recently-modified session, the daemon MUST remain paused
   regardless of `pause_expires_at`.
3. **Fail-safe** — any DB read error or unrecognized state on the pause
   columns → daemon stays paused, emits `pause_state_unverifiable`
   non-transient health warning, requires explicit user resume. Closes
   the privacy-violation path where a corrupted/unmigrated row could
   otherwise default to "resume into recording".

Also in this commit: a Makefile workaround that gates `test-daemon`
exit on ✔/✘ counts because libdispatch's source teardown on macOS 26
trips the nano-zone allocator's "freed pointer was not the last
allocation" guard during the harness's final aggregation. Every individual
test still passes; the abort fires *after*. Reproduces on prior commits
with sufficient test load — not strictly U10's fault, but U10's added
test surface makes it more reliable. And: `stop()` now awaits canceled
restart tasks before returning, so a `stop` arriving mid-U5-backoff
doesn't leave a task running into the next session.

### U9 — TUI surface (commit `8599f0c`)

- **Keybind remap** in `cmd/steno/internal/app/keymap.go`:
  - `space` → `demarcate` (no longer toggles `recording`).
  - `p` → pause/resume toggle (30-min auto-resume default).
  - `shift-p` → indefinite pause / resume toggle.
  - `e` → error-history modal.
  - `start` / `stop` commands retained on the daemon protocol (and
    TUI command sender) — only their keybinds were removed. Useful for
    diagnostics / scripting.
- **Status bar** is now a 7-state machine with overflow priority:
  - `● REC`
  - `⏸ PAUSED — resumes in HH:MM`
  - `⏸ PAUSED — manual resume only`
  - `⚠ RECOVERING — gap Ns`
  - `✗ FAILED — see error`
  - `✗ MIC_OR_SCREEN_PERMISSION_REVOKED — open Settings → Privacy`
  - `✗ DISCONNECTED` (distinct from RECOVERING — socket-level loss)
  - Plus a `last segment Ns ago` annotation that turns yellow above 60s
    while not paused.
- Per-second tick drives the pause countdown and the last-segment
  indicator.
- **Heal markers** rendered inline in the segment timeline, between the
  boundary segments: `⚠ healed after 12s gap`.
- **First-launch consent banner**, gated on the marker file
  `~/Library/Application Support/Steno/.first_launch_seen`. Renders
  above the timeline (NOT in the status bar — preserves the always-visible
  state surface). Text:
  > Steno is now always-on. Recording started. Press space to mark a
  > session boundary, p to pause for 30 min, shift-p to pause indefinitely.
  > Press any key to dismiss.
  Dismisses on any key; on dismiss, writes the marker file. Persistent
  across sessions but never re-shown. This is the privacy-relevant
  disclosure for the always-on default — TCC's mic/screen-recording
  grants are *capability* grants, not acknowledgement of the recording
  *model*.
- **Default-filter on dedup'd segments**: every segment query in
  `cmd/steno/internal/db/store.go` now appends `WHERE duplicate_of IS
  NULL`. The default view shows one logical transcript per utterance.
- **Error history ring buffer** (last 10) + modal (key `e`).
- **DISCONNECTED state** distinct from RECOVERING (the latter is a
  daemon-emitted health event; the former means the TUI lost the
  socket).
- Go protocol mirror in `cmd/steno/internal/daemon/protocol.go` updated
  for U10's commands and `pauseStateChanged` events.

### A note on event routing

Engine status events (`recovering`, `healed`, `recoveryExhausted`,
`pauseStateChanged`) are still routed over the existing `.error` wire
channel with the `transient` flag distinguishing recovering vs
recovery-exhausted. The TUI sniffs the message prefix to route to
engineStatus. Splitting onto dedicated wire fields is flagged as a
follow-up in the `EventBroadcaster` comment but not blocking.

## Key Decisions

- **Spacebar = demarcate, not start/stop.** Once recording is always on,
  start/stop loses semantic meaning. Spacebar reused for the action
  users now actually want: "this is the boundary between two
  conversations". Atomic in the engine (timestamp T → routing) and
  atomic in storage (single transaction).
- **Two pause keybinds, not a menu.** `p` is the 30-min auto-resume
  default (which is the right choice for "stepping away for a bathroom
  break" — the most common pause case). `shift-p` is the explicit "I am
  paused indefinitely and the daemon should not silently re-engage,
  ever" key. Wall-clock vs indefinite is the privacy-critical
  distinction; representing them as two keys makes the choice
  unmissable.
- **`DispatchWallTime`, not `DispatchTime`.** Tested. A 30-min pause
  with the laptop closed for 25 minutes wakes correctly with 5 minutes
  left (`DispatchTime` would have shown 25 minutes left). The simpler
  primitive is the right one here.
- **First-launch hint is a banner, not a status-bar entry.** The
  status bar is the always-visible state surface; cluttering it with a
  one-shot hint would muddy the most important UX guarantee in the
  product. Banner is above the timeline, dismisses on any key.
- **Marker file for first-launch state**, not stored in the daemon's
  SQLite. The hint is a TUI-side concern; users running the daemon
  headless or via the MCP surface shouldn't see it. A file in
  `~/Library/Application Support/Steno/` is the lightest persistence
  that survives reinstall-and-relaunch.
- **Default segment query filters duplicates.** Every call site through
  `db.Store` gets the filter. The `d` keybind that the plan suggested
  for "show raw view with duplicates" was deliberately cut per the
  plan's Refinements section — adding a keybind for a power-user
  inspection mode in v1 is YAGNI.
- **Demarcate timestamp routing assumes
  `SpeechAnalyzer.result.timestamp == audio-frame start of the
  segment`.** The U1 spike was supposed to verify this empirically; we
  skipped U1 per the plan's predefined fallbacks. If real-world testing
  breaks the assumption, the documented fallback is to plumb wall-clock
  timestamps through the audio path independently. Flagged in the
  commit body so future-us isn't surprised.
- **`STENO_SUPPRESS_FIRST_LAUNCH_BANNER=1` test seam.** Legacy
  keypress tests would otherwise need to mock `$HOME` to stay hermetic.
  The env var is a one-line escape hatch.

## Plan deviations

- **U10** — Makefile gates `test-daemon` exit on ✔/✘ counts because
  libdispatch's source teardown on macOS 26 trips the nano-zone
  allocator during harness aggregation (see "How" above). Not strictly
  U10's fault, but U10's added test surface makes the abort more
  reliable.
- **U10 demarcate timestamp-routing assumption** — U1 spike skipped; the
  plan's predefined fallback (wall-clock timestamps through the audio
  path) applies if real-world testing exposes the assumption as wrong.

## Testing

- **U10** — `PauseTimer` arm / cancel / re-arm / past-deadline; pause
  happy paths (timed + indefinite); resume happy paths; daemon-restart
  restoration (timed-future re-arms / timed-past resumes / indefinite
  stays paused); wake-while-paused is a no-op; persistence-failure →
  `pause_state_unverifiable`; demarcate happy + paused-reject +
  idle-reject + pre-T-vs-post-T routing.
- **U9** — keybind wire-shape (real Unix socket capture); pause-state
  events update countdown; status-bar all 7 variants + overflow policy;
  last-seg threshold colors; error ring-buffer overflow at the 11th
  entry; first-launch banner appears + dismisses + writes marker;
  heal-marker rendering; DISCONNECTED state on socket loss; default
  segment query excludes 5 mic-duplicates-of-5-sys; footer reflects
  engine status.
- Manual verification: built daemon + TUI, ran the live integration test
  against a fresh dev daemon, drove `pause`/`resume`/`pause-indef`/
  `demarcate` over the socket via a smoke client, confirmed wire shapes
  round-trip with the new fields. **Did NOT** physically disconnect
  AirPods — covered by unit tests against bubbletea `Update`.

`[steno-tests-passed: 474 tests in 4.5s]` (349 daemon Swift + 125 Go)
per commit attestation.

## What's Next

After this PR, **all 12 units of the always-on plan are shipped**
(U1 spike skipped per the agreed predefined fallbacks). The success
criteria from the brainstorm
(`docs/brainstorms/2026-04-25-always-on-recording-brainstorm.md`) are in
production:

- never lose a moment to "I forgot to start recording";
- self-heal across sleep/wake/device-change/recognizer-crash;
- mic-vs-system dedup at storage time so the default view is one
  logical transcript per utterance;
- prune empty sessions at every close path;
- rich health surface so the user knows exactly what the daemon is
  doing.

Fast-follows on top of Cluster 4:

- **PR #38** — reverts the 90-day retention default (added in PR #36)
  to indefinite retention.
- **PR #39** — TUI feedback polish: removes a misleading `a` keybind
  that snuck in here, adds a visible session-boundary marker on
  demarcate.
- **PR #43** — system-audio "park" recovery on SCStream -3815 (display
  reconfiguration), refining U8's classifier so display-park doesn't
  burn the bounded-backoff budget.

Splitting engine-status events onto dedicated wire fields (instead of
piggybacking on the `.error` channel with the transient flag) is the
deferred protocol-cleanliness follow-up — flagged in the
`EventBroadcaster` comment.
