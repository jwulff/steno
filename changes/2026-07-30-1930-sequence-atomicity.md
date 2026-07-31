# The sequence number is assigned where it is written

## Why

A consumer tailing `WHERE sequenceNumber > :cursor` could permanently skip a committed row.
Narrow window, silent, unrecoverable — once the cursor moves past, that segment is never
returned again.

Found by reading the code while diagnosing #85, not from an incident signature. Filed
rather than fixed at the time because, unlike its siblings, it needed a decision about
where sequence assignment belongs.

## What was wrong

`RecordingEngine.handleRecognizerResult` assigned the number and then persisted, with
suspension points in between:

```swift
currentSequenceNumber += 1
...
try await repository.saveSegment(segment)
```

The engine is an actor, so *assignment* was serialized and monotonic. The *inserts* were
not: two concurrent recognizer results — one per source — could both be in flight, and the
row holding N+1 could become visible before the row holding N. A reader polling at exactly
that instant saw N+1, advanced its cursor, and never saw N. The demarcate-routing path
widened the window further with an extra `await` between the bump and the save.

The same gap was a latent `UNIQUE(sessionId, sequenceNumber)` collision: two writers could
compute the same next slot.

## How

`appendSegment` assigns `MAX(sequenceNumber) + 1` and inserts **inside one transaction**.
GRDB serializes writes, so no other writer interleaves: a row numbered N is durable before
N+1 is even assigned. Assignment order is commit order, which is exactly the property a
cursor needs.

The engine no longer sequences at all. It passes `StoredSegment.unassignedSequence` and
uses the returned segment — which also deleted the demarcate-routing arithmetic that
borrowed a slot from the current session and backed the counter off by one. Per-session
`MAX+1` handles routing for free.

`currentSequenceNumber` survives only as a status/display frontier, updated from the
persisted segment and only when the segment landed on the current session.

## Key decisions

- **The database assigns, not the engine.** The alternative — hold a lock across assignment
  and insert in the engine — keeps two sources of truth in sync by discipline. Moving
  assignment to the writer makes the invariant structural.
- **`saveSegment` stays** as the explicit-sequence primitive, because fixtures and backfills
  legitimately need to place a specific number. Its doc now says plainly that production
  writers must use `appendSegment` and why.
- **`unassignedSequence` over an optional.** Making `sequenceNumber` optional on
  `StoredSegment` would ripple through every consumer to express a state that exists for
  microseconds. A named sentinel documents the contract without the churn.

## Testing

The tests are written against the failure, and verified to catch it: temporarily
reimplementing `appendSegment` the racy way — read the frontier in one transaction, insert
in another — makes `concurrentAppendsProduceContiguousSequences` fail immediately with

```
SQLite error 19: UNIQUE constraint failed: segments.sessionId, segments.sequenceNumber
```

which is the collision half of the same bug. With the real implementation, 60 concurrent
appends across both sources yield exactly 1...60: no duplicates, no gaps.

Also covered: returned sequence numbers match what was persisted; each session is numbered
independently (the demarcate case); and append resumes past pre-existing segments rather
than restarting at 1 (the wake/device-change case).

`make test-daemon`: 506 passed, 0 failed.

## What's next

A `sequenceNumber` cursor is now safe from loss, but it is still not the right axis for a
live consumer: it lags the capture frontier under load and interleaves the two sources by
finalization order. `captured_at` remains the recommendation, for freshness and ordering
rather than for safety. The schema contract now says exactly that.

Closes #83.
