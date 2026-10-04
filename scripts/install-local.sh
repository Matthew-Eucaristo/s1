#!/bin/zsh
# Build s1 in release mode and install the binary locally.
# Usage: ./scripts/install-local.sh [install-dir]   (default: ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

DEST="${1:-$HOME/.local/bin}"
mkdir -p "$DEST"
cp .build/release/s1 "$DEST/s1"
echo "installed -> $DEST/s1"
echo "make sure $DEST is in your PATH (e.g. export PATH=\"$DEST:\$PATH\")"
echo "then run: s1 preflight"
