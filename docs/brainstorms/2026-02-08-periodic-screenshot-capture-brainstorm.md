# Periodic Screenshot Capture for LLM Analysis

**Date:** 2026-02-08
**Status:** Brainstorm complete, ready for planning

## What We're Building

The daemon captures a full-screen screenshot every 30 seconds while recording. Each screenshot is sent to a vision LLM (user-configurable: Apple Intelligence on-device or Anthropic Claude) which generates a text description of what's on screen. The description is stored alongside the image. Screenshot descriptions are fed into topic extraction alongside transcript segments, making topics aware of both audio and visual context. The TUI shows `[SCREEN]` markers in the transcript timeline and can display screenshot descriptions on demand.

## Why This Approach

### Goal: Full context capture

Steno already captures what people *say*. Adding periodic screenshots captures what people *see* — slides being presented, documents being discussed, code being reviewed, websites being demoed. This makes meeting notes, topic extraction, and searchable history dramatically richer.

### SCScreenshotManager (not CGWindowListCreateImage, not SCStream video)

We chose `SCScreenshotManager` (macOS 14+) for periodic stills:

- **Modern API** — Apple's explicit replacement for the deprecated `CGWindowListCreateImage`
- **Same TCC permission as SCStream** — Users who enabled system audio capture already have Screen Recording permission granted. Zero additional prompts.
- **Returns CGImage directly** — No CMSampleBuffer conversion needed
- **SCContentFilter for app exclusion** — Same filtering API used by SCStream, consistent and well-supported
- **Independence** — Separate from the audio SCStream; no coupling between screenshot and audio capture
- **No Sequoia nag** — `CGWindowListCreateImage` triggers extra consent alerts on macOS 15+; SCScreenshotManager does not

### Daemon-side LLM description

The daemon describes each screenshot at capture time rather than storing raw images for later analysis because:

- Descriptions are immediately available for topic extraction enrichment
- Text descriptions are cheap to store and query
- The TUI (and future clients) get structured text without needing vision LLM access
- Raw JPEGs are still stored on disk for future deeper analysis if needed

## Key Decisions

### 1. Capture frequency: 30 seconds

High fidelity — catches slide transitions and screen changes. ~120 images/hour at ~500KB each = ~60MB/hour. Acceptable for modern storage.

**Future enhancement (noted, not v1):** Perceptual hash (pHash) deduplication to avoid storing near-identical consecutive screenshots. Skip storing + describing if hamming distance is below threshold.

### 2. Storage: JPEG on disk + metadata in SQLite

Images stored as JPEGs in `~/Library/Application Support/Steno/screenshots/{sessionId}/{timestamp}.jpg`. SQLite `screenshots` table stores metadata: timestamp, session ID, file path, LLM description, model used, capture duration.

**Why not blobs in SQLite?** Images are ~500KB each. Storing in SQLite would bloat the database, slow WAL checkpoints, and make the TUI's read-only SQLite access slower. Filesystem storage keeps the DB lean.

### 3. Privacy: App exclusion list

Users configure a blocklist of app bundle IDs (e.g., `com.1password.1password`, `com.apple.MobileSMS`). Before capturing, the daemon calls `CGWindowListCopyWindowInfo` to get visible windows, filters out blocklisted apps, and captures only the remaining windows. If ALL visible windows are blocklisted, skip that capture entirely.

**Default blocklist (suggested):** 1Password, Keychain Access, Messages (can be overridden in settings).

### 4. Vision LLM: User-configurable

Follows the existing pattern for summarization — user selects the AI model in settings. Options:

- **Apple Intelligence (Foundation Models)** — On-device, free, private. Uses the same framework as existing summarization. Image input support available on macOS 26.
- **Anthropic Claude** — Best vision quality. Requires API key. Sends screenshots to the cloud.

The `ScreenDescriptionService` protocol mirrors `SummarizationService` — implementations for both backends, injected at startup.

### 5. TUI integration: Three layers

1. **Transcript markers** — `[SCREEN]` entries in the transcript timeline at screenshot timestamps, styled distinctively. Expanding shows the description text.
2. **Topic enrichment** — Screenshot descriptions are passed to `RollingSummaryCoordinator` alongside transcript segments. The LLM prompt includes both "what was said" and "what was on screen" for richer topics.
3. **Event streaming** — New `"screenshot"` event type broadcast to TUI clients with description text, timestamp, and session ID.

### 6. Daemon architecture

