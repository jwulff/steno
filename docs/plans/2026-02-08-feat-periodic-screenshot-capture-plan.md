---
title: "feat: Periodic Screenshot Capture with LLM Analysis"
type: feat
date: 2026-02-08
brainstorm: docs/brainstorms/2026-02-08-periodic-screenshot-capture-brainstorm.md
---

# Periodic Screenshot Capture with LLM Analysis

## Overview

Add periodic full-screen screenshot capture to the daemon during recording. Every 30 seconds, the daemon captures a screenshot via `SCScreenshotManager`, sends it to a vision LLM for description, stores the JPEG on disk, persists metadata to SQLite, and streams a `"screenshot"` event to subscribed TUI clients. Screenshot descriptions enrich topic extraction alongside transcript segments. The TUI displays `[SCREEN]` markers in the transcript timeline with expandable descriptions.

## Problem Statement

Steno captures what people *say* but not what they *see*. During meetings, the most important context is often on screen — slides, documents, code reviews, websites being demoed. Adding periodic screenshots with LLM-generated descriptions makes meeting notes, topic extraction, and searchable history dramatically richer.

## Proposed Solution

### Architecture

```
RecordingEngine
├── MicRecognizer (existing)
├── SystemAudioSource (existing)
├── RollingSummaryCoordinator (existing)
└── ScreenshotCoordinator (NEW)
    ├── ScreenCaptureService → SCScreenshotManager → CGImage
    ├── ScreenDescriptionService → Vision LLM → ScreenDescription
    └── TranscriptRepository → SQLite screenshots table + JPEG on disk
```

### Data Flow (per 30s interval)

1. Timer fires in `ScreenshotCoordinator`
2. `ScreenCaptureService.capture(excluding:)` → `CGImage` via `SCScreenshotManager`
3. Resize to 50% retina resolution
4. `ScreenDescriptionService.describe(image:)` → `ScreenDescription` (structured + narrative)
5. Store JPEG to `~/Library/Application Support/Steno/screenshots/{sessionId}/{timestamp}.jpg`
6. Persist metadata to `screenshots` SQLite table
7. Emit `.screenshotCaptured(ScreenshotRecord)` via delegate → `"screenshot"` NDJSON event
8. Pass description to `RollingSummaryCoordinator` for topic enrichment

### Key Decision: SCScreenshotManager (macOS 14+)

- Same Screen Recording TCC permission as existing `SCStream` audio capture — zero additional prompts
- Returns `CGImage` directly — no `CMSampleBuffer` conversion
- `SCContentFilter` for app exclusion — same API used by `SCStream`
- Independent from audio `SCStream` — no coupling between screenshot and audio capture
- No macOS 15+ Sequoia nag dialogs (unlike deprecated `CGWindowListCreateImage`)

## Technical Approach

### New Files

#### Daemon (Swift)

| File | Purpose |
|---|---|
| `daemon/Sources/StenoDaemon/Screenshots/ScreenCaptureService.swift` | Protocol: `capture(excluding:) async throws -> CGImage` |
| `daemon/Sources/StenoDaemon/Screenshots/SCScreenshotCaptureService.swift` | Implementation using `SCScreenshotManager` + `SCContentFilter` |
| `daemon/Sources/StenoDaemon/Screenshots/ScreenDescriptionService.swift` | Protocol: `describe(image:) async throws -> ScreenDescription` |
| `daemon/Sources/StenoDaemon/Screenshots/FoundationModelScreenDescriptionService.swift` | Apple Intelligence backend |
| `daemon/Sources/StenoDaemon/Screenshots/AnthropicScreenDescriptionService.swift` | Anthropic Claude vision backend |
| `daemon/Sources/StenoDaemon/Screenshots/ScreenshotCoordinator.swift` | Actor: timer + orchestration |
| `daemon/Sources/StenoDaemon/Screenshots/ScreenDescription.swift` | Model: structured + narrative description |
| `daemon/Sources/StenoDaemon/Screenshots/ScreenshotRecord.swift` | Model: persisted screenshot metadata |
| `daemon/Tests/StenoDaemonTests/Screenshots/ScreenCaptureServiceTests.swift` | Mock-based tests |
| `daemon/Tests/StenoDaemonTests/Screenshots/ScreenDescriptionServiceTests.swift` | Mock-based tests |
| `daemon/Tests/StenoDaemonTests/Screenshots/ScreenshotCoordinatorTests.swift` | Timer + orchestration tests |
| `daemon/Tests/StenoDaemonTests/Mocks/MockScreenCaptureService.swift` | Test mock |
| `daemon/Tests/StenoDaemonTests/Mocks/MockScreenDescriptionService.swift` | Test mock |

