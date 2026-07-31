# Ask a binary what it is

## Why

`steno-daemon --version` printed `0.1.0` on every release ever cut, and the Go CLI had no
version flag at all. After an upgrade there was no way to confirm which binary was running
— the working fallback was reading the DB migration list or the binary's mtime.

That's worst exactly when it matters: verifying an upgrade landed, or reading a bug report
filed against "the latest version".

Confirmed across two genuinely different binaries — a 2026-06-01 build and the v0.5.1
release (15398368 vs 16271664 bytes, only the latter applying migration
`20260730_001_segment_captured_at`) — both reporting `0.1.0`.

## How

`VERSION` at the repo root is the single source of truth.
`scripts/sync-version.sh` generates a Swift constant and a Go constant from it, and both
generated files are **committed**.

Committing generated files is the unusual choice, so: the Homebrew formula builds from a
source tarball with no git metadata and invokes `swift build` / `go build` directly. Any
version computed by the Makefile — from `git describe` or otherwise — would simply be
absent there, which is how you end up with a third build path reporting something
different again. Committing the constants is what makes `make`, Homebrew, and CI agree.

`make check-version` guards the committed copies against drift and is wired into
`make test`, so CI and the pre-push hook both enforce it.

There were three places a version could be wrong, not one. Besides
`steno-daemon --version`, the Go binary advertised `0.1.0` as `ServerInfo.Version` over
MCP — its primary interface — so a client asking what it was talking to got the wrong
answer even after the flag was fixed.

## Guarding the release path

A drift check that only runs under `make test` does not protect a release: `release.yml`
runs `make build`. And `check-version` alone cannot catch the more likely mistake — tagging
`v0.6.0` without touching `VERSION` passes it, because the constants do agree with the
(stale) `VERSION`. The binaries would ship reporting `0.5.1`, which is the exact bug this
change exists to eliminate.

So there are two guards on two different failure modes:

- `check-version` — the generated constants match `VERSION`. Now a prerequisite of `build`,
  not just `test`, so it covers the release path.
- `check-release-tag TAG=…` — `VERSION` matches the tag being built. Wired into
  `release.yml` *before* the build step, so a mismatched tag fails in seconds rather than
  publishing wrong binaries.

## Key decisions

- **`--check` never writes to the tracked files.** The first version of this guard
  regenerated the constants and then diffed them, so it repaired the drift it was meant to
  detect and passed unconditionally. It was caught by testing the failure case rather than
  the passing one. It now renders the expected contents to stdout and diffs against what's
  on disk.
- **Generated-and-committed over build-time injection.** `-ldflags -X` for Go and a SwiftPM
  prebuild plugin for Swift would both work under `make`, and neither reaches the Homebrew
  build. One mechanism that works everywhere beats two that each work somewhere.
- **A plain `VERSION` file over parsing the git tag.** Same reason — the source tarball has
  no tags. It also makes bumping the version an explicit, reviewable diff.

## Testing

The guard is verified against its failure modes, not just its success:

| Case | Expected | Result |
|---|---|---|
| In sync | pass | pass |
| `VERSION` bumped, constants stale | fail | fails, names the drifted file, shows the diff |
| Constants tampered, `VERSION` unchanged | fail | fails likewise |
| Repaired via `make version-sync` | pass | pass |

And the release-tag guard:

| Case | Expected | Result |
|---|---|---|
| `TAG=v0.5.1` against `VERSION` 0.5.1 | pass | pass |
| `TAG=v0.6.0` against `VERSION` 0.5.1 | fail | fails, names the bump needed |
| `TAG` omitted | fail | fails with usage |
| `TAG=0.5.1` (no `v`) | pass | pass |

MCP `ServerInfo` verified over a real initialize handshake:
`{"name": "steno-mcp", "version": "0.5.1"}`.

End to end after `make build`:

```
$ ./daemon/.build/release/steno-daemon --version
0.5.1
$ ./cmd/steno/steno --version
steno 0.5.1
```

`make test`: 502 daemon tests, full Go suite, all green.

## What's next

Releasing now has a step it didn't have: bump `VERSION`, run `make version-sync`, commit.
Forget it and `check-release-tag` fails the release workflow before it builds anything —
loud and early, rather than another release that claims to be someone else.

Closes #92.
