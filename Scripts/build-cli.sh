#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-dev}"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"

cd "$ROOT_DIR"

echo "Building oatmeal CLI (release)…"
swift build -c release --arch arm64

BINARY="$BUILD_DIR/arm64-apple-macosx/release/oatmeal"

if [[ ! -f "$BINARY" ]]; then
  echo "ERROR: binary not found at $BINARY"
  exit 1
fi

# Strip debug symbols
strip "$BINARY"

mkdir -p "$DIST_DIR"
TARBALL="$DIST_DIR/oatmeal-$VERSION-arm64-macos.tar.gz"

# Package into tarball
tar -czf "$TARBALL" -C "$(dirname "$BINARY")" oatmeal

SIZE=$(wc -c < "$TARBALL" | tr -d ' ')
SHA=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)

echo ""
echo "Built: $TARBALL"
echo "Size:  $SIZE bytes"
echo "SHA256: $SHA"
echo ""
echo "To create a release:"
echo "  gh release create v$VERSION $TARBALL --title \"v$VERSION\" --notes \"Release v$VERSION\""
echo ""
echo "Then update the Homebrew formula with:"
echo "  url \"https://github.com/st-imdev/oatmeal-meeting-notes/releases/download/v$VERSION/oatmeal-$VERSION-arm64-macos.tar.gz\""
echo "  sha256 \"$SHA\""
