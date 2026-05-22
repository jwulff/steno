# Release pipeline for v0.4.0 + Homebrew formula

## Why

Two unrelated-but-paired pieces of breakage were blocking a v0.4.0 cut:

1. **The release workflow at `.github/workflows/release.yml` had not
   been updated since the single-binary refactor.** It still ran
   `swift build -c release` from the repo root (`Package.swift` lives
   at `daemon/Package.swift` now), referenced
   `Resources/Steno.entitlements` (moved to
   `daemon/Resources/StenoDaemon.entitlements`), and never touched the
   Go `cmd/steno` binary at all. Cutting v0.4.0 today would have
   either crashed CI or shipped a single broken artifact.

2. **There was no `steno.rb` formula in `jwulff/homebrew-tap`.** The
   sibling project `dictamac.rb` lives there as a reference, but
   Steno's two-binary layout needs its own formula that builds both
   the Swift daemon and the Go CLI, signs the daemon ad-hoc, and
   installs both side-by-side.

Both need to land before the v0.4.0 tag push to avoid a "tag, watch CI
break, retag" loop that would leak a half-baked release to Homebrew
users.

## How

### Release workflow rewrite

`make build` is the single source of truth for the two-step build (Swift
`steno-daemon` + Go `steno`); the workflow now defers to it. Sequence:

  1. Set up Swift 6.2 + Go 1.24 toolchains.
  2. `make build` → release-mode daemon (with embedded Info.plist via
     `-Xlinker -sectcreate`) + Go binary.
  3. `make sign-daemon` → ad-hoc codesign with
     `daemon/Resources/StenoDaemon.entitlements`.
  4. Stage `bin/steno-daemon` + `bin/steno` + README + LICENSE under
     `dist/steno-<tag>-macos-arm64/`, tar+gzip, compute sha256.
  5. Upload the workflow artifact AND create the GitHub Release with
     both files attached.

The artifact name carries `-arm64` to leave a clear migration path if
we ever ship a separate x86_64 build matrix. Single architecture is
fine for v0.4.0 — every supported macOS 26 host runs on Apple Silicon.

### Reference Homebrew formula

`Formula/steno.rb` mirrors `dictamac.rb`'s "reference copy lives
upstream, canonical copy lives in the tap" pattern. The release
procedure is:

  1. Tag and push v0.4.0; the release workflow above produces the
     tarball and `.sha256` file.
  2. Copy `Formula/steno.rb` to `jwulff/homebrew-tap/Formula/steno.rb`.
  3. Replace `REPLACE_WITH_RELEASE_SHA256` with the sha256 of the
     source tarball (NOT the binary tarball — Homebrew downloads
     source and builds it). The matching command is in the formula
     comments.
  4. Commit + push the tap.

The formula builds from source rather than downloading the prebuilt
tarball because:

  - Future architectures (x86_64, future Apple Silicon families) get
    native binaries without us fanning out the release matrix.
  - `brew audit` prefers source builds for transparency.
  - The daemon's ad-hoc codesign step needs to happen on the
    installing user's machine anyway for entitlements to bind to
    their TCC database identity.

`depends_on macos: :tahoe` (macOS 26+) and `MacOS::Xcode.version >=
"26"` are the same gates `dictamac.rb` uses, for the same reason
(`SpeechAnalyzer` is in the macOS 26 SDK only). `depends_on "go" =>
:build` handles the Go side.

## Key Decisions

- **Single arm64 artifact, no fan-out matrix.** Apple Silicon only is
  the realistic deployment surface for macOS 26 today; adding x86_64
  to the release matrix would slow CI and ship a binary no users
  could run anyway. The artifact name leaves the door open for a
  matrix expansion later without renaming.
- **Build via `make build` rather than open-coding `swift build`
  commands in the workflow.** Keeps the workflow honest about
  matching `make build` locally — when a contributor runs `make
  build` and ships, CI does the exact same thing. Single source of
  truth.
- **Source-build formula, not bottle / prebuilt-binary install.**
  Same reasoning as dictamac's formula: the ad-hoc signing step
  needs to happen on the user's machine; future architectures get
  native builds; `brew audit` prefers source.
- **Don't promote the prebuilt tarball as the install path.** It's
  attached to the release for users who want to bypass brew, but the
  formula points at the GitHub source tarball. Two install paths
  with different provenance would be confusing.
- **Caveats block in the formula explains the TCC prompts.** First
  launch will fire three permission dialogs; users see the caveats
  banner once on install so they know what to expect.

## Tradeoffs Considered

- **Pinning to Swift 6.2 vs 6.0 on the runner.** Steno needs 6.2 (per
  `daemon/Package.swift`'s `swift-tools-version`). The GitHub
  macos-15 runner ships 6.0 by default. The workflow asks
  `setup-swift` for 6.2, which today will likely fail to provision
  on the hosted image. We accept the loud failure: the only fix is
  bumping to a macOS 26 runner image once it's available, and a
  silent stale-SDK build would be worse than a failed CI run.
- **Why not commit the formula directly to the tap from this PR?**
  The reference formula in `Formula/steno.rb` carries
  `REPLACE_WITH_RELEASE_SHA256` because the sha is only computable
  after the tag exists. The tap-side commit happens as a separate
  step in the release procedure (see the file header comment in
  `Formula/steno.rb`).

[steno-tests-passed: 509 tests in 9s]
