# Steno

A fast, private speech-to-text TUI for macOS.

Steno uses Apple's new SpeechAnalyzer API (macOS 26) for real-time transcription that runs entirely on-device. No cloud services, no API keys, no rate limits.

![Steno transcribing a Seahawks press conference with 15 auto-extracted topics](assets/screenshot.png)

## Requirements

- macOS 26 (Tahoe) or later
- Microphone access

## Installation

### Download Binary

Download the latest release from [GitHub Releases](https://github.com/jwulff/steno/releases/latest):

```bash
# Download and unzip
curl -L https://github.com/jwulff/steno/releases/latest/download/steno-macos-arm64.zip -o steno.zip
unzip steno.zip

# Remove quarantine attribute (required for unsigned binaries)
xattr -d com.apple.quarantine steno

# Run
./steno
```

### From Source

Requires Swift 6.2+.

```bash
git clone https://github.com/jwulff/steno.git
cd steno
swift build -c release
```

The binary will be at `.build/release/steno`.

### Signed Binary

For microphone access without Gatekeeper warnings:

```bash
swift build -c release
codesign --force --sign - \
  --entitlements Resources/Steno.entitlements \
  .build/release/steno
```

## Usage

```bash
# Run with default microphone
steno

# List available microphones
steno --list-devices

# Use specific microphone
steno --device "MacBook Pro Microphone"
```

### Controls

| Key | Action |
|-----|--------|
| `Space` | Start/stop transcription |
| `s` | Open settings |
| `i` | Cycle input devices |
| `m` | Cycle AI models |
| `q` | Quit |
| `Up/Down` | Scroll transcript |

## How It Works

Steno uses the SpeechAnalyzer API introduced in macOS 26, which provides:

- **On-device processing** - Your audio never leaves your Mac
- **Low latency** - Real-time transcription as you speak
- **High accuracy** - 55% faster than Whisper Large V3 Turbo in Apple's benchmarks

## Development

```bash
# Run tests
swift test

# Run app
swift run steno
```

See [CLAUDE.md](CLAUDE.md) for development conventions.

## License

MIT
