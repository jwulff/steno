---
title: "feat: Homebrew distribution via personal tap with bottle CI"
type: feat
status: active
date: 2026-04-29
origin: docs/brainstorms/2026-04-29-homebrew-distribution-requirements.md
deepened: 2026-04-29
---

# feat: Homebrew distribution via personal tap with bottle CI

## Overview

Make `brew tap jwulff/steno && brew install steno` work end-to-end on macOS 26 arm64. Ship a source-built formula in a new `jwulff/homebrew-steno` tap, with bottle CI that auto-publishes prebuilt artifacts on every Steno release. Same formula stays structurally eligible for graduation to `homebrew/core` later — no rewrite required.

This plan also corrects the stale `release.yml` in `jwulff/steno` (R10), single-sources the version string across the daemon's Swift code, the embedded Info.plist, and the Go binary (R13), adds daemon-side detection for the `brew services` ↔ `steno-daemon install` launchd conflict (R14), and adds a `--version` flag to the Go `steno` binary so the formula's `test do` block has something concrete to assert.

A formula-bump automation (originally U5: tag-driven `repository_dispatch` from `jwulff/steno` to the tap, opening the bottle PR automatically) was scoped out after document review — for Phase 1 release cadence the manual `brew bump-formula-pr` flow is enough, and the deferred automation eliminates a PAT-trust surface and three GitHub Actions workflows.

---

## Problem Frame

Current Steno install paths are tarball-from-Releases (manual, uncommon for macOS CLIs) and `make install` (slow, requires Swift + Go toolchains and repo clone). Mac developers expect `brew install`. We commit to a phased path: a personal tap now, `homebrew/core` later. Phasing is constrained by core's "source build only, no binary-only formulas" rule, so the Phase 1 formula must already be source-built with bottles — not binary-download — to avoid a rewrite (see origin: `docs/brainstorms/2026-04-29-homebrew-distribution-requirements.md`).

Sub-problems surfaced during planning and document review:

1. The `steno` Go binary has no `--version` flag — the formula's `test do` needs something assertable.
2. `release.yml` is stale (Swift 6.0, `macos-15`, ad-hoc paths that are subtly inaccurate, single-binary tarball). U2 rewrites it.
3. The daemon's version is hardcoded in three places that drift on every release: `daemon/Sources/StenoDaemon/StenoDaemon.swift` `CommandConfiguration.version`, `daemon/Resources/Info.plist`'s `CFBundleVersion` + `CFBundleShortVersionString`, and `cmd/steno/main.go`'s MCP server registration `server.NewMCPServer("steno-mcp", "0.1.0", …)`. U1 single-sources these from a `VERSION` file at the repo root.
4. The formula's `service` block enables `brew services start steno`. The existing `steno-daemon install` registers a separate launchd plist. If both are active, the daemon's `pidFile.acquire()` throws on the second instance, launchd respawns per `keep_alive true`, and the user gets escalating backoff with no diagnostic. U7 adds daemon-side conflict detection so `RunCommand` and `InstallCommand` refuse with an actionable error.
5. Migrating users from `make install` to `brew install` likely changes the daemon binary's cdhash — different SwiftPM caches, different Mach-O LC_BUILD_VERSION metadata. macOS keys TCC permission grants (microphone, screen recording, speech recognition) by cdhash, so existing users will be re-prompted on first run. U6 verifies the cdhash claim empirically and documents the migration in the README.

---

## Requirements Trace

- R1. New `jwulff/homebrew-steno` repo with single source-built formula `Formula/steno.rb` (origin R1).
- R2. Build dependencies declared correctly: Go (build), Xcode 26+ (build) so Swift 6.2 toolchain resolves (origin R2). The origin doc said `xcode: ["16.0", :build]`, but Xcode 16 ships Swift 6.0, not 6.2 — research-time correction.
- R3. Constrain to arm64 + macOS ≥ `:tahoe` (origin R3).
- R4. Build both `steno` and `steno-daemon`, ad-hoc codesign daemon with `daemon/Resources/StenoDaemon.entitlements`, install both to formula `bin/` (origin R4).
- R5. Working `test do` block exercising `--version` on both binaries (origin R5).
- R6. `service` block runs `#{bin}/steno-daemon run` for `brew services start steno` (origin R6).
- R7. README documents `brew services start steno` and `steno-daemon install` as alternatives — pick one (origin R7).
- R8. Bottle CI: each formula PR builds an arm64 macOS-26 bottle on `runs-on: macos-26`; the `pr-pull` label flow publishes the bottle to the tap repo's GitHub Releases and updates the formula's `bottle do` block (origin R8, scoped down — automation portion of origin R8 deferred).
- R9. Bottle build runs on `runs-on: macos-26` (GitHub-hosted, GA since 2026-02-26 — research confirmed) (origin R9).
- R10. Fix stale `release.yml` in `jwulff/steno`: Swift 6.2 toolchain, `macos-26` runner, correct entitlements path, two-binary tarball, plus produce a reproducible `steno-<version>-source.tar.gz` source tarball as a release asset for the formula's `url` to consume (origin R10, expanded).
- R11. Same formula structurally graduates to `homebrew/core` without rewrite (origin R11).
- R13. Single-source version string: a `VERSION` file at the repo root drives generated `daemon/Sources/StenoDaemon/Version.swift`, `daemon/Resources/Info.plist` (templated from `Info.plist.in`), and `cmd/steno/main.go`'s ldflags-injected `version`. The formula's `version` property mirrors this. (Plan-local; surfaced by document review.)
- R14. Daemon-side detection of competing launchd registrations: `RunCommand.run()` and `InstallCommand.run()` detect when both `~/Library/LaunchAgents/com.steno.daemon.plist` (from `steno-daemon install`) and a brew-managed `homebrew.mxcl.steno.plist` exist (or when the PID file is held by the alternate path) and exit with an explicit `launchctl bootout` recovery message. (Plan-local; surfaced by document review.)

R12 (origin: "track core notability + surface in README") was dropped during document review — it is a maintainer-facing self-note disguised as a user-facing requirement, with no concrete delivery beyond a README footnote that adds no user value.

---

## Scope Boundaries