#### TUI (Go)

| File | Purpose |
|---|---|
| `tui/internal/db/screenshots.go` | `ScreenshotsForSession()` query |

#### Schema

| File | Purpose |
|---|---|
| `schema/README.md` | Add `screenshots` table documentation |

### Modified Files

#### Daemon (Swift)

| File | Change |
|---|---|
| `Engine/RecordingEngineDelegate.swift` | Add `EngineEvent.screenshotCaptured(ScreenshotRecord)` case |
| `Engine/RecordingEngine.swift` | Add `screenshotCoordinator` dependency, start/stop with recording |
| `Dispatch/EventBroadcaster.swift` | Add `EventType.screenshot` + mapping for new event |
| `Socket/DaemonProtocol.swift` | Add screenshot fields to `DaemonEvent` |
| `Storage/DatabaseConfiguration.swift` | Add migration `20260209_001_create_screenshots_table` |
| `Storage/SQLiteTranscriptRepository.swift` | Add `saveScreenshot()`, `screenshotsForSession()` |
| `Storage/TranscriptRepository.swift` | Add screenshot methods to protocol |
| `Commands/RunCommand.swift` | Wire `ScreenshotCoordinator` into service graph |
| `Models/StenoSettings.swift` | Add `screenshotEnabled`, `screenshotExcludedApps`, `screenshotProvider` |
| `Services/RollingSummaryCoordinator.swift` | Accept screenshot descriptions for topic enrichment |

#### TUI (Go)

| File | Change |
|---|---|
| `internal/daemon/protocol.go` | Add screenshot fields to `Event` struct |
| `internal/app/model.go` | Handle `"screenshot"` events, add `[SCREEN]` entries |
| `internal/app/messages.go` | Add `ScreenshotMsg` type |
| `internal/db/models.go` | Add `Screenshot` struct |
| `internal/db/store.go` | Add `ScreenshotsForSession()` query |
| `internal/ui/styles.go` | Add `ScreenLabelStyle` (magenta) |

### SQLite Schema Addition

```sql
-- Migration: 20260209_001_create_screenshots_table
CREATE TABLE screenshots (
    id TEXT PRIMARY KEY,
    sessionId TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    capturedAt REAL NOT NULL,
    filePath TEXT NOT NULL,
    description TEXT,
    appName TEXT,
    documentTitle TEXT,
    modelId TEXT,
    captureDurationMs INTEGER,
    createdAt REAL NOT NULL
);

CREATE INDEX idx_screenshots_session ON screenshots(sessionId);
CREATE INDEX idx_screenshots_time ON screenshots(capturedAt);
```

### Protocol Addition

New NDJSON event:

```json
{"event":"screenshot","sessionId":"...","text":"Chrome showing GitHub PR review for steno/pull/14","source":"screen","title":"GitHub - Pull Request Review"}
```

Fields on `DaemonEvent`:
- `event: "screenshot"`
- `sessionId`: session UUID
- `text`: narrative description (2-3 sentences)
- `source`: `"screen"` (constant)
- `title`: app name + document title

### Settings Addition

```json
{
  "screenshotEnabled": true,
  "screenshotProvider": "local",
  "screenshotExcludedApps": [
    "com.1password.1password",
    "com.apple.keychainaccess",
    "com.apple.MobileSMS"
  ]
}
```

## Implementation Phases

### Phase 1: Capture Infrastructure + SQLite

**Goal:** Screenshot capture loop running, JPEGs stored on disk, metadata in SQLite. No LLM yet.

**Tests first:**
- `ScreenCaptureServiceTests` — mock returns CGImage, verify coordinator calls capture
- `ScreenshotCoordinatorTests` — timer fires, capture called, JPEG written, metadata persisted
- `DatabaseConfiguration` migration test — screenshots table created with correct schema
- `TranscriptRepository` screenshot persistence tests

**Implementation:**
- `ScreenCaptureService` protocol + `SCScreenshotCaptureService`
- `ScreenshotRecord` model (mirrors SQLite row)
- SQLite migration `20260209_001_create_screenshots_table`
- Repository methods: `saveScreenshot()`, `screenshotsForSession()`
- `ScreenshotCoordinator` actor with 30s timer, capture → resize → save JPEG → persist
- Wire into `RecordingEngine` (start/stop with recording)
- JPEG storage at `~/Library/Application Support/Steno/screenshots/{sessionId}/{timestamp}.jpg`
- Image resize: 50% of retina resolution via `CGContext` draw + scale

**Verify:** `cd daemon && swift build && swift test`

**Estimated scope:** ~8 files new, ~4 files modified

---

