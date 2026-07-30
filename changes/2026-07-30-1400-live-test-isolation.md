# Live tests stop assuming they got an idle daemon

## Why

`make test` passed or failed depending on what had run before it, which made the
pre-push hook a coin flip. It blocked landing #86 and #89, and cost several cycles of
"run it again and see."

## What was wrong

Two independent facts collided:

1. **Always-on recording (#32).** A freshly launched daemon is already recording. `start`
   against a recording daemon fails — `RecordingEngineError` 4.
2. **`go test ./...` runs packages in parallel.** `internal/app` and `internal/daemon`
   both drive the *same* shared daemon over its socket, so whichever got there first
   decided the other's starting state.

`internal/app`'s `TestLiveTUIFlow` starts a recording and leaves it running;
`internal/daemon`'s three live tests then fail at `start`. Run either package alone and it
passes, which is what made this look like flakiness rather than a state dependency.

## How

- `ensureIdle(t, client)` in the daemon test package sends `stop` before a test issues its
  own `start`. Safe whether or not anything is recording, and it makes each test's
  precondition explicit rather than inherited.
- The app package's live test does the same inline — it's a different package, and one
  shared helper wasn't worth exporting for a single call site.
- `go test -p 1` in the Makefile. The tests are not merely order-dependent, they are
  *concurrency*-dependent: two packages driving one daemon can interleave a `stop` from
  one into the middle of the other's `start`/`stop` pair. Serializing packages is the only
  honest fix while a single shared daemon is the fixture.

## Key decisions

- **Fixed the tests, not always-on recording.** Auto-starting is the intended product
  behavior (#32). A test fixture that assumes otherwise is the thing that's wrong.
- **`stop` rather than asserting the state.** A test that tolerated either starting state
  would still be at the mercy of a concurrent package changing it mid-run. Establishing the
  precondition is stronger than accommodating it.
- **`-p 1` over `t.Parallel()` juggling.** The shared resource is a whole daemon process,
  not something the Go test runner can arbitrate. The real fix is a per-test daemon on its
  own socket + DB, which is a bigger change than this blocker warrants — noted for later.

## Testing

Verified against the failure's actual precondition: kill the daemon, launch it fresh (so
it is recording), then run the suite. That combination failed reliably before and passes
now, twice in a row with `-count=1` and a fresh recording daemon before each:

```
=== run 1 (cold daemon, recording):
ok  internal/app 8.867s   ok  internal/daemon 13.925s   ok  internal/db   ok  internal/mcp
=== run 2 (cold daemon, recording):
ok  internal/app 7.743s   ok  internal/daemon 13.197s   ok  internal/db   ok  internal/mcp
```

`make test-daemon`: 502 passed, 0 failed.

## What's next

The durable fix is a per-test daemon on its own socket and database, so the live tests stop
sharing a fixture at all. That would also let `-p 1` come back off. Out of scope here — this
change is scoped to unblocking the push gate.

Closes #87.
