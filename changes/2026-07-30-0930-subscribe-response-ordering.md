# Subscribe answers before it starts talking

## Why

`make test` failed on a healthy machine with a running daemon, so the pre-push hook
blocked every push. The symptom was terse and misleading:

```
--- FAIL: TestLiveDaemonConnection
    smoke_test.go:57: subscribe not ok:
```

An empty error string, from a handler that returns `DaemonResponse.success()`
unconditionally and cannot fail.

## How

`CommandDispatcher.handle` computed a response through a switch and wrote it in a shared
tail. For `subscribe`, the handler's own work put bytes on the client's socket *before*
that tail ran:

- `broadcaster.subscribe(client:events:)` registers the connection, opening the event
  stream on it. While recording, level events alone fire at 10Hz.
- #62's `broadcaster.replay(readiness, toClient:)` writes a `model_status` line
  immediately, whenever the engine has reported readiness.

A client reads the socket line by line. Whatever landed first got decoded as the
subscribe response — an event line has no `ok` field, so Go's zero value made it
`ok=false` with an empty `error`. Hence "subscribe not ok:" with nothing after the colon.

`subscribe` now takes an early-return path in `handle`: write the response, *then*
`activateSubscription` registers the client and replays readiness. A new `send` helper
carries the response write for both paths.

## Key decisions

- **Early return rather than a deferred-side-effect closure.** Returning
  `(response, () async -> Void)` from every handler would tax eight commands to serve one.
  The `subscribe` special case is three lines at the top of `handle` and says plainly what
  the ordering constraint is.
- **Fixed at the daemon, not the client.** The Go client could skip event lines while
  waiting for a response, but that only papers over a protocol the daemon controls: a
  command's response should precede anything that command causes to be written. Once a
  connection is a subscriber, interleaving on it is expected and the client already
  handles it.
- **Both failure modes covered by tests, not just the replay.** The replay is what made it
  reproducible, but registering the client before responding is the deeper bug — a
  recording daemon broadcasting level events at 10Hz hits it with no replay involved.
  `subscribeResponsePrecedesBroadcastEvents` pins the general invariant; it passed before
  this change and would catch a regression that reintroduces the race by another route.
- **`MockClientConnection.sentLines` is new.** The existing `sentResponses` and
  `sentEvents` helpers each filter the other kind out, so neither can express "what did
  the client see first" — which is the entire contract here.

## Testing

`make test-daemon`: 452 passed, 0 failed, including two new
`CommandDispatcherTests`. `subscribeResponsePrecedesReplayedEvents` fails on the parent
commit with the exact observed shape (`model_status` line first, response second) and
passes here.

Verified end-to-end against a live daemon built and installed from this branch:
`go test ./internal/daemon/ ./internal/app/ -count=1` → both `ok`. Before the fix, five
tests failed; `TestLiveDaemonConnection` and `TestLiveTUIFlow` were fixed outright by the
ordering change.

Also renders `*bool` / `*int` protocol fields as values instead of pointer addresses in
these tests' log and error output — `recording=0x7a07d8bb0108` became `recording=false`.
Shared `derefBool` / `derefInt` helpers in the daemon test package; one inline fix in the
app package.

## What's next

Two things found in the same run, both filed rather than fixed here:

- **#87** — the remaining three live tests depend on prior test state. They assume an idle
  daemon, but always-on recording (#32) means a cold-started daemon is already recording,
  so they pass or fail depending on what ran before them. Each passes individually; the
  package passes on a second consecutive run.
- Cold-start socket bring-up takes ~10s because `FluidAudio.DownloadUtils` retries a
  failing Sortformer v2.1 download first (`invalid (empty file); refusing to cache it`)
  before the socket binds. Noted on #86; socket availability arguably should not sit behind
  a model download.

Closes #86.
