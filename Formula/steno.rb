# Sample Homebrew formula for steno.
#
# This file is a REFERENCE COPY that ships in the steno repo so the
# formula can be code-reviewed alongside the code it builds. The canonical,
# brew-installable copy lives in https://github.com/jwulff/homebrew-tap at
# `Formula/steno.rb` and is installed via:
#
#   brew install jwulff/tap/steno
#
# When releasing a new steno version, update the `url`, `sha256`, and
# (if needed) the macOS version gate here AND in the tap repo. The
# release workflow at `.github/workflows/release.yml` produces a
# `steno-<tag>-macos-arm64.tar.gz` artifact that ships both binaries
# pre-built; the formula below intentionally builds from source instead
# so users with non-Apple-Silicon Macs (or future architectures) get
# native binaries without us having to fan out the release matrix.
class Steno < Formula
  desc "macOS always-on speech-to-text TUI + MCP server (Swift daemon + Go CLI)"
  homepage "https://github.com/jwulff/steno"
  url "https://github.com/jwulff/steno/archive/refs/tags/v0.5.0.tar.gz"
  # Replace with the value of:
  #   curl -sL https://github.com/jwulff/steno/archive/refs/tags/v0.5.0.tar.gz \
  #     | shasum -a 256
  sha256 "f642d702bc405af370dc20b94a40d459d97b114674b5f4d8deb15fcb387fd3c6"
  license "MIT"
  head "https://github.com/jwulff/steno.git", branch: "main"

  # steno uses macOS 26 (Tahoe) SpeechAnalyzer APIs. `:tahoe` is the
  # Homebrew macro for macOS 26.0+; brew will refuse to install on older
  # systems.
  depends_on macos: :tahoe

  # Build-time dependencies. Swift 6.2+ comes from Xcode 26 — kept as a
  # floor on the `xcode` dep below. Go 1.24+ is required for the
  # `cmd/steno` binary; Homebrew installs it as a build-only dep so
  # downstream users don't need it at runtime.
  depends_on xcode: ["16.0", :build]
  depends_on "go" => :build

  def install
    # steno targets `.macOS("26.0")` (in daemon/Package.swift) and
    # imports `SpeechAnalyzer` / `SpeechTranscriber`, which are only
    # available in the macOS 26 SDK that ships with Xcode 26. Homebrew
    # may pick an older toolchain on Tahoe machines that still have
    # Xcode/CLT 16.x installed, in which case the Swift build will
    # fail late with cryptic "cannot find type 'SpeechAnalyzer' in
    # scope" errors. Fail loudly up front instead.
    odie <<~EOS unless MacOS::Xcode.version >= "26"
      steno requires Xcode 26 (or its Command Line Tools) to build,
      which provides the macOS 26 SDK. Detected Xcode version:
      #{MacOS::Xcode.version}.

      Install Xcode 26 from the App Store (or `xcode-select` to a newer
      developer dir) and try again.
    EOS

    # Pin the deployment target so the Swift compiler honors the macOS
    # 26 floor declared in daemon/Package.swift even if a host
    # environment overrides it.
    ENV["MACOSX_DEPLOYMENT_TARGET"] = "26.0"

    # Build the daemon directly via `swift build` instead of `make
    # build-daemon` so we can pass `--disable-sandbox`. Homebrew
    # already wraps the install in its own `sandbox-exec`, and
    # SwiftPM's internal sandbox-exec call during manifest compilation
    # fails with `sandbox-exec: sandbox_apply: Operation not
    # permitted` when nested inside Homebrew's sandbox.
    # `--disable-sandbox` tells SwiftPM to skip its layer, which is
    # safe under Homebrew's already-sandboxed install context.
    cd "daemon" do
      system "swift", "build",
             "-c", "release",
             "--disable-sandbox",
             "-Xlinker", "-sectcreate",
             "-Xlinker", "__TEXT",
             "-Xlinker", "__info_plist",
             "-Xlinker", "Resources/Info.plist"

      # SpeechAnalyzer requires the `disable-library-validation` +
      # `allow-jit` + `device.audio-input` entitlements at runtime, so
      # ad-hoc sign the daemon binary the same way `make sign-daemon`
      # does. Ad-hoc signing is required because Apple Developer
      # certificates trigger provisioning-profile validation which
      # fails for bare CLI binaries.
      system "codesign",
             "--sign", "-",
             "--options", "runtime",
             "--entitlements", "Resources/StenoDaemon.entitlements",
             "--force",
             ".build/release/steno-daemon"
    end

    # Build the Go CLI (TUI + MCP modes; dispatched by the `--mcp`
    # flag at runtime). No code-signing needed — it only talks to the
    # daemon over a Unix socket.
    cd "cmd/steno" do
      system "go", "build", "-o", "steno", "."
    end

    bin.install "daemon/.build/release/steno-daemon"
    bin.install "cmd/steno/steno"
  end

  def caveats
    <<~EOS
      Steno is an always-on speech-to-text TUI. First launch grants the
      Microphone, Speech Recognition, and Screen & System Audio TCC
      prompts; until you accept them the daemon will stay in an error
      state with a message in the TUI's status bar.

      Run `steno` to open the TUI (the daemon auto-starts in the
      background). Run `steno --mcp` for the MCP stdio server mode.
    EOS
  end

  test do
    # Smoke check: both binaries load and respond to --version (or
    # equivalent). We do NOT exercise transcription here because that
    # requires Speech Recognition + Microphone TCC permission, which
    # is unavailable in `brew test`'s sandbox.
    #
    # `steno-daemon status` reports the daemon's state without
    # requiring it to be running — it just reads the socket / PID
    # file. Exit code 0 indicates the binary linked correctly and
    # parses its arguments.
    system bin/"steno-daemon", "status"
    # The Go CLI's `--help` flag exits 0 and proves the binary linked.
    # We avoid running the TUI itself because it would block.
    system bin/"steno", "--help"
  end
end
