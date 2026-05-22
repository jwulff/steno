# LICENSE, README, and SwiftTUI Pin (PR #6)

## Why

Immediately on the heels of PR #5's CI fallback, the repo still wasn't
ready to be public: no license file (so technically all-rights-reserved
under default copyright), no README explaining what Steno does or how to
build it, and an unpinned SwiftTUI dependency that could re-resolve to a
different commit on any clean checkout.

This PR is the actual "open source release prep" content that the title of
PR #5 had advertised — the housekeeping needed before pointing anyone at
the repo URL.

## How

Three small, independent changes bundled into one PR because they all
share the same motivation (make the repo presentable and reproducible):

- **`LICENSE` (new, 21 lines)** — Standard MIT license text, attributed
  to John Wulff.
- **`README.md` (new, 81 lines)** — Installation, usage, and development
  sections. Enough for a new contributor to clone, build, and run without
  having to spelunk through `Package.swift` and the Makefile.
- **`Package.swift` (1 line changed)** — Pinned the SwiftTUI dependency
  to commit `5371330` instead of a moving branch ref, so `swift package
  resolve` produces identical output across checkouts and across time.

## Key Decisions

- **MIT over Apache-2.0 or GPL.** MIT keeps friction lowest for both
  contributors and downstream users — no patent grant language to argue
  about, no copyleft to worry about. Consistent with John's other public
  repos.
- **Pin SwiftTUI to a specific commit, not a tag.** SwiftTUI doesn't
  publish tags reliably, and at the time we were tracking `main`. Pinning
  to a commit SHA guarantees byte-identical resolution; we accept the
  manual-bump cost as the price of build reproducibility.
- **One PR, three files.** All three changes are tiny and serve the same
  goal (make the repo OSS-ready). Splitting them into three PRs would
  have been more ceremony than value.

## Testing

No behavioral changes — LICENSE and README don't run, and the SwiftTUI
pin just locks the existing resolution in place.

[steno-tests-passed: 25 tests in 0.2s]

## What's Next

- The next OSS-readiness items (release workflow for tagged binaries,
  Dependabot config) land in follow-up PRs.
- README will need to grow significantly once the daemon split and Go TUI
  arrive — current version still describes Steno as a single Swift binary.
