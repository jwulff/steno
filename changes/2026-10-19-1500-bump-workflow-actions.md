# Bump workflow actions to current majors

## Why

Dependabot opened three action bumps in May (#16, #29, #30). Two of them edit adjacent
lines of `release.yml` and conflict with each other, and the `setup-go` bump only
touched `test.yml`, which would have left the release job on the old major. One PR
covering both workflows replaces all three (#120).

## How

- `actions/setup-go` v5 → v6 in `test.yml` and `release.yml`.
- `actions/upload-artifact` v6 → v7 in `release.yml`.
- `softprops/action-gh-release` v2 → v3 in `release.yml`.

No inputs changed. These majors move the actions to the Node 24 runtime, which
GitHub-hosted `macos-15` runners support.

## Validation

- CI on this PR exercises `setup-go@v6` through `test.yml`.
- `release.yml` runs only on tags, so the upload and release steps are exercised on
  the next tagged release.
