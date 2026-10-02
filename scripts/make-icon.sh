#!/usr/bin/env bash
# Regenerate assets/AppIcon.icns from assets/logo/s1.svg.
# Renders the mark over a soft squircle via a throwaway Swift script,
# then builds the standard 10-image iconset and iconutil-compiles it.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" assets/logo/s1.svg >/dev/null

swift - "$WORK" <<'EOF'
import AppKit
let work = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
let top = NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.99, alpha: 1)
let bot = NSColor(calibratedRed: 0.82, green: 0.83, blue: 0.88, alpha: 1)
NSGradient(colors: [top, bot])!.draw(in: path, angle: -90)
NSColor.white.withAlphaComponent(0.55).setStroke()
path.lineWidth = 6; path.stroke()
if let mark = NSImage(contentsOfFile: work + "/s1.svg.png") {
    let m = size * 0.62
    let mr = NSRect(x: (size - m) / 2, y: (size - m) / 2 + size * 0.015, width: m, height: m)
    mark.draw(in: mr, from: .zero, operation: .sourceOver, fraction: 1)
}
img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
try rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: work + "/icon-1024.png"))
EOF
cp "$WORK/icon-1024.png" assets/icon-1024.png

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$WORK/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns + assets/icon-1024.png"
