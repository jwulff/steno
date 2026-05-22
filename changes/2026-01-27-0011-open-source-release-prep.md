# Open Source Release Prep — CI Smart Fallback (PR #5)

## Why

Steno targets the macOS 26 SpeechAnalyzer API, which requires Swift 6.2+.
GitHub Actions runners didn't have that yet (and wouldn't for months), so a
naive `swift build && swift test` on CI was guaranteed to fail on every
push. We still wanted PR-level CI signal before opening the repo to the
public, so we needed a workflow that could distinguish "tests genuinely
broken" from "GitHub's toolchain just isn't there yet."

The project already had a `[steno-tests-passed: N tests in Xs]` attestation
convention enforced by the pre-push hook. CI just needed to learn to trust
it when the runner couldn't run the tests itself.

## How

Rewrote `.github/workflows/test.yml` into a three-job pipeline. No source
code or tests changed; this PR is workflow-only despite the broader
"prepare for open source release" framing in the PR title.

### Job 1 — `check-attestation`

Runs on `ubuntu-latest`. Greps the commit message (or, for `pull_request`
events, the PR head commit) for `[steno-tests-passed:`. Exports
`has_attestation=true|false` as a job output. No build tools required —
this is just a string match against the commit subject/body.

### Job 2 — `test`

Runs on `macos-15`. Sets up Swift 6.0 (the newest version GitHub offered at
the time), then compares the installed `swift --version` against the
`swift-tools-version` declared in `Package.swift`. Exports
`swift_version_ok=true|false`. If `version_ok` is true, it actually runs
`swift build -v` and `swift test -v`; otherwise both steps are skipped via
`if:` guards so the job doesn't fail spuriously on a known-incompatible
runner.

### Job 3 — `result`

Always runs (`if: always()`) and aggregates the previous two:

- Tests passed on CI → green.
- Swift version incompatible AND attestation present → green, with a log
  note that CI will start running tests automatically once the runner
  catches up.
- Swift version incompatible AND no attestation → red, with instructions
  on how to add the attestation locally.
- Tests ran but failed → red.

This `result` job is what branch protection points at, so PRs get a single
consolidated check.

## Key Decisions

- **Trust the local attestation rather than skip CI entirely.** Skipping
  would have meant zero PR-level signal until macOS 26 landed on GitHub.
  The attestation already gates `git push` locally via the pre-push hook,
  so this just lifts that same signal into the PR check.
- **Self-deprecating design.** Once GitHub runners get Swift 6.2 /
  macOS 26, the `version_ok` branch flips and CI runs tests for real with
  no workflow change required. The attestation fallback becomes dead code
  rather than something that needs to be ripped out.
- **PR scope was narrower than the title suggests.** The PR title is
  "Prepare for open source release" and the body mentions a release
  workflow and Dependabot, but only `.github/workflows/test.yml` actually
  shipped in this PR. The LICENSE, README, release workflow, and
  Dependabot config landed separately. Calling that out here so the next
  reader doesn't go looking for those files in this commit.

## Testing

- 25 tests passing locally (only test suite at this point — pre-daemon
  split).
- CI workflow itself was tested by virtue of being the thing under test:
  PR #5's own CI run exercised the attestation-fallback path because
  GitHub's Swift was still pre-6.2.

[steno-tests-passed: 25 tests in 0.2s]

## What's Next

- Pair this with LICENSE + README so the repo is actually presentable
  (shipped immediately after as PR #6).
- Add Dependabot for Swift package updates (followed later).
- Eventually drop the attestation-fallback branch once `macos-26` runners
  are available on GitHub Actions.
