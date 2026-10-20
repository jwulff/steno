# Re-arm always-on capture when a wake finds the engine idle

Fixes #111.

## Why

`.idle` was an absorbing state, the same shape as #109 but on the other
side of the state machine. Once the engine reached `.idle` it stayed there
for the life of the daemon process.

`.idle` is reachable from exactly three places: the initial value
(`RecordingEngine.swift:24`), the `.paused` branch of `stop()`, and the tail
of a full `stop()`. So in practice it means "a client sent `stop`". Always-on
recording (#32) removed the user-facing start/stop, but `stop` is still a
valid wire command, and after it:

| Path | Why it does not recover |
|---|---|
| `handleSystemDidWake` | returns early at `guard let session = currentSession`, and `stop()` nils the session |
| `handleSystemWillSleep` | explicitly declines to move off `.idle` |
| `start()` | admits `.idle`, but only a client can call it |
| the plan's recovery section | scoped entirely to `error`; its periodic re-attempt was never implemented |

So one `stop` from any client permanently disables an always-on recorder.
On the machine that prompted this, that was 58 hours of silence across
roughly 180 wakes, with the daemon alive and answering `status` the whole
time. Nothing in either UI looked wrong, because `idle` rendered with the
same neutral dot as `starting` and `stopping`.

## How

A wake re-applies the always-on arm rule when the engine is `.idle`.

The important part is that it is the *same* rule daemon start already runs,
not an unconditional `start()`. `stop()` called from `.paused` clears the
in-memory pause markers and lands in `.idle`, but deliberately leaves the DB
anchor (`pause_expires_at` / `paused_indefinitely`) on the session row. Engine
state therefore cannot distinguish a stopped-while-paused engine from a
plainly stopped one, and a naive "idle plus wake means record" would resurrect
capture on a machine the user had explicitly paused. Only the row knows.

That check already existed inside the daemon-start path, inline. It is now
factored into `pauseAnchorState()` returning `active` / `inactive` /
`unverifiable`, and both callers go through it, so the two cannot drift apart.
They are the same question ("may this daemon begin capturing on its own?")
asked at two different moments. The daemon-start path keeps its existing
behaviour exactly, including its `pause_state_unverifiable` emit.

`unverifiable` is fail-safe in both callers: if the anchor cannot be read we
cannot prove the user is not paused, so capture stays stopped and a
non-transient event carries the same `pause_state_unverifiable` token that
U9's TUI surface and U10's health-warning machinery already match on.

A failed re-arm is not fatal. `start()` has already set `.error` or
`.unsupported` and emitted its own detail; the re-arm adds a transient event
and the next wake tries again.

### Visibility

The engine fix is invisible on a Mac that does not sleep, and the state was
unreadable in both UIs regardless, so both now say so:

- Go TUI: `idle` renders as `⚠ NOT CAPTURING — daemon idle` in the recovering
  (warning) style instead of `○ IDLE` in the neutral one. `StatusUnknown` is
  split out of that branch and stays neutral, because unknown is not evidence
  that capture is off. The legacy `recording: bool` path is untouched.
- Swift app: `DaemonHealth` gains a `notCapturing` case at `warn` severity and
  `.idle` maps to it. It was previously classified `.healthy`, alongside
  `.recording` — a stopped always-on daemon reported as healthy.

## Key decisions

- **Wake, not a periodic timer.** The plan's unimplemented trigger #3 is a
  60s re-attempt. A wake is where this actually bites, it needs no new timer
  and no retry-storm budget, and it reuses plumbing that already exists. The
  cost is honest and worth stating: a Mac that never sleeps will not re-arm.
  A periodic tick remains the more complete answer and is a separate change.
- **Read the pause anchor, not the engine status.** See above. This is the
  privacy invariant #111 asks to keep, and engine state alone cannot express
  it.
- **`stop` keeps its current meaning.** It still ends the session and still
  lands in `.idle`. What changes is that `.idle` is no longer terminal. That
  keeps every existing client and test working while reducing the blast
  radius of an unpaired `stop` (#110) from "forever" to "until the next wake".
- **Opt-in, default `false`.** `reArmIdleOnWake` in `StenoSettings`,
  decoded with `decodeIfPresent` so existing settings files are unaffected.
  This started as an off switch with a `true` default; review flipped it.
  An incidental `stop` (a script, a test) and a deliberate privacy `stop`
  are the same wire command, and only a pause writes an anchor, so a `true`
  default would resume capture after a stop the user meant. With the
  default, `stop` stays terminal and the UI change below is what makes the
  stopped state visible. Set it `true` to get the self-healing wake.
- **A failed re-arm retries on the next wake.** A re-arm whose `start()`
  throws lands in `.error`, not `.idle`. `wakeRearmFailed` marks that one
  cause, so the next wake tries again without turning wake into a retry
  point for unrelated errors such as a revoked permission.
- **A re-arm abandons if the system slept again while it was suspended.**
  The anchor read and the `recovering:` emit both suspend the actor. If a
  sleep lands meanwhile, `gapStartedAt` is set again, and starting would
  bring capture up after that sleep's teardown. The re-arm checks it, and
  that the engine is still idle, right before `start()`.
- **`pauseAnchorState()` uses `nowProvider()`** where the daemon-start path
  used a bare `Date()`. Identical in production, since `nowProvider` defaults
  to `{ Date() }`, and testable everywhere else.

## Testing

Five tests in `SleepWakeHandlerTests`, covering the rule and each way out of
it. The first two were verified to fail against the unfixed engine (8 failed
expectations); the three negative ones passed before the fix and are there to
stop it over-reaching.

- `wakeFromIdleReArms` — stop, sleep, wake, and assert `.recording`, a
  re-acquired power assertion (taken only on entry to `.recording`, so it is
  independent proof of the transition), a *fresh* session rather than a
  resurrected one, and an announced re-arm.
- `wakeFromIdleRespectsPauseAnchor` — pause indefinitely, then `stop` (which
  lands in `.idle` with the anchor still on the row), then sleep/wake. Must
  stay idle with no assertion held. This is the privacy invariant.
- `wakeFromIdleReArmsPastExpiredPauseAnchor` — an expired timed anchor is not
  an active pause, so the same wake re-arms.
- `wakeFromIdleFailsSafeOnUnreadablePauseAnchor` — repository read fails;
  stays idle and emits the non-transient `pause_state_unverifiable` token.
- `wakeFromIdleRespectsDisabledSetting` — the setting off (the default).
- the review fixes: a failed re-arm is retried on the next wake, an
  unrelated `.error` is not, and `wakeReArmAbandonsWhenSleepBeginsWhileSuspended`
  parks the re-arm in its anchor read, runs a sleep, and asserts the engine
  stays idle with no power assertion. That last one fails without the
  `gapStartedAt` check.

Plus one app test (`idleIsNotHealthyOnAnAlwaysOnDaemon`) and three TUI tests
(`TestStatusLabelIdleReadsAsNotCapturing`, the legacy-`recording` guard, and
`TestStatusLabelUnknownStaysNeutral`).

`make test` passes: daemon 0 failures, `go test -p 1 ./...` green across 7
packages, app suite 44 tests in 6 suites.

Worth flagging for whoever reads the attestation: `test-daemon`'s passed-count
is not reproducible. The teardown abort the target already works around
truncates the tail of the log, so consecutive runs of the *same* tree report
different totals (pristine `main` gave 518 and then 511 on back-to-back runs).
Zero failures is the meaningful signal; the count is a floor.

## What this does not close

- A Mac that never sleeps still never re-arms. The periodic re-attempt from
  the plan is the general fix and is still unimplemented.
- `.error` with no `currentSession` still has no autonomous recovery. #109 /
  PR #112 cover `.error` *with* a session; this covers `.idle`. The
  no-session error case remains open.
- The underlying reason a `stop` arrives unpaired in the first place is #110.
  This bounds the damage; it does not stop the test suite sending the `stop`.
