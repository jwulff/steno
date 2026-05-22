# TUI Fills Entire Terminal Window (PR #7)

## Why

The SwiftTUI view was only using the top portion of the terminal: it
rendered a band of content at the top of the window, then dropped back to
the shell prompt area for the rest of the height. Visually it looked like
the app had crashed and returned to the shell, even though it was still
running and accepting input. Controls at the bottom of the layout were
also being squeezed into wherever the content happened to end, rather
than pinned to the bottom of the terminal.

This was a pure UX bug — nothing functionally broken, just a layout that
ignored the terminal dimensions.

## How

Single-file change in `Sources/Steno/Views/MainView.swift` (+14 / -19).

- Added `frame(maxWidth: .infinity, maxHeight: .infinity)` to the root
  view so it expands to fill the terminal instead of sizing to its
  content.
- Inserted a `Spacer()` in the transcript area so the controls row gets
  pushed to the bottom of the available height rather than floating
  immediately under the transcript.
- Removed the fixed line-count padding that was previously constraining
  the view to a small vertical band. With `maxHeight: .infinity` and the
  `Spacer()` doing the layout work, the manual padding wasn't just
  redundant — it was actively the bug.

The commit also folded in a small unrelated cleanup: switching the
AudioObject CFString APIs to use `Unmanaged<CFString>` to silence Swift's
"implicit retain on CFString" warnings. Not load-bearing for the TUI fix
but was sitting in the same working tree and was cheap to ship together.

## Key Decisions

- **Let SwiftTUI do the layout, not manual padding.** The old code tried
  to size the view by adding empty rows; the fix lets the layout system
  handle vertical distribution via `Spacer()` and infinite frames. This
  is the SwiftTUI idiom and survives terminal resizes correctly.
- **Bundle the CFString warning fix.** Unrelated to the layout bug but in
  the same file area and one-line per call site. Splitting it out would
  have meant a second PR for a build-cleanliness change that nobody was
  going to review separately.

## Testing

- 25 tests passing locally; none of them cover view layout (TUI rendering
  isn't tested in the suite at this point), so verification was manual:
  run `swift run steno` and confirm the view fills the terminal and
  resizes cleanly.
- Build is clean — the CFString fix eliminated the warnings that had
  been showing up on every build.

[steno-tests-passed: 25 tests in 0.2s]

## What's Next

- Layout tests would catch this class of bug, but SwiftTUI doesn't
  provide a great harness for that. Tracked informally until the
  Go/bubbletea rewrite (PR #12) replaces this view entirely, at which
  point the question is moot.
- Terminal resize handling should be tested manually on the next layout
  pass.
