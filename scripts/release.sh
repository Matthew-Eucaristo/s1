#!/bin/zsh
# Build the release artifacts for GitHub Releases:
#   s1-<version>-macos.tar.gz   universal CLI (arm64 + x86_64)
#   S1-<version>-app.zip        universal signed S1.app bundle
# Prints the sha256 of each — paste them into the tap's Cask,
# or let scripts/publish-tap.sh do the whole dance.
#
# Usage: ./scripts/release.sh 0.2.0
set -euo pipefail
VERSION="${1:?usage: ./scripts/release.sh <version>  e.g. 0.2.0}"
cd "$(dirname "$0")/.."

echo "=== building universal CLI ==="
swift build -c release --arch arm64 --arch x86_64 --product s1

BIN_DIR=".build/apple/Products/Release"
[[ -f "$BIN_DIR/s1" ]] || { echo "universal binary not found at $BIN_DIR/s1" >&2; exit 1; }
lipo -info "$BIN_DIR/s1"

TAR="s1-${VERSION}-macos.tar.gz"
tar -czf "$TAR" -C "$BIN_DIR" s1
echo "wrote $TAR"
echo "sha256: $(shasum -a 256 "$TAR" | awk '{print $1}')"

echo "=== building universal S1.app ==="
./scripts/make-app.sh release >/dev/null
[[ -d dist/S1.app ]] || { echo "dist/S1.app missing" >&2; exit 1; }
lipo -info "dist/S1.app/Contents/MacOS/S1"

ZIP="S1-${VERSION}-app.zip"
rm -f "$ZIP"
# ditto, not zip -r: preserves Finder metadata + a layout unzip sees as a
# plain .app bundle (what `brew install --cask` expects).
ditto -c -k --sequesterRsrc --keepParent dist/S1.app "$ZIP"
echo "wrote $ZIP"
echo "sha256: $(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo
echo "next: ./scripts/publish-tap.sh $VERSION   # or attach both files to the"
echo "      GitHub Release manually + update Casks/s1.rb"