- Intel Mac support — out of scope per origin; arm64 only.
- macOS releases older than 26 — out of scope per origin (SpeechAnalyzer is hard requirement).
- Submitting to `homebrew/core` — Phase 2, separate effort, not in this plan.
- Removing or deprecating `steno-daemon install` — keep coexisting with `brew services` for now (with daemon-side conflict detection per R14).
- Migrating Steno's existing tarball-download install path away — README adds Homebrew as recommended path; existing path stays.
- A Homebrew Cask — wrong primitive for a CLI; formula is correct.
- README signaling about future homebrew/core graduation — kept private to maintainer notes; no user-facing benefit.

### Deferred to Follow-Up Work

- **Tag-driven formula bump automation** (originally U5): on each Steno release tag, fire `repository_dispatch` to the tap to auto-open a formula bump PR. Phase 1 uses the manual `brew bump-formula-pr` flow (one local command per release). Re-add when release cadence makes manual bumps a friction point. Carries a PAT-trust surface that needs explicit tag-validation before opening the PR — addressed when the unit returns.
- **Phase 2 `homebrew/core` submission**: gated on notability bar. Separate PR against `homebrew/core` whenever criteria are met. Tracked privately in maintainer notes.
- **Deprecating `steno-daemon install`** in favor of `brew services` — separate PR if and when telemetry shows users converging on the brew-services path.
- **Reproducible bottle builds** (byte-identical cdhash across runs) so users don't re-grant TCC on every minor formula bump. Substantial Swift/Go reproducible-build work; out of scope for v1. v1 documents the re-prompt behavior instead.
- **Auto-merging the formula PR** when CI is green and labels match. Manual `pr-pull` gate stays in v1.

---

## Context & Research

### Relevant Code and Patterns

- `Makefile` — current `build-daemon` (`swift build -c release` + `-Xlinker -sectcreate` for embedded `Info.plist`), `sign-daemon` (`codesign --force --sign - --entitlements ...`), `install` (PREFIX = `~/.local/bin`). The formula's `install` block mirrors this sequence. Note the Makefile uses `cd daemon` before `swift build`, which puts the linker's CWD inside `daemon/`; the formula must replicate that exactly (use `cd buildpath/"daemon" do … end`) so `-Xlinker Resources/Info.plist` resolves correctly.
- `daemon/Resources/StenoDaemon.entitlements` — already in source tree, ships in the source tarball, available to the formula at install time.
- `daemon/Resources/Info.plist` — embedded into the daemon binary at link time. Currently hardcodes `CFBundleVersion` and `CFBundleShortVersionString` to `0.1.0`. U1 templates this from `Info.plist.in`.
- `daemon/Sources/StenoDaemon/StenoDaemon.swift` — `@main` struct with `version: "0.1.0"` (stale). swift-argument-parser auto-generates `--version` from this. U1 replaces with `version: stenoDaemonVersion` referenced from a generated `Version.swift`.
- `daemon/Sources/StenoDaemon/Commands/RunCommand.swift` — calls `pidFile.acquire()` and exits non-zero on collision. U7 expands the failure to also check for the alternate launchd plist's presence and print a recovery command.
- `daemon/Sources/StenoDaemon/Commands/InstallCommand.swift` — registers `~/Library/LaunchAgents/com.steno.daemon.plist`. U7 makes this detect a brew-managed plist and refuse to install in that case.
- `cmd/steno/main.go` — defines only `--mcp` flag today; needs `--version` added via `flag.Bool` + early-exit print, and the MCP server's hardcoded `"steno-mcp", "0.1.0"` registration must read from the same `version` package variable.
- `.github/workflows/release.yml` — stale; runs `swift build -c release` from the repo root (no `Package.swift` there — `daemon/Package.swift` is the actual location), signs `.build/release/steno` (no such artifact at root), and produces a single-binary tarball using a tag-templated name that doesn't match the actual `steno-darwin-arm64.tar.gz` asset shipped for v0.3.0. The entitlements file `Resources/Steno.entitlements` referenced at the repo root *does* exist (it's a duplicate of `daemon/Resources/StenoDaemon.entitlements` from before the daemon was split out) — but the workflow's overall logic is broken in multiple ways and U2 rewrites it from scratch.
- `.github/workflows/test.yml` — enforces `[steno-tests-passed: …]` commit attestation on PRs. Any new commits this plan produces must include the attestation trailer to clear CI.
- `CLAUDE.md` — pinning constraints: Swift 6.2+, Go 1.24+, ad-hoc codesign with `disable-library-validation` + `allow-jit`, no `com.apple.developer.speech-recognition` (restricted entitlement), no `swift run` (skips signing).

### Institutional Learnings

- No `docs/solutions/` directory exists. No prior packaging/distribution learnings to consult.

### External References

- Homebrew `MacOSVersion::SYMBOLS` defines `:tahoe` → "26" (Homebrew 5.0.0+, Nov 2025). Use `depends_on macos: ">= :tahoe"`.
- Homebrew Formula Cookbook: depend on Xcode for Swift CLIs (`depends_on xcode: ["26.0", :build]`). Do NOT use the `swift` formula — it builds the open-source toolchain from source and is meant for Linux. NSHipster's "Swift Program Distribution with Homebrew" article documents the canonical pattern.
- Homebrew docs explicitly recommend release-asset tarballs over GitHub's auto-generated `archive/refs/tags/...` URLs because the auto-generated tarballs can have unstable SHA256s when GitHub regenerates its archive backend (documented historical precedent).
- `brew tap-new` generates `Formula/`, `tests.yml`, `publish.yml`. `tests.yml` runs `brew test-bot` on `macos-26` to build bottles on PRs; `publish.yml` is triggered by labeling a PR `pr-pull`, which downloads the bottle artifacts via `brew pr-pull --root-url=…` and publishes them as a GitHub Release on the tap repo, then commits the updated formula to `main`.
- Bottle URL convention with default `root_url`: `https://github.com/jwulff/homebrew-steno/releases/download/steno-<version>/<bottle-tarball>`. Reference tap doing this end-to-end: `mas-cli/homebrew-tap`.
- GitHub-hosted Actions: `runs-on: macos-26` GA since 2026-02-26 → arm64 by default. `macos-latest` does NOT yet point at 26 (still 14/15 in April 2026); pin explicitly.
- Ad-hoc codesigning is content-hash-based (no machine identity) and survives bottling. `cellar: :any_skip_relocation` is correct because binaries don't reference cellar paths. **However**, the cdhash of an ad-hoc-signed binary depends on every byte of the Mach-O including SwiftPM-injected timestamps and toolchain metadata — so two builds of the same source from different machines or runners will have different cdhashes. macOS TCC keys permissions on cdhash; users migrating between builds will be re-prompted (R14 documents this).
- SwiftPM inside Homebrew's superenv build sandbox: pass `--disable-sandbox` to `swift build` (SwiftPM's own sandbox conflicts with brew's), and redirect cache via `ENV["SWIFTPM_CACHE_DIR"] = buildpath/".cache"` so SwiftPM doesn't try to write to `~/Library/Caches`.
- Go inside Homebrew's superenv: set `ENV["GOPATH"] = buildpath/"go"` (otherwise Go tries to write `~/go`, often blocked), `ENV["GOFLAGS"] = "-mod=mod"`, and rely on Homebrew's default network access during build for module fetches. `homebrew/core` accepts Go formulas that fetch modules at build time (e.g., `gh`, `hugo` use this pattern).

