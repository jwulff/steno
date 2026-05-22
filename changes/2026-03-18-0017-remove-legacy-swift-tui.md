# Remove Legacy Swift TUI and Dead Code (PR #27)

## Why

PR #11 extracted the daemon, PR #12 introduced the Go TUI as a thin
client, PR #24 added the MCP server, and PR #26 unified the two Go
binaries into a single `steno` with a `--mcp` flag. Across that
sequence, the original monolithic Swift TUI under `Sources/Steno/`
plus its vendored `LocalPackages/SwiftTUI/` dependency had been kept
around — partly to keep CI green during the refactor, partly as a
safety net in case the new architecture turned out to need a fall-back.

By this point the new architecture had been stable across multiple PRs
of TUI polish (#21, #22, #23) and the daemon + Go unified binary had
shipped (#26). The legacy code wasn't a hedge any more — it was 14,756
lines of dead weight: a `test-legacy` make target that nobody ran for
real, a root `Package.swift` whose only purpose was building the
monolith, and a vendored SwiftTUI library nothing depended on.

The cleanup is purely a hygiene win — no user-visible behavior change.
Pruning it removes ~1,550 files, shrinks the repo, simplifies CI,
and eliminates the "which TUI does this CLAUDE.md mean?" confusion
when reading the codebase fresh.

## How

### Deletions

| Path                              | What it was                                  |
|-----------------------------------|----------------------------------------------|
| `Sources/Steno/`                  | Original monolithic Swift TUI (35 files)     |
| `Tests/StenoTests/`               | Tests for the legacy TUI (20 files)          |
| `LocalPackages/SwiftTUI/`         | Vendored SwiftTUI dependency (~1500 files)   |
| `Package.swift` (root)            | Swift package manifest for the legacy build  |
| `Resources/Steno.entitlements`    | Entitlements for the legacy binary           |

The daemon has its own `daemon/Package.swift`, `daemon/Resources/`,
and entitlements — none of those are touched.

### Makefile cleanup

- Removed the `test-legacy` target (and its `swift package clean` call).
- `make test` now runs only `test-daemon` (Swift) + `test-steno` (Go),
  which matches the actual two-binary architecture.

### CI workflow

`.github/workflows/test.yml` was running `swift build` / `swift test`
at the repo root, which depended on the now-deleted root `Package.swift`.
Updated to:

- Run `make build` and `make test` instead of `swift` commands directly.
- Add a Go setup step (`actions/setup-go`) so the steno tests can compile.

This makes CI use the same entry points developers use locally, which
is how it should have been from the start of the two-binary world.

### Docs

`CLAUDE.md`, `README.md`, and `schema/README.md` had lingering
references to the legacy monolith, the `test-legacy` target, and
`Sources/Steno/...` paths. All trimmed.

### `.gitignore`

`tui/steno-tui` (binary output from the old separate TUI build) is
replaced with `dist/` — the directory where the unified `make build`
puts its artifacts.

## Key Decisions

- **One delete-and-update PR, not staged across several** — the
  legacy code had no live consumers; deleting it in halves would have
  meant intermediate states where part of the references still
  pointed at deleted files. Single PR, single revert if anything broke.
- **CI fix in the same PR as the deletes** — the root `Package.swift`
  removal is the proximate cause of the CI break, so the fix belongs
  in the same commit pair. Splitting them would have meant a red
  main branch between the merges.
- **No grace period / no deprecation tag** — nothing depended on the
  legacy code. There was nobody to warn. Pure dead-code removal.
- **Keep `daemon/` untouched** — the deletion is intentionally scoped
  to legacy *frontend* code. The Swift daemon is the canonical
  backend and stays exactly where it is.

## Testing

[steno-tests-passed: 251 tests in 30s] (171 daemon + 80 steno)

- `make test` passes with the `test-legacy` target removed.
- `make build` produces both `steno-daemon` and `steno` binaries.
- CI workflow now runs the make-based pipeline against the new repo
  layout.

## What's Next

- The repo is now at its target structure: `daemon/` (Swift) and
  `cmd/steno/` (Go), nothing else. Future work can stop carrying
  caveats about the legacy monolith.
- With `Sources/Steno/` gone, the project root `Package.swift`-shaped
  hole means tools that assumed a top-level Swift package
  (e.g. some IDE integrations) need to point at `daemon/Package.swift`
  explicitly. Worth a follow-up note in the README if it bites
  anyone.
