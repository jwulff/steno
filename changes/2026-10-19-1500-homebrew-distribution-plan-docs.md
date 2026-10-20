# Homebrew distribution brainstorm and plan

## Why

Issue #40 asks for `brew install` support. The requirements brainstorm and
implementation plan for it were written on 2026-04-29 but sat in an open PR
while part of the work shipped by other routes. Landing them keeps the design
reasoning (tap vs. core, source-built formula with bottles, the TCC cdhash
question, the launchd conflict) in the repo next to the other plans.

## How

- Adds `docs/brainstorms/2026-04-29-homebrew-distribution-requirements.md`
  and `docs/plans/2026-04-29-001-feat-homebrew-distribution-plan.md`.
- Adds `AGENTS.md` with `project_tracker: github` so `ce-plan` routes issue
  creation to GitHub Issues.
- Adds a dated status note at the top of the plan. Main shipped the formula
  through the shared `jwulff/homebrew-tap` (#44) and single-sourced the
  version (#95), so the plan's dedicated `jwulff/homebrew-steno` tap no
  longer describes reality. The note lists what shipped, what shipped
  differently, and what is still open under #40.

## Validation

Docs only. Rebased onto current main; CI runs the normal suite. Copilot's six
review threads from the original review were addressed and resolved before
this rebase.
