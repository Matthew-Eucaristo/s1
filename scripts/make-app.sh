#!/usr/bin/env bash
# Build the S1 app and package it as dist/S1.app.
# Signs with $S1_SIGN_IDENTITY (default: "S1 Dev Cert" self-signed dev cert if
# present, else ad-hoc). Ad-hoc signatures key TCC grants to the binary's cdhash,
# which changes on EVERY rebuild — so each rebuild would silently lose
# Accessibility/Screen Recording grants. Any stable signing identity (a
# self-signed cert kept in the login keychain, or a real Developer ID) makes
# grants survive rebuilds. scripts/dev-cert.sh creates the dev cert.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${S1_SIGN_IDENTITY:-S1 Dev Cert}"

CONFIG="${1:-release}"
swift build -c "$CONFIG" --product s1-app --arch arm64 --arch x86_64

APP="dist/S1.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Universal builds land in .build/apple/Products/<Config>/, single-arch in
# .build/<config>/ — accept either layout.
BIN=""
for d in ".build/apple/Products/$(printf %s "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}" \
         ".build/$CONFIG"; do
    [ -f "$d/s1-app" ] && BIN="$d/s1-app" && break
done
[ -n "$BIN" ] || { echo "error: s1-app binary not found in .build"; exit 1; }
cp "$BIN" "$APP/Contents/MacOS/S1"
cp Sources/S1App/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
    || echo "note: assets/AppIcon.icns missing — run scripts/make-icon.sh"
# Menu-bar template glyph (s1 mark); the app falls back to an SF Symbol
# if absent.
cp assets/menubar-18.png "$APP/Contents/Resources/s1-menubar.png" 2>/dev/null || true
cp assets/menubar-36.png "$APP/Contents/Resources/s1-menubar@2x.png" 2>/dev/null || true

# Prefer the stable dev cert; fall back to ad-hoc (-) when absent.
# No --deep: deprecated by Apple, and this bundle holds a single binary.
if security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
    echo "signed with '$SIGN_IDENTITY' (stable TCC identity across rebuilds)"
else
    codesign --force --sign - "$APP" >/dev/null
    echo "note: no '$SIGN_IDENTITY' identity — ad-hoc signed; TCC grants will reset each rebuild"
    echo "      run scripts/dev-cert.sh once to create a stable local dev cert"
fi

echo "built $APP — open it with: open $APP"
echo "to install: cp -R $APP /Applications/"
