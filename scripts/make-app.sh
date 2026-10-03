#!/usr/bin/env bash
# Build the S1 app and package it as dist/S1.app (ad-hoc signed, runs locally).
# Result: double-clickable app; TCC identity stays stable across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

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

# Ad-hoc sign so TCC sees one stable identity ("S1").
codesign --force --deep --sign - "$APP" >/dev/null

echo "built $APP — open it with: open $APP"
echo "to install: cp -R $APP /Applications/"
