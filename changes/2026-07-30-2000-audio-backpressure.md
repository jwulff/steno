# Let the pipeline drop audio rather than fall an hour behind

## Why

Once transcription falls behind, the queue between capture and the recognizer grows without
bound and never drains while audio keeps arriving. On a ~7-hour recording that reached ~49
minutes of lag (#85); the only observed recovery was restarting into a fresh session, which
fragmented one meeting into four.

For a live watcher, fresh-and-lossy beats complete-and-50-minutes-late. There was no way to
make that trade.

## How

`AsyncStream` between the audio tap and the recognizer was created with the default
unbounded buffering policy — that is the unbounded queue. It is now
`.bufferingNewest(capacity)` when `audioBacklogCapSeconds > 0`, which discards the **oldest**
buffered audio first. That is the right end to lose: a listener minutes behind wants the
newest audio, not the backlog.

`continuation.yield` reports what it discarded, which gives an exact hook. Each dropped
buffer's duration is computed from its real frame count, accumulated per source, and
reported on a one-second trailing debounce — a sustained backlog drops dozens of buffers a
second, and "dropped 0.1s" thirty times is both a log flood and less useful than "dropped
3.0s".

Each burst emits `audioShed(seconds:source:)`, mirrors onto the existing transient-error
wire channel for older clients, and arms `shed:<seconds>s` on the next segment's
`heal_marker` — so a reader sees that audio was discarded rather than finding it silently
absent.

## Key decisions

- **Default off (`0`).** Shedding is right for a live watcher and wrong for archival
  recording, and the existing behavior is the archival one. An install upgrading into this
  release must not quietly start discarding audio, so `decodeIfPresent … ?? 0` keeps
  settings files written before this change disabled.
- **Drop oldest, not newest.** `.bufferingNewest` is named for what it *keeps*. Dropping
  the newest would keep the transcript complete-but-stale, which is the failure being fixed.
- **The cap is approximate; the reported numbers are exact.** Sizing a bounded stream needs
  an element count, but the cap is expressed in seconds, so conversion uses a nominal
  0.1s buffer. Hardware picks real buffer sizes and they vary. Rather than pretend
  otherwise, every *reported* figure is measured from the discarded buffers' actual frame
  counts — an operator reading "dropped 3.0s" can trust it even though the threshold that
  triggered it is fuzzy. The nominal constant is documented as exactly that.
- **Mark the transcript, don't just log.** A log line is gone by the time anyone reads the
  transcript. `heal_marker` already carried this shape for restart gaps; `shed:` distinguishes
  deliberate discard from a pipeline restart.

## Testing

- `.bufferingNewest(3)` fed 1…6 discards `[1,2,3]` and delivers `[4,5,6]` — the primitive
  drops the oldest, which is the whole premise.
- A 0.25s buffer measures as 0.25s, and the fixture deliberately differs from the 0.1s
  nominal so the assertion proves measurement rather than coincidence.
- `audioBacklogCapSeconds` survives a settings round trip.
- A settings JSON written before this change decodes to `0` — shedding stays opt-in.
- A bounded-latency window fires once for 50 rapid events; a trailing debounce would not
  have fired at all.
- The analyzer-range mapping is early by exactly the shed duration without the correction.

`make test-daemon`: 0 failures. (The reported pass count varies run to run — 464 to 469
here — because the harness's documented macOS 26 teardown abort truncates the log before
the final tally. `✘` count is 0 across runs.)

**Not covered by an automated test:** shedding under a genuinely starved recognizer. Driving
a real backlog deterministically means starving a live audio pipeline on a timer, which is
exactly the sort of load-dependent test that passes on an idle machine and flakes on a busy
one. The primitive, the measurement, and the defaults are tested; the integration is
reasoned from them.

## What review caught

Four defects in the first pass, two of them serious enough to have made this a net
negative:

- **Shedding corrupted the capture clock.** `capturedAt` is
  `analyzerStart + audioStartSeconds`, and the analyzer's timeline advances only over
  frames it actually receives — so every dropped buffer shifted all later segments earlier
  by the discarded duration, cumulatively. That is the exact axis #85 built the transcript
  ordering, dedup matching, and lag measurement on. Now the running shed total is added
  back when mapping analyzer ranges to wall clock.
- **The report would never have fired.** The coalescing used a trailing debounce that
  rescheduled on every drop — and the failure this cap exists for is *continuous* shedding,
  many drops per second. It would have been cancelled and replaced indefinitely: audio lost
  silently, no event, no marker, for hours. Replaced with a bounded-latency window opened by
  the first drop of a burst, so a sustained shed reports once per second for as long as it
  lasts.
- **Report tasks survived `stop()`**, so a shed within a second of stopping could re-arm a
  heal marker after teardown cleared it — making the first segment of the *next* session
  claim audio was shed in a session that had not started.
- **Two wire events per report**, because `EventBroadcaster` already maps `.audioShed` onto
  the transient-error channel and the code emitted `.error` as well — defeating the
  coalescing.

## What's next

The cap is a blunt instrument: it discards audio without knowing whether the room is
speaking. Now that `captured_at` (#85) gives a true audio-vs-wall-clock lag figure, a
smarter policy could shed only while lag exceeds the cap *and* the backlog is still
growing, or prefer to drop silence. Worth revisiting once there is real operating experience
with a cap set.

Closes #84.
