#!/bin/zsh
# Build a universal (arm64 + x86_64) release tarball for GitHub Releases.
# Usage: ./scripts/release.sh 0.2.0   ->  s1-0.2.0-macos.tar.gz + sha256
set -euo pipefail
VERSION="${1:?usage: ./scripts/release.sh <version>  e.g. 0.2.0}"
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64

BIN_DIR=".build/apple/Products/Release"
[[ -f "$BIN_DIR/s1" ]] || { echo "universal binary not found at $BIN_DIR/s1" >&2; exit 1; }
lipo -info "$BIN_DIR/s1"

OUT="s1-${VERSION}-macos.tar.gz"
tar -czf "$OUT" -C "$BIN_DIR" s1
SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')
echo "wrote $OUT"
echo "sha256: $SHA"
echo "upload it to GitHub Releases, then update Formula/s1.rb (url + sha256)"
