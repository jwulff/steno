---
title: "refactor: Merge Go TUI and MCP into single binary with daemon lifecycle management"
type: refactor
status: active
date: 2026-03-17
origin: docs/brainstorms/2026-02-07-three-component-architecture-brainstorm.md
---

# Merge Go TUI and MCP into Single Binary with Daemon Lifecycle Management

## Overview

Consolidate the three-binary Steno distribution (`steno-daemon`, `steno-tui`, `steno-mcp`) into a two-binary distribution: the Swift daemon stays as-is, and a single Go binary (`steno`) replaces both the TUI and MCP server. The Go binary auto-starts the daemon, manages its lifecycle, and provides both TUI and MCP modes via a flag.

**Before:** User installs 3 binaries, manually starts the daemon, then runs the TUI separately.
**After:** User runs `steno` and everything just works — daemon auto-starts, TUI appears, transcription begins.

## Problem Statement / Motivation

The current three-binary architecture creates friction:
- Users must know to start `steno-daemon` before running `steno-tui`
- Three separate binaries to install, update, and keep in sync
- The TUI shows "Daemon not running. Reconnecting..." if the daemon isn't started — confusing for new users
- Two separate Go modules (`tui/` and `mcp/`) duplicate the entire `internal/db/` package (models, store, queries, test utilities)
- Three separate `make` targets, three test suites, three install steps

The three-component architecture brainstorm (2026-02-07) explicitly left "single `brew install steno`" as an open question. This plan resolves it.

## Proposed Solution

### Two binaries, one entry point

```
steno                → TUI mode: auto-start daemon, connect, show live UI
steno --mcp          → MCP mode: stdio JSON-RPC server (read-only DB, no daemon mgmt)
steno-daemon run     → Swift daemon (unchanged)
```

### Architecture after refactor

```
steno (Go)
├── main.go                    # Flag parsing, mode dispatch
├── internal/
│   ├── app/                   # Bubbletea TUI (existing, from tui/)
│   ├── daemon/                # Socket client + protocol (existing, from tui/)
│   │   ├── client.go
│   │   ├── protocol.go
│   │   └── manager.go         # NEW: daemon lifecycle management
│   ├── db/                    # Unified database (merged from tui/ + mcp/)
│   │   ├── store.go           # Superset of both stores
│   │   ├── models.go
│   │   └── testutil.go
│   ├── mcp/                   # MCP server (moved from mcp/internal/tools/)
│   │   └── server.go
│   └── ui/                    # Lipgloss styles (existing, from tui/)
└── go.mod                     # Merged dependencies
```

## Technical Approach

### Key Architectural Decisions

**1. TUI auto-starts daemon, but only reconnects on crash (never restarts)**

The TUI starts the daemon as a **detached process** on launch if it's not already running. But if the daemon crashes while the TUI is connected, the TUI only reconnects with backoff — it does not try to restart. Rationale:
- If launchd is managing the daemon, it handles restarts (avoiding races)
- If the user started manually, a crash likely indicates a persistent problem (permissions, entitlements) — auto-restart would just crash-loop
- The TUI shows the error and guidance instead

**2. Daemon is spawned detached (outlives TUI)**

The daemon is started with `syscall.SysProcAttr{Setsid: true}` so it survives TUI exit. stdout/stderr redirect to `~/Library/Application Support/Steno/daemon.log`. This matches the launchd behavior.

**3. Daemon binary lookup: co-located first, then PATH**

```go
func findDaemon() (string, error) {
    // 1. Same directory as the steno binary
    exe, _ := os.Executable()
    colocated := filepath.Join(filepath.Dir(exe), "steno-daemon")
    if _, err := os.Stat(colocated); err == nil {
        return colocated, nil
    }
    // 2. $STENO_DAEMON_PATH override
    if p := os.Getenv("STENO_DAEMON_PATH"); p != "" {
        return p, nil
    }
    // 3. PATH lookup
    return exec.LookPath("steno-daemon")
}
```

**4. Socket readiness polling with child process monitoring**

After spawning the daemon, poll for socket availability while monitoring the child process:
- Poll socket path existence every 100ms
- On each iteration, check if child exited (via `Process.Wait` in a goroutine)
- 30-second timeout
- On timeout or early exit: read last lines of daemon.log, surface error to user

**5. MCP mode is read-only, no daemon management**

`steno --mcp` opens the SQLite database directly and serves MCP tools over stdio. It never starts, stops, or connects to the daemon. If the database doesn't exist, it exits with a clear error: "No steno database found. Run steno to start recording first."