---

## Key Technical Decisions

- **Source formula sources from a maintainer-controlled release asset** (`https://github.com/jwulff/steno/releases/download/v#{version}/steno-#{version}-source.tar.gz`), not from GitHub's auto-generated `archive/refs/tags/` URL. This trades a small coupling (U3 now depends on U2) for a stable SHA256 that won't drift if GitHub regenerates archives. U2's expanded scope is to produce that source tarball.
- **Bottles use default `root_url`**, which resolves to `https://github.com/jwulff/homebrew-steno/releases/download/steno-<version>` after `brew pr-pull`. No explicit `root_url` override needed; this also keeps the formula structurally identical when migrating to `homebrew/core`.
- **Bottle CI is worth its cost in Phase 1, independent of Phase 2 graduation.** Source build time is ~5 minutes (Swift release build dominates); bottle install is ~30 seconds. For the personal-tap user who already knows about Steno, that's a real UX delta. Bottle CI also functions as a smoke test that the formula installs cleanly on a fresh runner — catching regressions before users hit them. The infrastructure is set up once; per-release cost is zero (PR open → CI builds → label → publish). Phase 2 graduation is a bonus, not the load-bearing justification.
- **Manual formula bumps for Phase 1**, not automated dispatch. Maintainer cuts a release, runs `brew bump-formula-pr --version=<v> Formula/steno.rb` locally, opens PR, labels `pr-pull` after CI green. Eliminates the originally-planned U5 (repository_dispatch + secondary workflow + PAT secret + duplicate-detection logic). Re-add as a follow-up when release cadence justifies it.
- **`brew services` runs `steno-daemon run` directly** — not via a wrapper. Daemon's existing CLI handles foreground operation correctly (`ParsableCommand` + `dispatchMain()`, per CLAUDE.md). U7 adds the conflict-detection guards.
- **Daemon-side conflict detection over docs-only warning.** Origin treated launchd-conflict as a documentation problem ("pick one"). Document review surfaced that the actual failure mode is a PID-file/launchd crashloop with escalating backoff, invisible to the user. R14/U7 puts the detection in the daemon code so the failure is loud and actionable, not silent.
- **Single-source the version string from a `VERSION` file at the repo root.** Three locations currently drift independently (Swift `CommandConfiguration.version`, Info.plist `CFBundleVersion`/`CFBundleShortVersionString`, Go MCP server's hardcoded `"0.1.0"`). U1 introduces `VERSION`, generates `daemon/Sources/StenoDaemon/Version.swift`, templates `daemon/Resources/Info.plist` from `Info.plist.in`, and injects the Go version via ldflags. Single edit per release, no CI guard needed.
- **Maintain coexistence with `steno-daemon install`** rather than rip it out. Document the trade-off in README; revisit later if `brew services` becomes the dominant path.

---

## Open Questions

### Resolved During Planning

- **macOS 26 Homebrew DSL symbol** → `:tahoe` (verified in Homebrew `MacOSVersion::SYMBOLS`).
- **Swift 6.2 toolchain** → `depends_on xcode: ["26.0", :build]`. Use `swift build --disable-sandbox --arch arm64`. Origin doc said `["16.0", :build]` — incorrect, since Xcode 16 ships Swift 6.0.
- **macOS 26 arm64 GHA runner** → `runs-on: macos-26` is GA. No fallback needed in v1.
- **Bottle CI pattern** → `brew tap-new` template (`tests.yml` + `publish.yml` + `pr-pull` label flow). Default `root_url` resolves to tap GitHub Releases.
- **Codesign in formula install** → standard `system "codesign", "--force", "--sign", "-", "--entitlements", "...", bin/"steno-daemon"`. Sandbox-safe. Bottle marker `cellar: :any_skip_relocation`.
- **Source URL** → release asset (`steno-#{version}-source.tar.gz`), produced by U2.
- **Version single-sourcing** → `VERSION` file → generated Swift + templated Info.plist + Go ldflags.
- **Service block fate** → keep, with daemon-side conflict detection (U7) for safe coexistence with `steno-daemon install`.
- **Tag-driven dispatch automation** → deferred to follow-up; manual `brew bump-formula-pr` for Phase 1.
- **R12 / homebrew/core notability tracking in README** → dropped; no user value.

### Deferred to Implementation

- **Verify Xcode 26.0 ships Swift 6.2** — research flagged as UNVERIFIED. Confirm during U3 by running `xcodebuild -version` on a macOS 26 build runner before tagging the formula's `depends_on xcode:` minimum. If Xcode 26 ships Swift 6.1, raise the constraint accordingly.
- **Verify the bottle URL tag-prefix convention** (`steno-<version>` vs `v<version>`) on first `brew tap-new` + `pr-pull` cycle. Adjust formula or `--root-url` invocation if needed.
- **TCC re-prompt empirical verification**: U6 must run `codesign -d -vvv` on a `make install`-built binary and a formula-built binary at the same source SHA, compare cdhashes, and document the result in README. If they happen to match, the migration warning is unnecessary; if not (likely), document the one-time re-prompt expectation.
- **Gatekeeper quarantine on bottle install**: bottles are downloaded over the network and may pick up `com.apple.quarantine` xattr. U6's clean-account smoke test reveals whether this blocks the daemon. If so, add a `post_install` block to the formula that strips the xattr.
- **`brew bump-formula-pr` against personal tap**: canonical tool, but primarily exercised against `homebrew/core`. Verify it works for `jwulff/homebrew-steno` on first manual bump; fall back to hand-editing the formula or `peter-evans/create-pull-request` if not.

---

## Implementation Units

- [ ] U1. **Single-source version string and add `--version` flag**

**Goal:** Eliminate version-drift across the Swift binary, the embedded Info.plist, and the Go MCP server. Give `steno` a `--version` flag for the formula's `test do` block.

**Requirements:** R5, R13

**Dependencies:** None.

**Files:**
- Create: `VERSION` (repo root, contents: `0.3.1` or whichever version this lands in)
- Create: `daemon/Resources/Info.plist.in` (template; `__VERSION__` placeholder for `CFBundleVersion` + `CFBundleShortVersionString`)
- Modify: `daemon/Resources/Info.plist` — remove from VCS (becomes a build artifact); add to `.gitignore`
- Create: `daemon/Sources/StenoDaemon/Version.swift` — generated; check in a default `let stenoDaemonVersion = "dev"` so the package compiles even before Make runs
- Modify: `Makefile` — new `gen-version` target that reads `VERSION` and rewrites `Version.swift` + `Info.plist`. `build-daemon` and `build-daemon-debug` depend on `gen-version`. `build-steno` passes `-ldflags "-X main.version=$(shell cat VERSION)"`.
- Modify: `daemon/Sources/StenoDaemon/StenoDaemon.swift` — replace `version: "0.1.0"` with `version: stenoDaemonVersion`
- Modify: `cmd/steno/main.go` — add `var version = "dev"` package-level; add `--version` flag handling that prints `steno <version>` and exits 0; replace `server.NewMCPServer("steno-mcp", "0.1.0", ...)` with `server.NewMCPServer("steno-mcp", version, ...)`
- Test: `cmd/steno/main_test.go` (create if absent — verify `--version` precedence over `--mcp`)

**Approach:**
- `VERSION` file is the single source of truth.
- `make gen-version` runs `sed`/`awk` substitution to produce `daemon/Sources/StenoDaemon/Version.swift` (`let stenoDaemonVersion = "<contents>"`) and `daemon/Resources/Info.plist` (substituting `__VERSION__` in `Info.plist.in`).
- Both `Version.swift` and `Info.plist` are git-ignored after this change. Initial check-in includes the generator template files (`Info.plist.in`) and a default `Version.swift` containing `"dev"` so the Swift package compiles in a fresh checkout even before `make` runs.
- `--version` check happens before `--mcp` dispatch in `main.go` so `steno --version --mcp` prints the version and exits without starting either mode.
- The formula's `install` block writes the formula's `version` property to `VERSION` before running `make build`, so Homebrew-driven builds use the formula's version string and `--version` output matches `version.to_s`.

**Patterns to follow:**
- Standard Go CLI version-injection (kubectl, gh).
- Standard SwiftPM "generated source file" pattern (Apple's swift-package-manager itself uses this for build-time version constants).
- Existing `flag.Bool` style in `cmd/steno/main.go`.

**Test scenarios:**
- Happy path: `steno --version` prints `steno <version>` and exits 0 without starting TUI/MCP.
- Happy path: `steno-daemon --version` prints `steno-daemon <version>` (auto-generated by swift-argument-parser from `Version.swift`).
- Happy path: bumping `VERSION` to `0.4.0`, running `make gen-version`, then `make build-daemon` produces a binary whose `--version` reports `0.4.0` and whose embedded Info.plist reports `CFBundleVersion = 0.4.0`.
- Edge case: `steno --version --mcp` — `--version` short-circuits and exits before MCP server starts.
- Edge case: clean checkout, no `make gen-version` run yet — `swift build` and `go build` still succeed (using the checked-in `Version.swift` default `"dev"` and Go's default `var version = "dev"`).
- Integration: an MCP client connecting to `steno --mcp` after `make gen-version` sees the correct version in the server's `initialize` handshake.

**Verification:**
- `cat VERSION; make build` produces both binaries reporting the same `--version` string.
- `mdls daemon/.build/release/steno-daemon` (or `plutil -extract CFBundleVersion …`) reports the same string.
- `git status` shows `Version.swift` and `Info.plist` as untracked (correctly gitignored).

---

- [ ] U2. **Fix `release.yml` and produce reproducible source tarball**

**Goal:** Make Steno's existing release pipeline produce a correct, two-binary `steno-darwin-arm64.tar.gz` PLUS a reproducible source tarball `steno-<version>-source.tar.gz` that the formula will source from. Closes R10.

**Requirements:** R10

**Dependencies:** U1 (so the release tarball ships binaries with version-flag support and `VERSION`-driven build is in place).

**Files:**
- Modify: `.github/workflows/release.yml`

**Approach:**
- Switch runner to `runs-on: macos-26` (arm64 by default). Existing workflow uses `macos-15`.
- Drop `swift-actions/setup-swift` dependency. Use the system Swift on macos-26 (Xcode 26 preinstalled). Verify with a `swift --version` step early in the job; fail fast if 6.2 isn't present.
- Build BOTH binaries via `make build` (which now invokes `make gen-version` first per U1).
- Sign daemon: ad-hoc with the entitlements file at `daemon/Resources/StenoDaemon.entitlements`.
- Binary tarball: `tar -czf steno-darwin-arm64.tar.gz -C <release-dir> steno steno-daemon` (two binaries, fixed asset name).
- Source tarball: produce a clean, reproducible `steno-${tag}-source.tar.gz` containing the repo at the tagged commit (use `git archive` for determinism: `git archive --format=tar.gz --prefix=steno-${tag}/ ${tag} > steno-${tag}-source.tar.gz`).
- SHA256 sidecars for both tarballs.
- Upload all four assets to the GitHub Release.

**Execution note:** The current `release.yml` references `Resources/Steno.entitlements` which exists at the repo root as a leftover from before the daemon was split out — but the workflow's logic is broken in other ways (`swift build` from repo root has no `Package.swift`, signs `.build/release/steno` which doesn't exist there, etc.). Read the file fresh and rewrite from scratch rather than patching individual lines.

**Patterns to follow:**
- Existing `Makefile` `build` and `sign-daemon` targets — the workflow is a thin CI wrapper around `make`.
- Existing `.github/workflows/test.yml` for action versions.
- `git archive` is the canonical reproducible-source-tarball tool.

**Test scenarios:**
- Integration: cut a throwaway pre-release tag (e.g., `v0.3.1-rc1`) on a feature branch; observe the workflow produces both `steno-darwin-arm64.tar.gz` (two binaries) AND `steno-v0.3.1-rc1-source.tar.gz` (full source tree) on the GitHub Release.
- Verification: `codesign -d --entitlements - <daemon-bin>` on the extracted binary shows `disable-library-validation` and `allow-jit`.
- Verification: extracted `steno --version` prints the tag name (proving `VERSION`-driven build worked).
- Verification: SHA256 sidecars match their tarballs.
- Verification: the source tarball, extracted and built locally with `make build`, produces working binaries (round-trip integrity).
- Edge case: re-tagging the same version → workflow either skips or overwrites cleanly; no leftover artifacts breaking subsequent tags.

**Verification:**
- A tagged release lands four assets (binary tarball + sha256, source tarball + sha256), all valid.

---

- [ ] U3. **Bootstrap `jwulff/homebrew-steno` tap and write source formula**

**Goal:** Stand up the new tap repo and ship a working `Formula/steno.rb` that builds Steno from source on macOS 26 arm64, sources from U2's source tarball, and passes `brew audit --strict --new-formula`.

**Requirements:** R1, R2, R3, R4, R5, R6, R11

**Dependencies:** U1 (formula's `test do` calls `--version` and writes `version.to_s` into `VERSION` before `make build`), U2 (formula sources from the release-asset source tarball), U7 (daemon's launchd conflict detection must be in place before the formula ships a `service` block).

**Files:**
- Create new repo `jwulff/homebrew-steno` (separate from this repo).
- Create: `Formula/steno.rb` (in the tap repo)
- Create: `README.md` (in the tap repo)

**Approach:**
- `brew tap-new jwulff/steno --no-git` locally to scaffold the standard tap structure, or generate manually following the cookbook.
- Initialize as a public GitHub repo at `https://github.com/jwulff/homebrew-steno`.
- Write `Formula/steno.rb`:
  - `desc`, `homepage` (`https://github.com/jwulff/steno`), `license "MIT"`.
  - `url "https://github.com/jwulff/steno/releases/download/v#{version}/steno-#{version}-source.tar.gz"` with concrete version + sha256 for the first formula-tracked release.
  - `depends_on macos: ">= :tahoe"`, `depends_on arch: :arm64`.
  - `depends_on xcode: ["26.0", :build]`, `depends_on "go" => :build`.
  - `install` block:
    - `(buildpath/"VERSION").write(version.to_s)` so the Make-driven build uses the formula's version.
    - `ENV["SWIFTPM_CACHE_DIR"] = buildpath/".cache"`, `ENV["GOPATH"] = buildpath/"go"`, `ENV["GOFLAGS"] = "-mod=mod"`.
    - Build the daemon with the linker's CWD inside `daemon/` so `Info.plist` resolves correctly:
      ```ruby
      cd buildpath/"daemon" do
        system "swift", "build", "-c", "release", "--disable-sandbox", "--arch", "arm64",
               "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
               "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"
      end
      ```
    - Build the Go binary: `cd buildpath/"cmd/steno" do; system "go", "build", "-ldflags", "-X main.version=#{version}", "-o", "steno", "."; end`
    - Install: `bin.install buildpath/"daemon/.build/release/steno-daemon"` and `bin.install buildpath/"cmd/steno/steno"`.
    - Codesign: `system "codesign", "--force", "--sign", "-", "--entitlements", buildpath/"daemon/Resources/StenoDaemon.entitlements", bin/"steno-daemon"`.
  - `service` block: `run [opt_bin/"steno-daemon", "run"]`, `keep_alive true`, `log_path` and `error_log_path` to `var/"log/steno-daemon.log"`.
  - `test do` block: `assert_match version.to_s, shell_output("#{bin}/steno --version")` and same for `steno-daemon`.
  - `bottle do` block: empty initially; populated by `brew pr-pull` once U4 lands the bottle CI.

**Execution note:** Run `brew audit --strict --new-formula --online jwulff/steno/steno` before pushing. Iterate until clean.

**Patterns to follow:**
- `mas-cli/homebrew-tap`'s `mas.rb` (Swift CLI tap with bottles).
- Homebrew Formula Cookbook for service blocks and `bin.install`.
- Existing Go-CLI formulas in homebrew/core (`gh`, `hugo`) for the Go env-var pattern.

**Test scenarios:**
- Happy path: on macOS 26 arm64 with Xcode 26 + Go installed, `brew install --build-from-source jwulff/steno/steno` succeeds end-to-end in <5 min.
- Happy path: post-install, `which steno` and `which steno-daemon` both resolve to `/opt/homebrew/bin/`.
- Happy path: `steno --version` and `steno-daemon --version` both print expected output matching `version.to_s`.
- Happy path: `brew test jwulff/steno/steno` exits 0.
- Happy path: `brew audit --strict --new-formula --online jwulff/steno/steno` exits clean.
- Edge case: install on macOS 25 → fails with explicit "requires macOS 26" message (proving `depends_on macos:` works).
- Edge case: install on Intel Mac → fails with "requires arm64" message.
- Integration: `brew services start steno` registers a launchd plist; `brew services list` shows `steno` as running; `pgrep -f steno-daemon` finds the process.
- Integration: `brew services stop steno` deregisters and stops the daemon.
- Integration: `codesign -d --entitlements - $(brew --prefix)/bin/steno-daemon` shows `disable-library-validation` and `allow-jit`.
- Integration: `mdls $(brew --prefix)/bin/steno-daemon` reports `CFBundleVersion` matching `version.to_s` (proves Info.plist embedding worked).
- Edge case: bottle install (after U4 lands) on a fresh user account — daemon launches without Gatekeeper blocking. If blocked, U6 adds a `post_install` quarantine-strip step.

**Verification:**
- `brew install` from a fresh user account (no Steno previously installed) produces a working install.
- TUI launches via `steno`; recording starts via spacebar; transcript appears (full smoke per CLAUDE.md "verify the build artifacts").

---

- [ ] U4. **Add bottle CI to the tap repo**

**Goal:** Standard `brew tap-new` bottle pipeline — PRs against the tap trigger bottle build on `macos-26`; labeling a PR `pr-pull` publishes the bottle to the tap's GitHub Releases and updates the formula's `bottle do` block.

**Requirements:** R8, R9

**Dependencies:** U3 (formula must exist).

**Files (in tap repo):**
- Create: `.github/workflows/tests.yml` (from `brew tap-new` template, pinned to `runs-on: macos-26`)
- Create: `.github/workflows/publish.yml` (from `brew tap-new` template)
- Modify: tap-level `README.md` — install + manual-bump instructions

**Approach:**
- Copy `tests.yml` and `publish.yml` directly from what `brew tap-new` emits. Customize `tests.yml`: pin `runs-on: macos-26`, skip Linux/Intel matrix entries (per scope: arm64 only). Leave `publish.yml` as-generated.
- Configure a Homebrew GitHub token (PAT with `repo` scope on the tap repo) as a GitHub Secret in the tap repo for `publish.yml` to upload bottles and push the formula update.
- Document in the tap README the manual bump procedure: "to bump the formula, run `brew bump-formula-pr --version=<new> Formula/steno.rb` locally, push the resulting branch, open a PR, wait for `tests.yml` green, label `pr-pull`, `publish.yml` does the rest."

**Patterns to follow:**
- Output of `brew tap-new <user>/<tap>` on a clean macOS 26 box (gold-standard template).
- `mas-cli/homebrew-tap` workflow files (note: predates macos-26 GA; treat as structural reference, not literal copy).

**Test scenarios:**
- Integration: open a no-op PR against the tap (e.g., README typo). `tests.yml` runs on `macos-26`; `brew test-bot` builds a bottle artifact; CI exits green.
- Integration: label the same PR `pr-pull`. `publish.yml` downloads the bottle, creates/updates a `steno-<version>` GitHub Release on the tap repo, uploads the `.tar.gz` bottle as an asset, commits the updated formula's `bottle do` block to `main`, and merges the PR.
- Integration: on a fresh user machine, `brew install jwulff/steno/steno` resolves to a bottle (no `swift build`), completes in <30s, and produces working binaries.
- Edge case: `brew install --build-from-source jwulff/steno/steno` still works (source path didn't break).
- Edge case: PR with broken formula (failing `brew test`) — `tests.yml` fails, `pr-pull` label has no effect because publish workflow gates on green CI.
- Verification: `brew info jwulff/steno/steno` shows the bottle line.

**Verification:**
- Bottle install path is the default for fresh users; source build is the explicit opt-in.

---

<!-- U5 (originally: tag-driven formula bump dispatch from jwulff/steno to the tap)
     was scoped out during document review. Phase 1 uses manual `brew bump-formula-pr`.
     Tracked under "Deferred to Follow-Up Work" above. U-ID gap intentional. -->

---

- [ ] U6. **End-to-end smoke test, README update, and TCC migration documentation**

**Goal:** Validate the entire pipeline by cutting an actual release through the new path. Update the Steno README to make `brew install jwulff/steno/steno` the recommended install. Document the TCC permission re-prompt that migrating users will hit. Verify Gatekeeper quarantine doesn't block bottle installs.

**Requirements:** R7, plus integration verification of all preceding units.

**Dependencies:** U1, U2, U3, U4, U7.

**Files:**
- Modify: `README.md` (in `jwulff/steno`)
- Modify: tap `README.md` (in `jwulff/homebrew-steno`) — final polish if needed
- Possibly modify: `Formula/steno.rb` (in tap) — add `post_install` quarantine-strip if U6's smoke test reveals Gatekeeper blocks the daemon

**Approach:**

1. **Cut a real release through the new path.** Bump `VERSION` to v0.3.1, run `make gen-version`, commit, tag, push. `release.yml` builds + uploads source tarball + binary tarball as release assets.

2. **Manual formula bump.** From a local clone of `jwulff/homebrew-steno`: `brew bump-formula-pr --version=0.3.1 --url=https://github.com/jwulff/steno/releases/download/v0.3.1/steno-0.3.1-source.tar.gz Formula/steno.rb`. Push branch, open PR.

3. **Bottle CI flow.** Tap's `tests.yml` runs, builds bottle, uploads as artifact. Apply `pr-pull` label. `publish.yml` uploads bottle to tap GH release, commits formula update, merges.

4. **Clean-account smoke test.** On a fresh macOS 26 arm64 user account (no Steno installed, no `~/Library/LaunchAgents/com.steno.daemon.plist`), run `brew tap jwulff/steno && brew install steno`. Time it; confirm bottle hit (no source build).

5. **Gatekeeper quarantine check.** After install, run `xattr -l $(brew --prefix)/bin/steno-daemon`. If `com.apple.quarantine` is present and `steno-daemon run` is blocked by Gatekeeper, add a `post_install` block to the formula:
   ```ruby
   def post_install
     system "xattr", "-d", "-r", "com.apple.quarantine", bin/"steno-daemon"
   end
   ```
   Re-bump the formula and re-test.

6. **Service block check.** `brew services start steno` produces a working daemon. `steno` TUI connects to it. Recording succeeds. `brew services stop steno` cleanly tears down.

7. **TCC cdhash verification.** Build via `make install` and via the formula on the same source SHA. Run `codesign -d -vvv $(brew --prefix)/bin/steno-daemon 2>&1 | grep "CDHash"` and the equivalent on `~/.local/bin/steno-daemon`. Compare. Document the result.

8. **U7 conflict-detection regression test.** With `steno-daemon install` already active, `brew services start steno` should produce a clean error from the daemon-side guard, not a launchd crashloop. Reverse: with `brew services start steno` active, `steno-daemon install` should refuse with an explicit message.

9. **Update Steno's `README.md`:**
   - "Install" section gets a new top option: "via Homebrew (recommended)".
   - Existing tarball-download and `make install` paths demoted but kept.
   - **New "Migrating from `make install`" subsection** — if step 7 confirmed cdhashes differ, document: "On first launch via `brew install`, macOS will re-prompt for microphone, screen recording, and speech recognition permissions. This is because the Homebrew-built and source-built daemon binaries have different cdhashes; macOS keys TCC permissions on cdhash. Grant the prompts; subsequent launches use the brew-built binary's cached grants."
   - Daemon autostart guidance: "Pick one — `brew services start steno` (Homebrew-managed) OR `steno-daemon install` (built-in launchd registration). Running both will be detected and refused at command time (R14). If you've already used one, undo it before switching: `brew services stop steno` or `steno-daemon uninstall`."

**Patterns to follow:**
- Existing README structure (Install → Usage → How It Works → Architecture).

**Test scenarios:**
- Integration (the full end-to-end scenario): cut a release through the new pipeline; manual formula PR; bottle build; label; publish; install on fresh account. End-to-end success without unforeseen manual intervention.
- Integration: timed `brew install jwulff/steno/steno` on a fresh user account is <30s (bottle hit).
- Integration: `brew services start steno` produces a working daemon; `steno` TUI connects; recording succeeds.
- Integration: `brew uninstall steno` removes both binaries and the brew-managed launchd plist (if `brew services start` ran).
- Integration: TCC re-prompt scenario — install via `make install` first, grant permissions, record; then install via brew, observe whether re-prompts appear. Document result.
- Edge case: a user who previously ran `steno-daemon install` then runs `brew services start steno` — observed behavior is the U7 guard's actionable error, not crashloop.
- Edge case: bottle install on a user account that has never granted TCC permissions — first launch produces standard system prompts, not silent denial (proves Info.plist embedding worked through the bottle pipeline).
- Verification: README install instructions are accurate; copy-paste from a clean shell works on a fresh macOS 26 install.

**Verification:**
- A first-time user with macOS 26 + Homebrew installed can go from "I want Steno" to "I'm transcribing audio" in under 2 minutes (excluding the one-time TCC permission grants, which require a system-settings round-trip).
- A migrating user (previously on `make install`) understands and accepts the one-time re-prompt cycle from the README's Migrating section.

---

- [ ] U7. **Daemon-side launchd conflict detection**

**Goal:** Make the `brew services` ↔ `steno-daemon install` overlap a loud, actionable failure rather than a silent PID-file crashloop. Daemon detects competing launchd registrations and refuses with a recovery command.

**Requirements:** R14

**Dependencies:** U1 (modifies the same `RunCommand.swift` and `InstallCommand.swift` files; sequence matters for clean diffs but no logical dependency).

**Files:**
- Modify: `daemon/Sources/StenoDaemon/Commands/RunCommand.swift`
- Modify: `daemon/Sources/StenoDaemon/Commands/InstallCommand.swift`
- Test: `daemon/Tests/StenoDaemonTests/Commands/RunCommandTests.swift` (and `InstallCommandTests.swift` if present)

**Approach:**
- Define a small `LaunchdRegistry` helper (in `daemon/Sources/StenoDaemon/Infrastructure/`) that knows the two well-known plist locations:
  - `steno-daemon install` writes to `~/Library/LaunchAgents/com.steno.daemon.plist`
  - `brew services start steno` writes to `~/Library/LaunchAgents/homebrew.mxcl.steno.plist` (verify exact label by inspecting a real `brew services start` output)
- The helper exposes `hasUserManagedPlist() -> Bool` and `hasBrewManagedPlist() -> Bool` — pure file-existence checks.
- `RunCommand.run()`: after `pidFile.acquire()` fails, before exiting non-zero, log an explicit message:
  > "steno-daemon: another instance is running. Active launchd registrations: [list]. To recover: `brew services stop steno` AND/OR `steno-daemon uninstall`, then retry."
- `InstallCommand.run()`: at start, if `hasBrewManagedPlist()`, refuse:
  > "steno-daemon install: a brew-managed launchd plist exists at ~/Library/LaunchAgents/homebrew.mxcl.steno.plist. Run `brew services stop steno` first, OR keep the brew-managed registration (recommended if installed via Homebrew). Aborting."
- The brew-managed plist's exact filename should be verified — `brew services start steno` produces a specific label format; the helper can also fall back to scanning the directory for any plist whose `BundleProgram` or `ProgramArguments[0]` resolves to `bin/steno-daemon`.
- `brew services stop steno` removes `homebrew.mxcl.steno.plist`; `steno-daemon uninstall` removes `com.steno.daemon.plist`. Recovery commands are accurate.

**Execution note:** Start with a failing test that asserts `RunCommand.run()` produces the expected error message when both plists exist. Then implement the detection. Characterization-first because the existing `RunCommand.run()` failure path is the surface being modified.

**Patterns to follow:**
- Existing `InstallCommand`/`UninstallCommand` patterns for plist path resolution.
- Existing `pidFile.acquire()` failure handling style.
- Swift Testing framework conventions (per CLAUDE.md).

**Test scenarios:**
- Happy path: no competing plists exist → `RunCommand.run()` and `InstallCommand.run()` behave as today.
- Edge case: only `~/Library/LaunchAgents/com.steno.daemon.plist` exists → `RunCommand.run()` works (it's expected to be running daemon under launchd); `InstallCommand.run()` reports "already installed."
- Edge case: only `homebrew.mxcl.steno.plist` exists → `RunCommand.run()` works (running under brew services); `InstallCommand.run()` refuses with the "brew-managed plist exists" message.
- Edge case: BOTH plists exist → `RunCommand.run()` checks for crashloop indicators (PID file held), prints the recovery message, and exits non-zero with explicit guidance, NOT a generic "PID already exists." `InstallCommand.run()` refuses identically.
- Edge case: launchd plist file exists but is malformed (e.g., empty file from a bad uninstall) → helper treats absence and corruption identically; recovery message guides the user.
- Integration: with brew-services active, `steno-daemon install` exits non-zero in <100ms with the actionable error; the user can pipe the message into a script.

**Verification:**
- `RunCommand.run()` and `InstallCommand.run()` print actionable, copy-paste-ready recovery commands on conflict.
- No silent crashloop — user sees one error, not 200 launchd backoff log lines.

---

## System-Wide Impact

- **Interaction graph:** Two new external surfaces — `brew install`/`brew services` integration and the formula's `service` block — plus the existing `steno-daemon install` launchd path, now mediated by U7's conflict detection. The interactions to watch: (1) bottle install vs source build (formula `install` block semantics must produce identical results); (2) `brew services` vs `steno-daemon install` (mediated by U7 — daemon detects conflict and refuses, no silent failure).
- **Error propagation:** `RunCommand` and `InstallCommand` failures from U7 must produce stderr output suitable for piping into recovery scripts. Bottle CI failures in U4 must block the `pr-pull` label being effective.
- **State lifecycle risks:** A bottle published with a stale `bottle do` block (wrong sha256) is the worst-case state — `brew install` would fail for users until corrected. Mitigation: `brew pr-pull` automates the sha256 update, and `tests.yml` PR-build proves the bottle is good before label-trigger.
- **API surface parity:** No changes to the daemon NDJSON protocol or SQLite schema. The `--version` flag added in U1 is a new CLI surface but additive. U7 adds new error messages on failure paths but doesn't change existing happy-path behavior.
- **Integration coverage:** Unit tests of `--version` flags (U1), `brew audit` lint (U3), and `LaunchdRegistry` mocked-fs tests (U7) don't prove the end-to-end install works. U6's manual smoke test on a clean user account is the only path that validates the full chain — including the TCC re-prompt and Gatekeeper quarantine question.
- **Unchanged invariants:** Daemon protocol (NDJSON commands/events), socket location (`~/Library/Application Support/Steno/steno.sock`), SQLite schema, MCP tool surface. The `make install` and tarball-download install paths continue to work as alternatives.
- **TCC permission lifecycle:** Documented in U6. macOS keys permissions on cdhash; brew-built and `make install`-built binaries have different cdhashes; users migrating between paths will be re-prompted once.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Xcode 26 doesn't actually ship Swift 6.2 (research flagged UNVERIFIED) | Verify on first U3 build attempt with `xcodebuild -version`; raise the `depends_on xcode:` minimum if Swift 6.1 is what ships. Worst case: pin to a future Xcode minimum once Swift 6.2 lands. |
| Homebrew build sandbox interacts badly with `swift build` despite `--disable-sandbox` | Already cached `SWIFTPM_CACHE_DIR` redirect; if issues persist, fall back to `system "make", "build-daemon"` invocation that uses the existing Makefile (less Homebrew-idiomatic but works). |
| Go module fetch fails in CI's restricted network | Already addressed by `GOPATH = buildpath/"go"` + `GOFLAGS = "-mod=mod"`. Reference `gh`/`hugo` formulas in homebrew/core for Go-CLI patterns. If proxy access is blocked on a self-hosted runner, vendor with `go mod vendor` as a follow-up. |
| `codesign --entitlements` fails inside formula install | Move the codesign step to `post_install` block instead of `install`; or pre-sign the daemon as a build artifact and include it as a `resource`. Lowest-risk fallback exists. |
| TCC re-prompt on `make install` → `brew install` migration is more disruptive than expected | U6 documents the migration explicitly. Reproducible-build work to make cdhashes byte-identical is deferred to follow-up. Users get the prompts once and grant; future bottle versions may also re-prompt (also documented). |
| `brew services start steno` and `steno-daemon install` register competing launchd jobs | Addressed by U7's daemon-side detection — `RunCommand` and `InstallCommand` refuse with actionable recovery messages instead of silent crashloop. |
| Gatekeeper quarantine on bottle install blocks daemon launch | U6 verifies on clean account; if blocked, formula adds `post_install` quarantine-strip. |
| GitHub-hosted `macos-26` runner image is paused or regressed | Origin question; v1 trusts the runner. Fallback (deferred): self-hosted runner on a maintainer Mac, or manual bottle production via `brew test-bot` from a developer machine. Document the manual command sequence if needed. |
| `brew bump-formula-pr` doesn't work cleanly against personal taps | Verify on first manual bump. Fallback: hand-edit `version` + `sha256` in the formula and open the PR via `gh pr create`. Both paths produce identical PRs. |
| First release through the new pipeline corrupts the bottle | The `pr-pull` manual label gate is the safety check — maintainer reviews CI green status before publishing. Worst-case rollback: delete the bad GitHub Release and re-run the bump. |
| `homebrew/core` graduation rejected later due to entitlements requirement | Phase 2 risk only; resolved when we get there. CLAUDE.md asserts the entitlements are required — if core maintainers disagree, that's a product conversation, not a packaging fix. |
| Reproducible bottles require byte-identical builds | Deferred. v1 accepts that minor formula bumps will trigger fresh TCC prompts. Documented in U6's README section. |

---

## Documentation / Operational Notes

- README install order updated: Homebrew first, tarball second, `make install` third.
- README adds a "Migrating from `make install`" subsection documenting the one-time TCC re-prompt.
- README's daemon-autostart guidance points at U7's conflict detection: "you can't accidentally enable both."
- Tap README provides bump-PR instructions for the maintainer (label flow, secret rotation policy if applicable).
- `VERSION` file at the repo root is the single bump point per release. CLAUDE.md deployment checklist gets a one-line update: "before tagging, edit `VERSION` and run `make gen-version`."
- Phase 2 (homebrew/core) is its own future project — not in this plan, but the formula structure here is meant to graduate cleanly. Notability progress is tracked privately; no user-facing README content about it.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-04-29-homebrew-distribution-requirements.md`
- **Document review (2026-04-29):** 5 reviewers (coherence, feasibility, product-lens, scope-guardian, adversarial), 14 findings synthesized; substantive restructuring applied (drop U5, add U7, add R13/R14, expand U1/U2/U6).
- Homebrew `MacOSVersion::SYMBOLS`: `Library/Homebrew/macos_version.rb` in `Homebrew/brew`.
- "How to Create and Maintain a Tap" — Homebrew Docs.
- "Homebrew tap with bottles uploaded to GitHub Releases" — brew.sh blog (2020-11-18, still current pattern).
- NSHipster: "Swift Program Distribution with Homebrew".
- `mas-cli/homebrew-tap` — reference Swift-CLI personal tap with bottle CI.
- GitHub Actions changelog 2026-02-26 — macos-26 GA.
- Local: `Makefile`, `daemon/Resources/StenoDaemon.entitlements`, `daemon/Resources/Info.plist`, `daemon/Sources/StenoDaemon/StenoDaemon.swift`, `daemon/Sources/StenoDaemon/Commands/{Run,Install,Uninstall,Status}Command.swift`, `cmd/steno/main.go`, `.github/workflows/release.yml`, `CLAUDE.md`.
