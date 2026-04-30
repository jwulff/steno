---
date: 2026-04-29
topic: homebrew-distribution
---

# Homebrew Distribution

## Problem Frame

Today, installing Steno requires either downloading a tarball from GitHub Releases and manually moving binaries into `~/.local/bin`, or cloning the repo and running `make install` (which needs Swift 6.2 + Go 1.24 toolchains). Both paths have friction: the tarball flow is uncommon for CLI tools on macOS, and source build is slow. Mac developers expect `brew install <tool>` as the default install path.

We want Steno to be installable via Homebrew with two end states:
1. **Phase 1 (now)**: a personal tap at `jwulff/homebrew-steno` for users who already know about Steno. `brew tap jwulff/steno && brew install steno` should work.
2. **Phase 2 (later)**: graduate the same formula to `homebrew/core` once Steno has enough traction to clear core's notability bar, so `brew install steno` works without a tap.

The phasing matters because it forces Phase 1 to use patterns compatible with `homebrew/core` — specifically, source-built formula with bottles — to avoid rewriting later.

---

## Requirements

**Tap and formula**
- R1. Create a new public GitHub repo `jwulff/homebrew-steno` containing a single formula `Formula/steno.rb` that builds Steno from source.
- R2. The formula must depend on the Go toolchain at build time (`depends_on "go" => :build`) and on a Swift toolchain capable of building `daemon/Package.swift` (Swift 6.2+). Express via `depends_on xcode: ["16.0", :build]` or equivalent constraint that resolves on macOS 26.
- R3. The formula must constrain to Apple Silicon (`depends_on arch: :arm64`) and to macOS 26 or later (`depends_on macos: ">= :tahoe"` or whichever symbol Homebrew uses for macOS 26 — verify during planning).
- R4. The formula must build both binaries (`steno` from `cmd/steno`, `steno-daemon` from `daemon`), ad-hoc codesign the daemon with the entitlements file at `daemon/Resources/StenoDaemon.entitlements`, and install both to the formula's `bin/`.
- R5. The formula must include a working test block (`test do`) that at minimum verifies both binaries are executable and report a version (e.g., `steno --version`, `steno-daemon --version`) — add `--version` flags if they don't yet exist.

**Service integration**
- R6. The formula must declare a `service` block that runs `#{bin}/steno-daemon run` so users can opt into autostart via `brew services start steno`.
- R7. Document in the README that `brew services start steno` and `steno-daemon install` are alternative paths for autostart; users should pick one to avoid duplicate launchd registrations.

**Bottles and release CI**
- R8. Add a GitHub Actions workflow in `jwulff/homebrew-steno` that, on each new release tag of `jwulff/steno`, builds an arm64 macOS-26 bottle, uploads it as a GitHub Release asset on the tap repo, and opens a PR against the tap to update the formula's `bottle do` block.
- R9. The bottle build must run on a runner that natively matches the bottle's target (macOS 26 arm64). If GitHub-hosted runners do not yet provide a macOS 26 arm64 image, document the gap in `Outstanding Questions` and plan a fallback (self-hosted runner, manual bottle production, or temporarily ship without bottles).
- R10. Stale `release.yml` in `jwulff/steno` must be fixed before bottle CI is wired up: align Swift version (6.2), runner image (macOS 26), entitlements path (`daemon/Resources/StenoDaemon.entitlements`), tarball naming (`steno-darwin-arm64.tar.gz`), and ensure both binaries are included.

**Migration to homebrew/core (Phase 2 readiness)**
- R11. The Phase 1 formula must be writable into `homebrew/core` without structural rewrite — i.e., source build with bottles, no binary-only download, no shell-out hacks that core would reject.
- R12. Track the `homebrew/core` notability requirements (currently ≥75 stars, stable releases, no version conflicts, license compatibility) and surface in the README when Phase 2 submission becomes worth attempting. MIT license already satisfies the license requirement.

---

## Success Criteria

- A macOS 26 user with Homebrew installed can run `brew tap jwulff/steno && brew install steno` and end up with working `steno` and `steno-daemon` binaries on `PATH` in under 30 seconds (bottle hit) or under 5 minutes (source build fallback).
- `brew services start steno` registers a working launchd job that auto-starts the daemon on login.
- Cutting a new release tag in `jwulff/steno` results in an updated formula and a new bottle within one CI run, with no manual editing of `Formula/steno.rb`.
- The formula is structurally a candidate for `homebrew/core` submission whenever notability criteria are met — no rewrite required.

