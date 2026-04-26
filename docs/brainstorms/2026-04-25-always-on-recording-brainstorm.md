# Always-On Recording, Self-Healing, and Cross-Source Dedup

**Date:** 2026-04-25
**Status:** Brainstorm complete, ready for planning

---

## What We're Building

Shift Steno from a manual start/stop recorder to an **always-on capture daemon** that:

- Records continuously by strong default, with a clearly visible pause affordance for privacy
- Self-heals across sleep/wake, lid open/close, login, daemon crash, and audio-device changes — without user intervention and without losing data beyond a small bounded recovery window
- Repurposes spacebar in the TUI as a **session demarcation** action (close current, open next), not a recording on/off toggle
- Detects when the microphone is picking up the same audio that ScreenCaptureKit is capturing from the system, and marks the redundant mic segment as a duplicate at storage time so downstream consumers see one logical utterance instead of two
- Auto-prunes wall-to-wall sessions that contain no meaningful content

The end result: I open my laptop in the morning, recording is already on, and I never again realize an hour later that I forgot to start it. When I want to mark a meaningful span ("this conversation") I tap space; when I want privacy I tap `p`.

---

## Why This Matters

The value of a personal capture tool is bounded by its **capture rate**. Missing N% of moments where you wished you had recorded = roughly N% less product value, plus the asymmetric cost of regret — the moment is gone forever, but the cost of "unnecessarily recorded ambient audio" is near zero (it gets auto-pruned or sits as a session you never query).

Today's start/stop model places that asymmetric cost on the wrong side. Always-on flips it. Pause + auto-resume puts a privacy escape hatch in front of the user without re-introducing the "I forgot" failure mode (auto-resume guarantees you can never accidentally stay paused).

Self-healing is the second half of the same thesis: always-on is only as valuable as it is durable. A daemon that silently dies on AirPods reconnect or wake-from-sleep is no better than one you forgot to start.

---

## Key Decisions

### 1. Capture model: continuous stream, sessions = wall-to-wall containers

- Daemon is **always recording** when not paused. There is always exactly one active session.
- Spacebar **closes the current session and immediately opens a new one** — there is never a gap between sessions in the timeline.
- Every segment belongs to exactly one session (preserves the existing schema shape). No "orphan segments outside any session."
- Sessions that close with no meaningful content are auto-deleted at close time (see Empty-Session Cleanup below).

### 2. Pause model: hard pause, visible state, auto-resume by default

- New keybind `p` (TUI): toggles a hard pause on both mic + system audio. While paused, **no audio is captured at all** (no buffer, no transcription, no DB writes).
- Auto-resume after a configurable timeout (default **30 minutes**) — explicitly to prevent "I forgot to unpause" from becoming the new "I forgot to start."
- New keybind `shift-p`: pauses **indefinitely** until manually resumed. The status bar still shows the paused state loudly.
- Pause closes the current session and opens a fresh one on resume (treat the pause window as a session boundary).
- Status bar shows pause state with a visible countdown when on auto-resume:
  - `● REC` (normal)
  - `⏸  PAUSED — resumes in 27:14` (auto-resume countdown)
  - `⏸  PAUSED — manual resume only` (indefinite)

### 3. Self-healing boundary: hybrid 30-second / device-change rule

For every interruption class (sleep, wake, lid, audio device swap, recognizer crash, SCStream interruption):

- **If the recovery gap is < 30 seconds AND the audio input device is unchanged** → keep the same session open. The first segment after recovery is tagged with a heal marker so the user can see in the TUI that a transparent heal happened.
- **If the recovery gap is ≥ 30 seconds OR the audio device changed** → close the current session as `interrupted`, open a fresh one on recovery.
- The 30-second threshold is configurable; this is the starting default.
- "Device changed" means a different mic device is now selected by the system (e.g., AirPods disconnected → built-in mic), not just a route change within the same device.

### 4. Cross-source dedup: write both, mark duplicate, never destroy

- Mic and system-audio segments are **always persisted** to the DB. No real-time suppression.
- A background dedup pass within ~5 seconds of segment finalization compares each mic segment against any system-audio segments that overlap in time (within ±N seconds, default **±3s**).
- Comparison is cheap and deterministic: exact match → normalized-string match (lowercased, punctuation-stripped) → edit-distance ratio against a conservative high-confidence threshold. **No LLM tier** — keeps the dedup pass fast and dependency-free.
- When similarity is above the confident-match threshold, the **mic segment** is marked `duplicate_of: <sys_segment_id>`. System audio always wins because if mic and sys both heard the same words, the mic is hearing the speakers.
- Errs on safety: if the comparison is borderline, the mic segment is **kept** (no dedup mark). Better to show a duplicate occasionally than to silently lose a unique mic utterance that happened to overlap with sys audio.
- TUI and MCP queries default to filtering out `duplicate_of IS NOT NULL`. The raw history is intact and queryable when needed.
- Reversible: if the dedup logic turns out to be wrong, blanking the column restores the original two-stream view of every utterance.