### Phase 2: Apple Intelligence Vision Backend

**Goal:** On-device LLM describes each screenshot. Descriptions stored in SQLite.

**Tests first:**
- `ScreenDescriptionServiceTests` — mock returns structured description, verify coordinator stores it
- `FoundationModelScreenDescriptionServiceTests` — verify prompt construction, response parsing

**Implementation:**
- `ScreenDescription` model: `appName: String?`, `documentTitle: String?`, `narrative: String`
- `ScreenDescriptionService` protocol: `describe(image: CGImage) async throws -> ScreenDescription`
- `FoundationModelScreenDescriptionService` — Apple Intelligence Foundation Models with image input (macOS 26)
- Vision prompt: system prompt requesting structured fields + narrative
- Update `ScreenshotCoordinator`: capture → resize → describe → save JPEG → persist (description included)
- Re-entrance guard: skip capture if previous description still in progress

**Verify:** `cd daemon && swift build && swift test`

**Estimated scope:** ~4 files new, ~2 files modified

---

### Phase 3: Anthropic Claude Vision Backend

**Goal:** Cloud-based vision descriptions via Anthropic API.

**Tests first:**
- `AnthropicScreenDescriptionServiceTests` — mock HTTP client, verify request format, response parsing

**Implementation:**
- `AnthropicScreenDescriptionService` — sends base64 JPEG to Claude's vision endpoint
- Uses existing `effectiveAnthropicAPIKey` from settings
- Add `screenshotProvider` to `StenoSettings` (reuses existing `SummarizationProvider` enum)
- Wire provider selection in `RunCommand` based on settings

**Verify:** `cd daemon && swift build && swift test`

**Estimated scope:** ~2 files new, ~2 files modified

---

### Phase 4: Event Streaming + TUI Display

**Goal:** Screenshot events streamed to TUI. `[SCREEN]` markers in transcript timeline.

**Tests first:**
- `EventBroadcaster` screenshot mapping test
- Go: `protocol_test.go` — JSON round-trip for screenshot event
- Go: model test — screenshot event creates `[SCREEN]` entry

**Implementation (Daemon):**
- Add `EngineEvent.screenshotCaptured(ScreenshotRecord)` to enum
- Add `EventType.screenshot` to broadcaster
- Map to `DaemonEvent(event: "screenshot", text: description, source: "screen", title: appName)`
- `ScreenshotCoordinator` emits event via delegate after persist

**Implementation (TUI):**
- Add `Description` and `AppName` fields to Go `Event` struct
- Handle `"screenshot"` in `model.handleEvent()` — append `TranscriptEntry` with `Source: "screen"`
- Render `[SCREEN]` label in magenta (new `ScreenLabelStyle`)
- Show narrative description as entry text, app name in title position

**Verify:** `cd daemon && swift build && swift test` + `cd tui && go build && go test ./...`

**Estimated scope:** ~3 files modified (daemon), ~5 files modified (TUI)

---

### Phase 5: Topic Enrichment

**Goal:** Screenshot descriptions fed into topic extraction for richer context.

**Tests first:**
- `RollingSummaryCoordinator` test — screenshot descriptions included in summarization input

**Implementation:**
- `RollingSummaryCoordinator.addScreenshotDescription(_ description: String, at: Date)`
- Modify `SummarizationService.extractTopics()` to accept optional screenshot context
- Update topic extraction prompt: "What was said" + "What was on screen" sections
- `ScreenshotCoordinator` calls `summaryCoordinator.addScreenshotDescription()` after each description

**Verify:** `cd daemon && swift build && swift test`

**Estimated scope:** ~3 files modified

---

### Phase 6: App Exclusion + Settings

**Goal:** Privacy blocklist for sensitive apps. User configures via settings.

**Tests first:**
- `SCScreenshotCaptureService` exclusion test — verify `SCContentFilter` excludes specified apps
- Settings round-trip test — `screenshotExcludedApps` persists and loads

**Implementation:**
- Add `screenshotEnabled: Bool` and `screenshotExcludedApps: [String]` to `StenoSettings`
- Default blocklist: `com.1password.1password`, `com.apple.keychainaccess`, `com.apple.MobileSMS`
- `SCScreenshotCaptureService.capture(excluding:)` — uses `SCContentFilter` to exclude apps
- `ScreenshotCoordinator` checks `screenshotEnabled` before starting timer
- `ScreenshotCoordinator` passes excluded apps to capture service on each interval

**Verify:** `cd daemon && swift build && swift test`

**Estimated scope:** ~2 files modified

## Acceptance Criteria

### Functional Requirements