---

## Scope Boundaries

- Intel Mac support (x86_64). macOS 26 is Apple-Silicon-dominant and SpeechAnalyzer is performance-tuned for arm64. Revisit only with concrete user demand.
- macOS releases older than 26. SpeechAnalyzer is a hard requirement.
- Migrating Steno's own existing install path (`make install`, README tarball flow) away from `~/.local/bin`. Both paths can coexist with Homebrew.
- Submitting to `homebrew/core` in this phase. Core submission is a separate, later effort gated on notability and on Phase 1 stability.
- Removing or deprecating `steno-daemon install`. Document the alternative; consolidate later if `brew services` becomes the dominant path.
- Migrating release artifacts away from GitHub Releases. The existing release pipeline stays; we add bottle production alongside it.
- A Homebrew Cask. Steno is a CLI, not an app bundle, so a formula is the correct primitive.

---

## Key Decisions

- **Custom tap first, core later.** Phase 1 (custom tap) ships in days; Phase 2 (core) is gated on notability. Two-phase keeps near-term work small without burning the long-term path.
- **Source formula with bottles, not binary-only.** `homebrew/core` forbids binary-only formulas. Building source-with-bottles in Phase 1 avoids the rewrite cost when migrating to core.
- **arm64 only.** macOS 26 is Apple-Silicon-dominant. Adding x86_64 support doubles release CI surface for unknown user demand.
- **Tap repo named `jwulff/homebrew-steno`.** Single-tool tap matches "this tap is for Steno" intent. If other tools later need Homebrew distribution, they get their own taps; rename to a general `jwulff/homebrew-tap` only if/when that pressure appears.
- **Include `service` block.** `brew services start steno` is the discoverable Homebrew idiom. Cheap to ship; coexists with `steno-daemon install` for now.
- **MIT license is already core-compatible.** No license change needed for Phase 2.

---

## Dependencies / Assumptions

- macOS 26 GitHub-hosted runners exist for arm64 by the time bottle CI is wired up. If not, fall back to self-hosted (your own Mac) or skip bottles temporarily.
- Swift 6.2 is available in the Xcode toolchain that Homebrew can resolve via `depends_on xcode:`. Plausible since macOS 26's system Xcode ships Swift 6.2, but verify the `depends_on` syntax during planning.
- Ad-hoc codesigning with the existing entitlements file (`daemon/Resources/StenoDaemon.entitlements`) survives Homebrew's install sandbox and works on the user's machine without re-signing. Worth confirming with a real install during planning.
- The existing release pipeline can be cleaned up without breaking v0.3.0's already-published assets. The fix is forward-only.
- `homebrew/core` notability criteria stay roughly as they are today (~75 stars + stable releases + no version conflicts).

---

## Outstanding Questions

### Resolve Before Planning

(none)

### Deferred to Planning

- [Affects R3][Needs research] What is the exact Homebrew DSL symbol for macOS 26 (`:tahoe`? `:sequoia15`? something else)? Verify against current Homebrew/brew constants.
- [Affects R2][Needs research] Does `depends_on xcode:` with a minimum version reliably ensure Swift 6.2 is available on macOS 26 build machines, or should we instead use a `swift` formula or pin via `ENV` setup?
- [Affects R8, R9][Technical] Does GitHub-hosted Actions provide macOS 26 arm64 runners by the planning date? If not, what's the bottle-production fallback (self-hosted runner on your Mac, manual bottle uploads, or temporarily ship source-only)?
- [Affects R6, R7][Technical] If both `brew services start steno` and `steno-daemon install` register launchd jobs simultaneously, what's the failure mode? Document in install guidance, and consider whether `steno-daemon install` should detect and warn.
- [Affects R5][Technical] `steno` and `steno-daemon` may not currently support `--version`. If not, add minimal version flags as part of the implementation so the formula's `test do` block has something to assert.
- [Affects R4][Technical] Does Homebrew's build sandbox interact poorly with `codesign --entitlements`? If so, what's the workaround (deferred sign step, post-install hook, etc.)?

---

## Next Steps

-> /ce-plan for structured implementation planning
