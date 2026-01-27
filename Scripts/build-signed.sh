#!/bin/bash
#
# Build a signed release binary of Steno
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"

echo "Building Steno..."

cd "$PROJECT_DIR"

# Build release version
swift build -c release

# Sign with ad-hoc signature (for local use)
# For distribution, replace with your Developer ID
codesign --force --sign - \
    --entitlements "$PROJECT_DIR/Resources/Steno.entitlements" \
    "$BUILD_DIR/steno"

echo ""
echo "Build complete!"
echo "Binary: $BUILD_DIR/steno"
echo ""
echo "To install:"
echo "  cp $BUILD_DIR/steno /usr/local/bin/"
