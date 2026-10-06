# Brainstorm: Three-Component Architecture

**Date:** 2026-02-07
**Status:** Decided

## What We're Building

Splitting Steno from a monolithic TUI app into three independent components that communicate through a shared SQLite database:

1. **`steno-daemon`** (Swift) — Headless recorder, transcriber, and analyzer
2. **`steno`** (Go) — TUI client for viewing/controlling transcription
3. **`steno-mcp`** (TypeScript) — MCP server for AI-powered transcript queries

## Why This Architecture

**The three components have genuinely different requirements:**

- The daemon needs macOS-specific APIs (SpeechAnalyzer, ScreenCaptureKit, Foundation Models) — must be Swift
- The TUI needs fast startup, snappy rendering, and a great terminal library ecosystem — Go with bubbletea
- The MCP server needs the most mature MCP SDK and easy path to RAG — TypeScript

**Direct SQLite access (WAL mode) is the glue.** The daemon writes, clients read. No complex IPC protocol for data queries. Simple, debuggable, battle-tested.

## Key Decisions

### 1. Three separate binaries, best language per job
- **Swift daemon**: Owns audio capture, SpeechAnalyzer, segment persistence, LLM summarization
- **Go TUI**: Reads SQLite directly, sends control commands to daemon via Unix socket
- **TypeScript MCP**: Reads SQLite directly, stdio transport, query tools

### 2. Direct SQLite for data, Unix socket for control
- **Data flow**: All components read `~/.local/share/Steno/steno.sqlite` (WAL mode enables concurrent readers)
- **Control flow**: TUI sends commands to daemon via Unix domain socket at `~/.local/share/Steno/steno.sock`
- No heavyweight IPC (gRPC, REST) — the DB is the shared state

### 3. Daemon lifecycle: launchd + on-demand
- Install as a launchd agent for always-on recording at login
- TUI can also start daemon on-demand if it's not running
- Daemon survives TUI disconnects — recording persists across terminal sessions

### 4. Monorepo structure
```
steno/
├── daemon/          # Swift Package (steno-daemon binary)
│   ├── Package.swift
│   └── Sources/
├── tui/             # Go module (steno binary)
│   ├── go.mod
│   └── main.go
├── mcp/             # TypeScript/Node (steno-mcp binary)
│   ├── package.json
│   └── src/
├── schema/          # Shared DB schema docs, migration SQL
├── docs/
└── README.md
```

### 5. MCP query tools (ship all three together, RAG later)
- `search_transcripts(query, time_range?)` — full-text keyword search
- `get_topics(session_id?, time_range?)` — topic-based queries
- `get_transcript(session_id?, time_range?)` — time-based retrieval
- RAG with vector embeddings as a future enhancement

### 6. Schema is the contract
- DB schema documented in `schema/` directory
- Migration versioning stays in the Swift daemon (it owns writes)
- Go and TypeScript components use read-only access with documented table schemas
- Schema changes require updating all three components

### 7. Two data planes: SQLite for persistence, socket for ephemeral state

The daemon has two kinds of data:

**Persisted (SQLite)** — segments, sessions, summaries, topics. Available to all clients (TUI, MCP) via direct DB reads. Survives restarts.

**Ephemeral (socket only)** — lives only in the daemon process, never written to DB:
- **Partial transcription text** — in-progress speech before it's finalized into a segment
- **Audio levels** — mic and system audio VU meters (updated ~20-60Hz)
- **Recording status** — is it actively recording, which device, system audio on/off
- **Model processing indicator** — is the LLM currently generating a summary/topics
- **Errors/warnings** — transient issues (mic disconnect, permission prompt, guardrail violation)

The TUI needs both planes. The MCP server only needs SQLite (no live UI state).

**Data flow:**
- TUI connects to socket for ephemeral state + control commands
- TUI reads SQLite for persisted transcript history, topics, summaries
- MCP reads SQLite only

### 8. Daemon control protocol: NDJSON over Unix socket

Socket: `~/.local/share/Steno/steno.sock`
Format: Newline-delimited JSON (one JSON object per line)

**Commands (request → response):**
```
→ {"cmd":"start","locale":"en_US","device":"MacBook Air Microphone","systemAudio":true}
← {"ok":true,"sessionId":"abc-123"}

→ {"cmd":"stop"}
← {"ok":true}

→ {"cmd":"status"}
← {"recording":true,"sessionId":"abc-123","segments":42,"device":"MacBook Air Microphone","systemAudio":true,"modelProcessing":false}

→ {"cmd":"devices"}
← {"ok":true,"devices":["MacBook Air Microphone","External Mic"]}

→ {"cmd":"set-device","device":"External Mic"}
← {"ok":true}
```

**Subscribe (opt-in push events for ephemeral state):**

Clients subscribe to event channels. Ephemeral data only flows to subscribed clients.

```
→ {"cmd":"subscribe","events":["partial","level","segment","topic","status"]}
← {"ok":true}

# Ephemeral — not in DB, only available via socket
← {"event":"partial","text":"So the guys under","source":"mic"}
← {"event":"partial","text":"So the guys understand the importance of","source":"mic"}
← {"event":"level","mic":0.42,"sys":0.18}
← {"event":"level","mic":0.31,"sys":0.22}
← {"event":"status","modelProcessing":true}
← {"event":"status","modelProcessing":false}
← {"event":"error","message":"Guardrail violation in summary generation","transient":true}

# Persisted — also in DB, but pushed for instant TUI updates
← {"event":"segment","sessionId":"abc-123","sequenceNumber":43,"text":"So the guys understand the importance of it.","source":"mic"}
← {"event":"topic","sessionId":"abc-123","title":"Team Dynamics and Pride"}
```

**Level update frequency**: Daemon throttles level events to ~10Hz max (every 100ms) to avoid flooding the socket. TUI renders at its own refresh rate.

### 9. Migration path: clean-room parallel, daemon first
- Build `steno-daemon` first as the foundation (clean-room, not incremental extraction)
- Current monolith continues working during development
- MCP server can be built against existing DB schema in parallel once daemon is stable
- Go TUI built last (current Swift TUI works until then)
- Cut over when all three components are ready

## Open Questions

- **MCP resources vs tools**: Should sessions/topics be exposed as MCP resources (for browsing) in addition to tools (for querying)?
- **Packaging**: Single `brew install steno` that installs all three? Or separate packages?
- **Vector storage**: When RAG comes, store embeddings in SQLite (sqlite-vec extension) or a separate vector DB?
- **Multi-session**: Can the daemon record multiple sessions simultaneously (e.g., mic session + system audio session)?

## Approach Alternatives Considered

**Approach B (All Swift)**: Single binary with subcommands. Rejected because SwiftTUI is limited, Swift MCP SDK is immature, and a single large binary is wasteful for MCP server that only needs DB reads.

**Approach C (Swift + TypeScript)**: TypeScript for both TUI and MCP. Rejected because Node.js TUI performance isn't as snappy and Go/bubbletea is a significantly better fit for terminal apps.
