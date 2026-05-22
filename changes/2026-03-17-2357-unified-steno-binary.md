# Unified `steno` Binary (PR #26)

## Why

After PR #24 landed the MCP server, the repo had three binaries:

- `steno-daemon` (Swift) — the backend
- `steno-tui` (Go) — the bubbletea TUI
- `steno-mcp` (Go) — the MCP stdio server

The two Go binaries shared 90% of their code: the same SQLite store, the
same models, the same `modernc.org/sqlite` driver. They drifted: `tui/`
had its own `db/store.go`, `mcp/` had a different one, neither was the
superset. Worse, users had to remember which binary did what, install
both, keep them in lockstep, and manually start the daemon before the
TUI could connect.

The fix is to collapse the Go side into a single `steno` binary that
behaves correctly in either mode:

- Default invocation (`steno`): auto-start the daemon if not running,
  then connect and show the TUI.
- `steno --mcp`: serve MCP stdio over the same shared DB store.

This shrinks the install footprint from 3 binaries to 2, deletes
duplicate code, and removes the "did you start the daemon?" friction.

## How

### New layout under `cmd/steno/`

```
cmd/steno/
├── main.go              # --mcp flag dispatches mode
└── internal/
    ├── app/             # bubbletea TUI (moved from tui/)
    ├── daemon/          # socket client + lifecycle manager (NEW manager)
    ├── db/              # superset store, shared by TUI and MCP
    ├── mcp/             # tool handlers (moved from mcp/internal/tools/)
    └── ui/              # lipgloss styles
```

`tui/` and `mcp/` directories deleted entirely. `internal/db/store.go`
is the merged superset of the two previous stores — every query either
side needed is now in one place.

### DaemonManager: auto-start the backend

`internal/daemon/manager.go` (new — 231 lines + 187 lines of tests) owns
the daemon's process lifecycle from the Go side:

1. **PID file check** at `~/Library/Application Support/Steno/steno.pid`.
   Verify liveness with `kill(pid, 0)`; if the PID file exists but the
   process is gone, treat as crashed.
2. **Stale socket cleanup** — if `steno.sock` is left over from a
   previous crash, remove it before spawning.
3. **Binary lookup**, in order:
   - Co-located: `steno-daemon` next to the `steno` binary
     (the `make install` layout)
   - `$STENO_DAEMON_PATH` env var (test/dev override)
   - `$PATH` lookup (Homebrew, manual install)
4. **Spawn with `setsid`** so the daemon survives `steno` exiting.
5. **Socket readiness polling** — 100ms interval, 30s timeout, waits
   until the daemon accepts a connection on the Unix socket before
   returning control to the TUI.

Tests cover: fresh start, already-running daemon, stale PID file with
dead process, missing binary, daemon that takes 2s to come up, daemon
that never comes up (timeout).

### What did NOT change

- **Swift daemon code** — completely untouched. The Swift package, the
  entitlements, the Info.plist, all the same files. This refactor is
  pure Go-side.
- **NDJSON protocol** — same commands, same events, same shape.
- **SQLite schema** — same writer, same reader contract.
- **TUI UI and behavior** — pixel-identical to the previous `steno-tui`.
- **MCP tools and responses** — pixel-identical to the previous `steno-mcp`.

`STENO_DB` env var is honored in both TUI and MCP modes for test setups
that point at a non-default DB path.

## Key Decisions

- **One Go binary, two modes, dispatched by `--mcp` flag.** The
  alternative — two binaries that share an internal package — would
  have kept the install surface at 3 binaries. A single binary with a
  flag is the smallest viable distribution.
- **Auto-start the daemon from the TUI, not from a wrapper script.**
  Wrapper scripts are easy to write but hard to debug when they fail
  (which permissions? which PID? which socket?). Putting lifecycle
  management inside the Go binary means errors are structured Go
  errors with clear messages, not opaque shell exit codes.
- **`setsid` for the spawned daemon.** Without it, the daemon would
  inherit the TUI's process group and die when `steno` exits. With it,
  the daemon outlives the TUI — which is the whole point of having a
  daemon.
- **Co-located binary lookup first.** `make install` puts `steno` and
  `steno-daemon` in the same `~/.local/bin/`; the lookup matches that
  shape so the common path doesn't require `$PATH` to resolve a sibling.
- **Delete `tui/` and `mcp/` outright, no shim.** Tests pass on the new
  layout, so there's no value in keeping the old paths around. A clean
  delete makes `git blame` and IDE navigation honest about where code
  lives.
- **30s socket readiness timeout.** Long enough that a cold-start
  SpeechAnalyzer model download can complete; short enough that a
  truly stuck daemon surfaces a clear error instead of hanging the TUI
  forever. If 30s is wrong in practice, the right fix is a progress
  surface in the TUI, not a longer timeout.

## Testing

- 80 Go tests (TUI + daemon-client + MCP + manager) + 137 Swift tests
- New `manager_test.go` covers all DaemonManager paths with mocked
  binary discovery and a stub socket server
- Pre-push hook passed on every commit in the branch

[steno-tests-passed: 217 tests (80 Go + 137 Swift)]

## What's Next

- **PR #27 will remove the legacy Swift TUI and dead code** — the old
  `Sources/Steno/` monolith is no longer referenced by anything, and
  the `make test-legacy` target was carrying it forward purely to keep
  CI green during this refactor. Next PR drops both.
- A `make install` audit pass to make sure the new two-binary install
  cleanly removes the three-binary one (the Makefile change in this PR
  starts that work).
- Consider a `--no-auto-start` flag for tests or dev workflows that
  want to point at an externally-managed daemon.

Closes #25.