### Implementation Phases

#### Phase 1: Consolidate Go Modules

Merge `tui/` and `mcp/` into a single Go module. No new functionality — just code organization.

**Tasks:**
- [ ] Create new unified Go module at project root or `cmd/steno/`
- [ ] Merge `internal/db/` — use MCP's store (superset) as base, add TUI-only methods (`LatestSession()`)
- [ ] Move `internal/daemon/` (socket client, protocol) from TUI
- [ ] Move `internal/app/` (bubbletea model) from TUI
- [ ] Move `internal/ui/` (lipgloss styles) from TUI
- [ ] Move `internal/mcp/` (MCP tools) from MCP's `internal/tools/`
- [ ] Create `main.go` with `--mcp` flag: dispatch to TUI or MCP mode
- [ ] Merge `go.mod` dependencies (bubbletea + lipgloss + mcp-go + sqlite)
- [ ] Merge and deduplicate test utilities
- [ ] Verify all existing tests pass under new module structure
- [ ] Update Makefile: replace `build-tui` + `build-mcp` with `build-steno`

**Success criteria:** `make build` produces `steno` (Go) + `steno-daemon` (Swift). `make test` passes all suites. `steno` runs the TUI. `steno --mcp` runs the MCP server. No behavioral changes yet.

#### Phase 2: Daemon Lifecycle Manager

Add daemon auto-start to the TUI mode.

**Tasks:**
- [ ] Define `DaemonManager` interface for testability:
  ```go
  type DaemonManager interface {
      IsRunning() (bool, int, error)  // running, pid, error
      Start() error                    // spawn detached daemon
      WaitForSocket(ctx context.Context) error  // poll until ready
      FindBinary() (string, error)     // locate steno-daemon
  }
  ```
- [ ] Implement `ProcessDaemonManager` (real implementation)
- [ ] Implement `MockDaemonManager` for tests
- [ ] PID file checking: read `~/Library/Application Support/Steno/steno.pid`, verify with `kill(pid, 0)`
- [ ] Stale PID cleanup: if PID not alive, remove PID file and stale socket file
- [ ] Daemon spawning: `exec.Command` with `Setsid: true`, stdout/stderr to daemon.log
- [ ] Socket readiness: poll `steno.sock` existence + test connect, 100ms interval, 30s timeout
- [ ] Child process monitoring: goroutine that waits on the child and signals early exit
- [ ] Wire into TUI startup: check → start if needed → wait → connect → show TUI
- [ ] Error UX: if daemon binary not found, show "steno-daemon not found. Run: make install"
- [ ] Error UX: if daemon fails to start, show last lines of daemon.log
- [ ] Tests: daemon manager with mocks, startup sequences, failure scenarios

**Success criteria:** Running `steno` when no daemon is running auto-starts it. Running `steno` when daemon is already running connects to it. Daemon survives TUI exit.

#### Phase 3: Polish and Cleanup

- [ ] Update `make install` to install `steno` + `steno-daemon` (two binaries)
- [ ] `make install` removes stale `steno-tui` and `steno-mcp` from install prefix
- [ ] Add `STENO_DAEMON_PATH` env var support for development
- [ ] Add `STENO_DB` env var support in unified binary (already in MCP, ensure TUI mode also respects it)
- [ ] Delete `tui/` directory (old module)
- [ ] Delete `mcp/` directory (old module)
- [ ] Update CLAUDE.md repository structure section
- [ ] Update README.md install/usage instructions
- [ ] Update MCP server config documentation (binary name change: `steno-mcp` → `steno --mcp`)

**Success criteria:** Clean two-binary install. Old Go directories removed. Documentation current.

## System-Wide Impact

### Interaction Graph

- `steno` (Go) spawns `steno-daemon` (Swift) as detached subprocess → daemon creates SQLite DB + binds Unix socket → `steno` connects to socket + opens DB read-only → bubbletea renders TUI from socket events + DB queries
- `steno --mcp` opens SQLite DB read-only → serves MCP tools over stdio → MCP client (Claude Desktop, etc.) calls tools

### Error Propagation

- Daemon spawn failure → Go checks child exit code → reads daemon.log → surfaces error in TUI status bar
- Socket disconnect (daemon crash) → bubbletea receives `DaemonDisconnectedMsg` → enters reconnect loop with exponential backoff (1s→2s→4s→8s→16s cap) → shows "Reconnecting..." status
- DB open failure → TUI degrades gracefully (no topics panel, no historical data) → transcript still works via socket events
- MCP DB open failure → tool returns error → MCP client shows error

