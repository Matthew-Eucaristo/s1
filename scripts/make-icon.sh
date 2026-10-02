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

# Menu-bar template glyph: the mark alone, flattened to black-on-alpha.
qlmanage -t -s 72 -o "$WORK" assets/logo/s1.svg >/dev/null
swift - "$WORK" <<'EOF2'
import AppKit
let work = CommandLine.arguments[1]
let size: CGFloat = 36
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
if let mark = NSImage(contentsOfFile: work + "/s1.svg.png") {
    let m = size * 0.86
    mark.draw(in: NSRect(x: (size-m)/2, y: (size-m)/2, width: m, height: m),
              from: .zero, operation: .sourceOver, fraction: 1)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let px = rep.bitmapData!
let bpp = rep.bitsPerPixel / 8
for i in stride(from: 0, to: rep.bytesPerRow * rep.pixelsHigh, by: bpp) {
    let r = px[i], g = px[i+1], b = px[i+2]
    if r > 200 && g > 200 && b > 200 { px[i+3] = 0 }   // white bg -> transparent
    else { px[i] = 0; px[i+1] = 0; px[i+2] = 0; px[i+3] = 255 }
}
try rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: work + "/menubar-36.png"))
EOF2
cp "$WORK/menubar-36.png" assets/menubar-36.png
sips -z 18 18 assets/menubar-36.png --out assets/menubar-18.png >/dev/null
echo "wrote assets/AppIcon.icns + icon-1024.png + menubar-18/36.png"