- [ ] Screenshots captured every 30 seconds while recording
- [ ] JPEGs stored at `~/Library/Application Support/Steno/screenshots/{sessionId}/{timestamp}.jpg`
- [ ] Screenshots table in SQLite with metadata (timestamp, path, description, model, duration)
- [ ] Vision LLM describes each screenshot with structured fields (app name, doc title) + narrative
- [ ] Apple Intelligence (on-device) backend works for screenshot descriptions
- [ ] Anthropic Claude (cloud) backend works for screenshot descriptions
- [ ] User can configure provider in settings (same pattern as summarization)
- [ ] `"screenshot"` NDJSON events streamed to subscribed TUI clients
- [ ] TUI displays `[SCREEN]` markers in transcript timeline with description text
- [ ] Screenshot descriptions feed into topic extraction for enriched topics
- [ ] App exclusion blocklist prevents capturing sensitive apps (1Password, Keychain, Messages)
- [ ] No capture when all visible windows are blocklisted
- [ ] Screenshot capture uses same Screen Recording TCC permission as system audio (no new prompts)
- [ ] Captures all connected displays as one stitched image
- [ ] Images resized to 50% retina before storage and LLM analysis

### Non-Functional Requirements

- [ ] Screenshot capture/describe runs in its own concurrency slot (independent of summarization)
- [ ] Re-entrance guard: skip capture if previous LLM description still in progress
- [ ] No crash or hang if vision LLM is unavailable
- [ ] 50% retina resolution yields ~500KB-2MB per JPEG
- [ ] Storage: ~120-240MB/hour at 30s intervals (acceptable)

### Quality Gates

- [ ] All new code has tests (protocol mocks, coordinator logic, migration, event mapping)
- [ ] `swift test` passes with all new tests
- [ ] `go test ./...` passes with TUI changes
- [ ] Schema documented in `schema/README.md`

## Dependencies & Prerequisites

- macOS 14+ for `SCScreenshotManager` API
- macOS 26 for Apple Intelligence Foundation Models with image input
- Existing Screen Recording TCC permission (already granted for system audio)
- Anthropic API key (for Claude vision backend, optional)

## Open Questions

1. **Capture while screen locked** — Should we skip capture when screen is locked/sleeping? Probably yes. Implementation: check `CGSessionCopyCurrentDictionary()` for `kCGSessionOnConsoleKey`.
2. **Exact LLM prompt wording** — Draft during Phase 2 implementation. Should request: active app name, document/page title, visible headings, 2-3 sentence narrative.
3. **Screenshots without system audio** — If user hasn't enabled system audio, they may not have Screen Recording permission yet. First screenshot capture triggers TCC dialog. Should screenshots be opt-in toggle or automatic?

## Future Considerations (not v1)

- **pHash deduplication** — Perceptual hash comparison between consecutive screenshots. Skip storing + describing if hamming distance below threshold. Saves storage and LLM calls for static screens.
- **OCR layer** — Extract text from screenshots for full-text search without LLM.
- **Screenshot browser** — TUI or web UI to browse captured screenshots with descriptions.
- **Session deletion cascade** — When session deletion is implemented, cascade-delete the session's screenshot directory.

## References

### Internal

- Brainstorm: `docs/brainstorms/2026-02-08-periodic-screenshot-capture-brainstorm.md`
- RecordingEngine pattern: `daemon/Sources/StenoDaemon/Engine/RecordingEngine.swift`
- RollingSummaryCoordinator (closest analog): `daemon/Sources/StenoDaemon/Services/RollingSummaryCoordinator.swift`
- SummarizationService protocol pattern: `daemon/Sources/StenoDaemon/Services/SummarizationService.swift`
- Existing ScreenCaptureKit usage: `daemon/Sources/StenoDaemon/Audio/SystemAudioSource.swift`
- GRDB migrations: `daemon/Sources/StenoDaemon/Storage/DatabaseConfiguration.swift`
- Event system: `daemon/Sources/StenoDaemon/Dispatch/EventBroadcaster.swift`
- Service wiring: `daemon/Sources/StenoDaemon/Commands/RunCommand.swift`
- Settings: `daemon/Sources/StenoDaemon/Models/StenoSettings.swift`
- Schema contract: `schema/README.md`
- Go protocol types: `tui/internal/daemon/protocol.go`
- Go event handling: `tui/internal/app/model.go`

### External

- [SCScreenshotManager API](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager) — macOS 14+
- [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter) — App/window exclusion
- [Foundation Models framework](https://developer.apple.com/documentation/foundationmodels) — On-device LLM (macOS 26)
- [Anthropic Vision API](https://docs.anthropic.com/en/docs/build-with-claude/vision) — Cloud vision analysis
