# Ghost-Daemon Auto-Heal (PR #34)

## Why

Cluster 1 of always-on recording (PR #33, see
`changes/2026-04-26-1200-always-on-recording-foundation.md`) handled the
"daemon was killed cleanly" recovery case via the orphan sweep — when the
daemon process is gone, the next launch marks its stranded sessions
`interrupted` and opens a fresh one.

It did not handle the *other* failure mode: the daemon process is still
alive, holding its PID file, but its Unix socket has been deleted out from
under it. That actually happened on a dev machine. `Manager.EnsureRunning`
(the TUI-side spawn supervisor introduced in PR #26) saw a PID file
pointing at a live PID, didn't try to spawn, fell through to
`WaitForSocket`, and timed out 30 seconds later with `daemon did not
start: context deadline exceeded`. Recovery required a manual `kill <pid>`
from a second terminal.

That's a usability cliff right where the always-on story needs to be
strongest — the user opening the TUI shouldn't ever see "context deadline
exceeded" because of a stale socket file.

## How

`Manager.EnsureRunning` now distinguishes mid-startup daemons from ghosts
by the **PID-file mtime**:

| PID-file age | Socket reachable? | Action |
|---|---|---|
| any        | yes | short-circuit, return |
| `< 5s`     | no  | daemon may still be binding the socket — keep waiting (existing `WaitForSocket`) |
| `>= 5s`    | no  | **ghost** — SIGTERM, poll up to 3s, escalate to SIGKILL, clean stale PID + socket, fall through to spawn |

The detection-and-kill logic is extracted into `recoverGhostIfNeeded(pid)`
and the SIGTERM → SIGKILL escalation into `killGhost(pid)`, so both are
unit-testable without spinning the full spawn step. `EnsureRunning`'s
public signature is unchanged.

### Identity check before SIGKILL (commit `16c55df`)

The initial heal (commit `fda1afc`) introduced a regression risk that
review caught before merge: a stale PID file plus macOS PID recycling
could point at an unrelated user process. Pre-PR-#34 behavior was an
annoying 30s timeout; the new auto-heal would have SIGTERM+SIGKILL'd a
process that isn't ours.

The fix verifies daemon identity before signaling:

- `processIdentifier` is a function field on `Manager` (so tests can inject
  a mock). The default implementation shells out to `ps -p <pid> -o comm=`
  with a 2s context timeout — `comm=` gives the full executable path on
  macOS, no command-line args, no truncation.
- Decision tree after the 5s grace gate:
  - basename == `steno-daemon` → kill (existing logic)
  - basename is something else → `CleanStale`, no kill, `recovered=true`
  - lookup error / timeout → `CleanStale`, no kill, `recovered=true`
  - lookup empty (PID disappeared between checks) → `CleanStale`,
    no kill, `recovered=true`

The bias is deliberate: a false negative (failing to reap a real ghost) is
recoverable — the subsequent spawn step will surface "socket bind failed"
and the user can intervene. A false positive (killing some unrelated user
process) has no recovery path. We match by basename, not full path,
because the daemon binary lives at `~/.local/bin/steno-daemon`,
`daemon/.build/{debug,release}/steno-daemon`, or wherever
`$STENO_DAEMON_PATH` points.

## Key Decisions

- **PID-file mtime as the ghost signal.** Cheaper and simpler than parsing
  socket-binding errors or trying a `connect()` with a tighter timeout.
  The 5s grace covers the legitimate "daemon is mid-startup, hasn't
  bound the socket yet" window — empirically the daemon binds within
  ~1–2s on dev hardware.
- **3s SIGTERM → SIGKILL escalation.** A daemon that hasn't responded to
  SIGTERM in 3 seconds is wedged badly enough that polite shutdown is
  not going to happen. Bounded so the TUI's first-run experience can't
  be held hostage by a hung process.
- **Identity check by basename, not by checksum or path.** A
  `${STENO_DAEMON_PATH}`-aware solution would have demanded canonicalizing
  the path and handling all the symlink edge cases. Basename-equals
  catches the recycled-PID case without that complexity. The only
  collision is another binary on the system literally named
  `steno-daemon`, which is a non-problem.
- **`recovered=true` even when we *don't* kill.** Stale PID + socket
  files are *always* cleaned in the recovery path, even when the identity
  check tells us not to kill. The caller treats "ghost recovered" and
  "stale files cleaned, no process killed" identically — both unblock the
  spawn step.
- **Test goroutine ownership of `cmd.Wait()`.** The original
  `waitExited` helper called `Wait()` from a goroutine, racing with
  `t.Cleanup`'s own `Wait()` and panicking with "Wait was already
  called". Restructured so a single spawn-time goroutine owns the
  `Wait()` call and publishes the result on a buffered channel; tests
  read from the channel, never call `Wait()` directly. The Copilot
  "zombie on macOS" comment about not reaping via `Wait4(WNOHANG)` in
  production is correct in principle but irrelevant in practice — the
  daemon reparents to launchd quickly and `kill(pid, 0)` returns ESRCH
  there.

## Testing

- Healthy socket short-circuit returns nil immediately.
- Old PID file + live `/bin/sleep` ghost (basename `steno-daemon`
  injected via mock identifier) + sentinel socket file → kill + clean.
- Fresh PID file (`<5s`) + live sleeper → no-op, sleeper unharmed,
  grace gate runs before identity check (verified by injecting a
  panicking identifier).
- SIGTERM-trapping `/bin/sh` script → after the 3s deadline, SIGKILL
  escalation kills it. Test sleeps 150ms after spawn so the trap is
  installed before the first signal arrives — the in-band Wait
  goroutine removed the implicit slack the previous baseline relied
  on.
- Boundary: PID file mtime exactly at 5s → treated as ghost
  (the comparison is `>=`, not `>`).
- PID-reuse safety: injected identifier returning `/bin/sleep` (not
  `steno-daemon`) against a real spawned sleeper → sleeper is NOT
  killed, stale state is still cleaned.
- ps timeout / lookup error → conservative path (clean files,
  no kill).
- Live `ps`-based identifier exercised against a real subprocess and
  against a missing PID (sentinel return: `("", nil)`).

Live-daemon integration tests in `cmd/steno/internal/daemon/` have a
pre-existing flake under parallel `go test ./...` (contention against
real-daemon recording engine). They pass under `go test -p 1 ./...`;
the commit attestation reflects the sequential run.

`[steno-tests-passed: 261 tests in 21s]` per commit attestation.

## What's Next

This lands between Cluster 1 (PR #33) and Cluster 2 (PR #35). It's
independent of the always-on plan but raises the floor for the entire
effort — Cluster 2's supervisor + heal machinery assumes the spawn path
is reliable.

Cluster 2 picks up next with the IOKit power observer, AVAudioEngine
config-change handling, SCStream error-code recovery, and the bounded
backoff loop that replaces the previous no-op `handleRecognizerError`.
