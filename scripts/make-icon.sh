#!/usr/bin/env bash
# Regenerate the app icon + menu-bar glyph from the s1 mark.
# Draws natively (no SVG rasterizer): macOS icon grid — 1024 canvas,
# 824 pt continuous-corner squircle body inset 100 pt, baked soft drop
# shadow, deep indigo gradient with a top sheen, white mark. Then builds
# the standard 10-image iconset and iconutil-compiles AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift - "$WORK" <<'EOF'
import AppKit
let work = CommandLine.arguments[1]

/// The s1 mark (assets/logo/s1.svg, 512 viewBox, y-down) as absolute
/// geometry: an "s" stroke and a "1" voice bar.
func markPath(into t: AffineTransform) -> (stroke: NSBezierPath, bar: NSBezierPath) {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { t.transform(NSPoint(x: x, y: y)) }
    let s = NSBezierPath()
    s.move(to: p(336, 176))
    s.curve(to: p(240, 80), controlPoint1: p(336, 123), controlPoint2: p(293, 80))
    s.line(to: p(216, 80))
    s.curve(to: p(120, 176), controlPoint1: p(163, 80), controlPoint2: p(120, 123))
    s.curve(to: p(178, 265), controlPoint1: p(120, 216), controlPoint2: p(144, 250))
    s.curve(to: p(244, 336), controlPoint1: p(226, 286), controlPoint2: p(244, 295))
    s.curve(to: p(148, 432), controlPoint1: p(244, 389), controlPoint2: p(201, 432))
    s.line(to: p(124, 432))
    s.curve(to: p(28, 336), controlPoint1: p(71, 432), controlPoint2: p(28, 389))
    s.lineCapStyle = .round
    s.lineJoinStyle = .round
    let k = t.transform(NSSize(width: 1, height: 1)).width
    s.lineWidth = 36 * abs(k)
    let o = p(368, 140), q = p(408, 372)
    let bar = NSBezierPath(roundedRect: NSRect(x: min(o.x, q.x), y: min(o.y, q.y),
                                               width: abs(q.x - o.x), height: abs(q.y - o.y)),
                           xRadius: 20 * abs(k), yRadius: 20 * abs(k))
    return (s, bar)
}

/// Apple-style continuous corner ("squircle"): superellipse, n = 5.
func squircle(_ r: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY, n = 5.0
    for i in 0...720 {
        let th = Double(i) / 720 * 2 * .pi
        let c = cos(th), s = sin(th)
        let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = cy + b * CGFloat(copysign(pow(abs(s), 2 / n), s))
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func png(_ size: CGFloat, _ draw: (CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Mark centred in `box`, `fill` of its width (svg y-down → AppKit y-up).
func markTransform(in box: NSRect, fill: CGFloat) -> AffineTransform {
    let w: CGFloat = 398, h: CGFloat = 388, cx: CGFloat = 209, cy: CGFloat = 256
    let k = box.width * fill / max(w, h)
    var t = AffineTransform(translationByX: box.midX, byY: box.midY)
    t.scale(x: k, y: -k)
    t.translate(x: -cx, y: -cy)
    return t
}

let icon = png(1024) { S in
    let u = S / 1024
    let body = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = squircle(body)
    // Baked drop shadow, as on every macOS app icon.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.32)
    sh.shadowOffset = NSSize(width: 0, height: -10 * u)
    sh.shadowBlurRadius = 22 * u
    sh.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.45, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.24, green: 0.22, blue: 0.86, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.09, blue: 0.38, alpha: 1)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: body, angle: -90)
    // Soft top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    // The mark, with a faint lift.
    let (stroke, bar) = markPath(into: markTransform(in: body, fill: 0.56))
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.28)
    lift.shadowOffset = NSSize(width: 0, height: -6 * u)
    lift.shadowBlurRadius = 14 * u
    lift.set()
    NSColor.white.setStroke(); stroke.stroke()
    NSColor.white.setFill(); bar.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Hairline edge so the shape reads on light and dark wallpapers.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = 2 * u
    shape.stroke()
}
try icon.write(to: URL(fileURLWithPath: work + "/icon-1024.png"))

// Menu-bar template glyph: solid black mark on clear (the system tints it).
for px in [18, 36] {
    let glyph = png(CGFloat(px)) { S in
        let (stroke, bar) = markPath(into: markTransform(in: NSRect(x: 0, y: 0, width: S, height: S), fill: 0.9))
        NSColor.black.setStroke(); stroke.stroke()
        NSColor.black.setFill(); bar.fill()
    }
    try glyph.write(to: URL(fileURLWithPath: work + "/menubar-\(px).png"))
}
EOF
cp "$WORK/icon-1024.png" assets/icon-1024.png
cp "$WORK/menubar-18.png" assets/menubar-18.png
cp "$WORK/menubar-36.png" assets/menubar-36.png

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s assets/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d assets/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns + icon-1024.png + menubar-18/36.png"