---

## Behavior Spec by Event Class

| Event | Detection signal | Daemon response |
|---|---|---|
| Daemon process start (login, after crash) | LaunchAgent restarts the binary | If no active session in DB → open one. If an active session exists from a prior dead daemon → mark it `interrupted` and open a new one. |
| System will-sleep | `NSWorkspace.willSleepNotification` | Cleanly stop pipelines; persist any in-flight finalized segment; mark current session timestamp; do NOT close the session yet (the heal rule decides on wake). |
| System did-wake | `NSWorkspace.didWakeNotification` | Restart pipelines. Apply heal rule (< 30s + same device → reuse session; else roll over). |
| Lid open / close | Surfaces as sleep/wake on most configs; clamshell mode = no event | Handled via sleep/wake; no separate path needed. |
| Mic device disconnect (AirPods, USB mic, etc.) | `AVAudioEngine.configurationChangeNotification` and equivalent route-change observers | Stop and rebuild the mic pipeline against whatever device the system has now selected. Treat as a device-change event for the heal rule (≥ 30s gap is rare here, but device-changed is true → roll session). |
| System audio interruption (another app captures, SCStream error) | SCStream error / end-of-stream | Restart `SystemAudioSource` with bounded backoff (1s, 2s, 4s, 8s capped at 30s). Mic continues independently. Surface as a non-transient health warning if backoff exceeds N attempts. |
| SpeechAnalyzer recognizer error | Existing `handleRecognizerError` path | Restart that recognizer with the same backoff. Do not stop recording. Surface only if backoff exhausts. |
| Pause requested (`p` / `shift-p`) | TUI command | Close current session cleanly. Stop pipelines. Show pause state. On auto-resume timer or manual resume → open fresh session. |
| User presses spacebar | TUI command | Atomic boundary: close current session, open new session with the same recording config. No interruption to the audio pipelines themselves — only the session record changes. |
| User configures quiet hours (future, not in scope) | — | Out of scope for this brainstorm. Pause is sufficient. |

---

## Empty-Session Cleanup

A session is considered "empty" at close time if **either**:

- It has zero segments after duplicates are marked, OR
- The total non-duplicate transcribed text length is below a threshold (default **20 characters** of non-whitespace), OR
- Its wall-clock duration was below a minimum (default **3 seconds**)

Empty sessions are deleted (cascade-deletes any segments) at the moment they close. This applies to all close paths: spacebar, pause, sleep-rollover, device-change-rollover.

---

## Health & Observability Surface (TUI)

The current TUI gives a binary "REC vs IDLE" indicator. Always-on demands a richer surface so I can never be confused about state:

- **Always-visible recording state** with one of: `● REC`, `⏸  PAUSED — resumes in HH:MM`, `⏸  PAUSED — manual`, `⚠ RECOVERING — gap 12s`, `✗ FAILED — see error`
- **Last-segment-at indicator** (e.g. `last segment 4s ago`) so silent failures (frozen recognizer, hung pipeline) become visible instead of looking like normal silence. Above some threshold (e.g. 60s without a segment while not paused) this turns into a warning.
- **Permission/health warnings** persist (no 5-second auto-clear) when they reflect ongoing degraded state — e.g., system audio backoff exhausted, mic permission revoked.
- **Heal markers** appear inline in the segment timeline ("⚠ healed after 12s gap" between segments).

---

## Scope Boundaries

**In scope:**
- All four key decisions above
- Empty-session auto-prune at close time
- Health/observability changes in the TUI
- Schema additions for dedup columns and segment heal marker
- Daemon supervisor logic for sleep/wake, audio route, recognizer/SCStream restart
- Auto-open initial session on daemon start; auto-mark stranded `active` sessions as `interrupted` on recovery

**Deferred for later:**
- Quiet-hours scheduling (manual pause covers the immediate need)
- App/device-aware automatic pause (1Password frontmost, etc.) — interesting but adds policy surface
- Retroactive editing of session boundaries (merge two sessions, split one, retitle)
- Migration of existing sessions to add the new columns is in scope, but **historical re-dedup of pre-existing segments** is not (only forward dedup runs)
- Backfilling heal markers on segments captured before this change

**Outside this product's identity:**
- Cloud sync or remote storage of always-on data (privacy + scope)
- Multi-user / shared session models

---

## Assumed Defaults (push back if any are wrong)

These were not asked explicitly but are needed to write the plan. Calling them out so they're easy to correct:

1. **Pause auto-resume = 30 minutes**, configurable via daemon config file
2. **Heal-window threshold = 30 seconds**, configurable
3. **Dedup time-overlap window = ±3 seconds**, configurable
4. **Dedup similarity**: cheap, deterministic, no LLM. Tiered as exact match → normalized-string match (lowercased, punctuation-stripped) → edit-distance ratio with a conservative high-confidence threshold. If the score is borderline (anywhere below the confident-match threshold), default to **KEEP** the mic segment (do not mark as duplicate). Better to occasionally show a duplicate than to silently lose a unique mic utterance. The LLM tier is explicitly NOT in this brainstorm; it can be added later if false-keeps become annoying.
5. **Empty-session thresholds**: 0 segments OR < 20 chars non-duplicate text OR < 3s wall-clock duration
6. **Stranded `active` sessions on daemon start** are marked `interrupted` (not deleted) — preserves historical fact that a session was abruptly cut.
7. **Pause behavior across sleep**: stay paused on wake (don't surprise-resume because of a system event). Auto-resume timer is **wall-clock based** — it continues to count during sleep, so a 30-min auto-resume started at 14:00 will resume at 14:30 even if the laptop slept through most of that window.
8. **Spacebar in paused state**: no-op (with a brief flash in the TUI explaining "press p to resume first"). Spacebar is for demarcating *active* recording; pressing it while paused has no meaningful action.
9. **`make install` / LaunchAgent**: existing `KeepAlive=true` covers process supervision. No changes to the launchd plist are required for self-healing — the new logic lives inside the daemon.

---

## Success Criteria

- I can leave the laptop running for a week with sleep/wake cycles, AirPods reconnecting, and external display swaps, and on inspection: every wall-clock minute that I was awake-and-not-paused is covered by a session, with no `active`-but-stranded sessions in the DB.
- I never again open the TUI and discover I "forgot to start recording" — there is no off state I can land in by accident; only active, paused (with timer), or paused-indefinite (loudly visible).
- When I'm in a Zoom call, I get one logical transcript per utterance, not two — even though both mic and system audio captured it. The original mic version is still queryable with one column-aware query.
- Sessions in the DB do not accumulate empty-noise rows from times when I walked away from the laptop.
- A pipeline crash, recognizer error, or SCStream interruption recovers automatically within seconds with no user input. The TUI shows a heal marker so I can see it happened.
- The TUI status bar makes the current state unambiguous at a glance — recording, paused-with-countdown, paused-indefinite, recovering, or failed — not just connected/disconnected.

---

## Risks & Open Questions

1. **Battery / thermal**: continuous mic + ScreenCaptureKit + SpeechAnalyzer is non-trivial. Need to measure baseline draw on a real workday before declaring success.
2. **Disk growth**: even with empty-session pruning, an always-on workday produces meaningfully more rows. Worth a back-of-envelope ("100 segments/hour × 10 hours/day × 365 days = ~365k rows/year") and a retention policy decision *before* shipping (prompt: should there be auto-deletion past N days, or is "keep forever, query rarely" fine?).
3. **Dedup false positives**: the safest threshold is conservative (high-confidence matches only). The risk is that "we're talking and Steno didn't dedup" makes the feature look broken. Acceptable trade because the user prioritized "never lose data" over aggressive dedup.
4. **Sleep-wake on macOS 26**: SpeechAnalyzer's behavior across sleep is not documented in detail. May require empirical work to find the right teardown/restart sequence. Plan should include a discovery spike.
5. **SCStream contention**: if another app starts capturing system audio (a screen recorder, a meeting client), our SCStream may fail. Backoff handles transient cases but a persistently contended SCStream may need a graceful "system audio temporarily unavailable" state rather than indefinite retry.
6. **Spacebar collision**: spacebar is currently the only recording action and users may have muscle memory for "tap space when I want to record." The new meaning ("close this session, open the next") is a meaningful UX change. Worth a one-time first-launch hint in the TUI.
7. **What is a "session" for, post-shift?** Today a session is "the thing I started and stopped." After this change, a session is "a span I marked as interesting between two spacebar taps OR between two interruptions." Worth thinking about whether session titles, summarization, and topic extraction still make sense at the same granularity. (Probably yes, but worth a sanity check during planning.)

---

## Dependencies / Assumptions

- macOS 26 SpeechAnalyzer continues to behave correctly across sleep/wake when the pipeline is properly torn down and rebuilt. (Risk #4.)
- LaunchAgent `KeepAlive=true` is sufficient process supervision. (No new launchd work needed.)
- The on-device LLM infrastructure already in the daemon (used today for topic extraction) is reusable for borderline dedup judgments.
- The user is the sole intended consumer; this is a personal capture tool, not multi-user.
- Existing schema can be evolved with additive columns (`duplicate_of`, `dedup_method`, `dedup_score`, segment heal marker, session `interrupted` status was already enumerated but unused — now used). No destructive migration required.