New components:
- `ScreenCaptureService` protocol — `capture(excluding: [String]) async throws -> CGImage` (uses SCScreenshotManager + SCContentFilter for app exclusion)
- `ScreenDescriptionService` protocol — `describe(image: CGImage) async throws -> ScreenDescription` (structured + narrative output)
- `ScreenshotCoordinator` actor — Timer-driven (30s), orchestrates capture → resize → describe → store JPEG → persist metadata → emit event
- `screenshots` SQLite table — `id`, `sessionId`, `capturedAt`, `filePath`, `description`, `appName`, `documentTitle`, `modelId`, `captureDurationMs`

Wired into `RecordingEngine` like `RollingSummaryCoordinator` — started/stopped with recording, emits events via delegate. Runs its own concurrency slot for LLM calls (independent of summarization).

## Resolved Questions

### Resolution: 50% retina

Downscale captured image to 50% of retina resolution. This yields ~1-2MB per JPEG — enough detail for LLMs to read text and identify UI elements, while keeping storage reasonable (~120-240MB/hour at 30s intervals). Single resolution for both storage and LLM analysis (no dual-resolution complexity).

### Multi-display: Single stitched image across all displays

`CGWindowListCreateImage` with `kCGWindowListOptionAll` captures all connected displays into one image. One image per interval, one LLM call. The image may be wide (e.g. 5120x1440 for dual monitors) but vision LLMs handle this fine. Adapts automatically to whatever displays are connected — no configuration needed.

### LLM prompt design: Hybrid structured + narrative

The vision LLM returns both structured metadata and a natural description:

- **Structured fields:** Active application name, document/page title, visible headings
- **Narrative:** 2-3 sentence description of the content and activity on screen

This gives topic extraction structured data to correlate with (app name, doc title) AND natural language that blends well with transcript segments in the topic extraction prompt.

### Rate limiting: Separate concurrency budget

Screenshot descriptions run in their own concurrency slot, independent of the summarization pipeline. Both can run in parallel without blocking each other. For Anthropic, track API usage and warn the user if approaching rate limits. For Apple Intelligence (on-device), concurrency is essentially free.

### TCC Permissions: Already handled

`SCScreenshotManager` uses the same Screen Recording TCC permission as `SCStream`. Since the daemon already requests this for system audio capture via `SCShareableContent.current`, no additional permission flow is needed. If a user hasn't enabled system audio, the first screenshot capture will trigger the standard Screen Recording permission dialog (same one system audio would trigger).

The existing `PermissionService` protocol should be extended to check for screen recording permission via `SCShareableContent.current` (which implicitly triggers the TCC dialog if not yet granted).

## Open Questions

1. **Capture while screen is locked** — Should we skip capture when the screen is locked/sleeping? Probably yes — no useful content.
2. **Exact LLM prompt wording** — Draft the actual system prompt for vision analysis during implementation. Consider providing example output format.
3. **Screenshots without system audio** — If the user hasn't enabled system audio, they may not have Screen Recording permission yet. The first screenshot capture should trigger the TCC dialog. Should screenshots be opt-in (explicit toggle) or automatic during recording?

### Resolved: Cleanup policy — keep everything

Disk is cheap. No auto-deletion. Screenshots live alongside their session in `~/Library/Application Support/Steno/screenshots/{sessionId}/`. Users can manually clean up via filesystem. At ~200MB/hour, even 250 hours of recording only uses ~50GB. Session deletion (if implemented) should cascade-delete the session's screenshot directory.

## Rejected Approaches

### CGWindowListCreateImage (original Approach 1)
Deprecated by Apple in favor of SCScreenshotManager. Triggers extra consent alerts on macOS 15+ Sequoia. No advantage over SCScreenshotManager.

### Extend existing SCStream for video (Approach 2)
Couples screenshot capture to system audio being enabled. App exclusion via SCContentFilter would affect audio capture. Too much coupling.

### Separate SCStream for video (Approach 3)
Heavier — two SCStream instances running simultaneously. SCScreenshotManager is purpose-built for periodic stills and doesn't require a persistent stream.

## Next Steps

Run `/workflows:plan` to break this into implementation milestones. Suggested milestone order:

1. `ScreenCaptureService` + `screenshots` table + basic capture loop (no LLM)
2. `ScreenDescriptionService` with Apple Intelligence backend
3. Anthropic Claude vision backend
4. Topic extraction enrichment with screenshot descriptions
5. TUI `[SCREEN]` markers and description display
6. App exclusion list (settings + CGWindowList filtering)
