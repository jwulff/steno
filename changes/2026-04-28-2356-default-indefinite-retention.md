# Default to indefinite retention (PR #38)

## Why

U12 (part of the always-on-recording effort, PRs #33–#37) shipped with
`retentionDays: 90` as a hedge against unbounded disk growth. Once the
feature met real use, the hedge looked over-cautious. A back-of-envelope
walk against actual always-on data rates:

- ~150 wpm × 10 active hours/day × 365 days × ~10 bytes/word ≈ **5 MB/year
  of raw text**
- Plus SQLite row overhead, indexes, dedup metadata ≈ **100–200 MB/year
  on disk**

On a modern Mac that's small enough that an automatic 90-day sweep is
more likely to silently lose moments the user wanted to keep than to
save meaningful disk. Speech history is the kind of thing where "I'll
keep this until I tell you otherwise" is the only sensible default —
the cost of getting the policy wrong is asymmetric in favor of keeping
data.

## How

One-file defaults change in `daemon/Sources/StenoDaemon/Models/StenoSettings.swift`:
flip the default `retentionDays` from `90` to `0` (indefinite).

The `applyRetentionPolicy` short-circuit (`guard retentionDays > 0 else
{ return 0 }`) was already in place from U12, so flipping the default
to `0` is all that's needed — the prune machinery stays intact, it just
no-ops by default.

## Key Decisions

- **Indefinite, not "very large number".** Using `0` as a sentinel for
  "off" (rather than `Int.max` or 36500) keeps the intent legible in
  the settings file and matches the existing short-circuit semantics.
- **Don't touch existing `settings.json` files.** Users who already
  have `90` persisted keep that value and keep sweeping. Only fresh
  installs — or users who explicitly delete the `retentionDays` key —
  pick up the new indefinite default. Silently expanding everyone's
  retention window would have been a surprise.
- **Keep the prune capability.** This is a default-policy change, not
  a feature removal. Users who want a rolling window for privacy or
  storage reasons set `retentionDays` to a positive integer in
  `~/Library/Application Support/Steno/settings.json` and the existing
  sweep runs.

## Testing

`[steno-tests-passed: 488 tests in 25s]`

The existing retention-policy tests cover the `> 0` path; the default
change is exercised by `StenoSettings`' decode-with-defaults tests.

## What's Next

- A future "first-launch onboarding" surface could ask the user what
  retention window they want, instead of relying on settings-file
  edits. Low priority — the default is now the right one for most
  users.
- If real-world disk usage diverges from the back-of-envelope estimate
  above, revisit. The hooks are still there.