### State Lifecycle Risks

- **PID file stale after crash**: Mitigated by `kill(pid, 0)` liveness check before trusting PID file
- **Socket file stale after crash**: Mitigated by removing socket file when PID file is stale. Daemon's `UnixSocketServer` should also unlink before bind.
- **Two TUI instances racing to start daemon**: Second instance's `Start()` will fail (PID file already held), falls through to connect-only path — this is correct behavior

### API Surface Parity

- MCP tools: unchanged (same 5 tools, same parameters, same responses)
- MCP server name: stays `"steno-mcp"` for backward compatibility
- Daemon protocol: unchanged (same NDJSON commands/events)
- Binary name change: `steno-mcp` → `steno --mcp` (breaking for MCP client configs)

## Acceptance Criteria

### Functional Requirements

- [ ] `steno` with no daemon running: starts daemon, waits for socket, connects, shows TUI
- [ ] `steno` with daemon already running: connects, shows TUI (no second daemon)
- [ ] `steno --mcp`: runs MCP stdio server, all 5 tools work, no daemon management
- [ ] `steno --mcp` with no database: exits with clear error message
- [ ] TUI Ctrl+C: TUI exits, daemon keeps running
- [ ] Daemon crash during TUI: shows error, reconnects with backoff
- [ ] Two TUI instances: both connect successfully, no errors
- [ ] `make build`: produces `steno` (Go) + `steno-daemon` (Swift)
- [ ] `make test`: all test suites pass
- [ ] `make install`: installs both binaries, removes stale old binaries

### Non-Functional Requirements

- [ ] Daemon startup detection < 5 seconds in normal case
- [ ] No duplicate db code between TUI and MCP modes
- [ ] DaemonManager interface is fully mockable for tests
- [ ] Daemon detaches properly — survives terminal close, TUI exit, SIGHUP

### Testing Requirements

- [ ] Unit tests for `DaemonManager`: PID file parsing, stale detection, binary lookup
- [ ] Unit tests for startup sequence: daemon already running, daemon not running, daemon fails to start
- [ ] Existing TUI model tests pass unchanged
- [ ] Existing MCP tool tests pass under new module structure
- [ ] Existing daemon client/protocol tests pass
- [ ] Merged db store tests cover all queries from both TUI and MCP
- [ ] Integration test: full startup sequence (requires daemon binary)

## Dependencies & Risks

**Dependencies:**
- Swift daemon stays unchanged — no coordination needed
- MCP client configs (Claude Desktop, etc.) need updating: `steno-mcp` → `steno --mcp`

**Risks:**
- **Module merge may surface dependency conflicts** — both modules pin same sqlite version (v1.44.3), bubbletea and mcp-go should not conflict. Low risk.
- **Detached process spawning on macOS** — `Setsid` works on Darwin but needs testing. The daemon already runs this way via launchd.
- **Binary discovery in different install contexts** — Homebrew, manual install, dev environment all put binaries in different places. The three-tier lookup (co-located → env var → PATH) handles this.

## Future Considerations

- **`steno status` subcommand**: Check daemon health without starting TUI
- **`steno doctor` subcommand**: Diagnose permissions, entitlements, binary signing
- **Homebrew formula**: `brew install steno` that installs both binaries
- **First-run onboarding**: TUI splash screen guiding through TCC permission dialogs
- **Version compatibility check**: Go binary verifies daemon protocol version on connect

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-02-07-three-component-architecture-brainstorm.md](docs/brainstorms/2026-02-07-three-component-architecture-brainstorm.md) — established the three-component architecture, left distribution packaging as an open question

### Internal References

- TUI entry point: `tui/main.go`
- MCP entry point: `mcp/main.go`
- TUI db package: `tui/internal/db/store.go`
- MCP db package (superset): `mcp/internal/db/store.go`
- Daemon PID file: `daemon/Sources/StenoDaemon/Infrastructure/PIDFile.swift`
- Daemon signal handler: `daemon/Sources/StenoDaemon/Infrastructure/SignalHandler.swift`
- Daemon socket server: `daemon/Sources/StenoDaemon/Socket/UnixSocketServer.swift`
- Daemon run command: `daemon/Sources/StenoDaemon/Commands/RunCommand.swift`
- Daemon install/launchd: `daemon/Sources/StenoDaemon/Commands/InstallCommand.swift`
- Makefile: `Makefile`
