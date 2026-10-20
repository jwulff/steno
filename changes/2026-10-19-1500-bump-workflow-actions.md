# Bump workflow actions to current majors

## Why

Dependabot opened three action bumps in May (#16, #29, #30). Two of them edit adjacent
lines of `release.yml` and conflict with each other, and the `setup-go` bump only
touched `test.yml`, which would have left the release job on the old major. One PR
covering both workflows replaces all three (#120).

## How

- `actions/setup-go` v5 → v7 in `test.yml` and `release.yml`.
- `actions/upload-artifact` v6 → v7 in `release.yml`.
- `softprops/action-gh-release` v2 → v3 in `release.yml`.

Dependabot proposed `setup-go` v6, but v7 shipped on 2026-07-16 with unchanged inputs, so
this goes straight to v7 instead of landing a major that is already behind. No inputs
changed. These majors move the actions to the Node 24 runtime, which GitHub-hosted
`macos-15` runners support.

## Validation

- `actionlint` parse check and a Codex preflight review of both workflow files.
- CI does not exercise these steps on this PR. `test.yml` gates Setup Go, Build and
  Run tests on a Swift version check that fails on the runner (Swift 6.0 installed,
  6.2 required), so those steps are skipped; that gap is tracked separately.
- `release.yml` runs only on tags, so all three bumps are first exercised on the next
  tagged release.
