#!/bin/zsh
# Build s1 in release mode and install the binary locally.
# Usage: ./scripts/install-local.sh [install-dir]   (default: ~/.local/bin)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

DEST="${1:-$HOME/.local/bin}"
mkdir -p "$DEST"
cp .build/release/s1 "$DEST/s1"
# A stable signature keeps TCC grants (Accessibility, Microphone…) across
# reinstalls; the linker's ad-hoc one changes with every build.
SIGN_IDENTITY="${S1_SIGN_IDENTITY:-S1 Dev Cert}"
IDENTITIES=$(security find-identity -v -p codesigning)
if [[ "$IDENTITIES" == *"\"$SIGN_IDENTITY\""* ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DEST/s1" >/dev/null
    echo "signed with '$SIGN_IDENTITY'"
else
    echo "note: no '$SIGN_IDENTITY' identity — ad-hoc signed; permissions reset on each install"
    echo "      (scripts/dev-cert.sh creates a stable local one)"
fi
echo "installed -> $DEST/s1"
echo "make sure $DEST is in your PATH (e.g. export PATH=\"$DEST:\$PATH\")"
echo "then run: s1 preflight"
