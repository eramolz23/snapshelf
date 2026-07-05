#!/bin/bash
# Regenerate AppIcon.icns (committed — only rerun if the design changes).
set -e
cd "$(dirname "$0")"

swift - <<'EOF'
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icons draw their own rounded square: ~100px margin, ~185px radius at 1024.
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.86, alpha: 1),
           ending:   NSColor(calibratedRed: 0.08, green: 0.62, blue: 0.72, alpha: 1))!
    .draw(in: squircle, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: 400, weight: .medium)
let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!

// Tint the symbol white.
let tinted = NSImage(size: symbol.size)
tinted.lockFocus()
symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
NSColor.white.set()
NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
tinted.unlockFocus()

let target: CGFloat = 520
let scale = target / max(tinted.size.width, tinted.size.height)
let w = tinted.size.width * scale, h = tinted.size.height * scale
tinted.draw(in: NSRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h),
            from: .zero, operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "icon_1024.png"))
EOF

rm -rf SnapShelf.iconset
mkdir SnapShelf.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out "SnapShelf.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d icon_1024.png --out "SnapShelf.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns SnapShelf.iconset -o AppIcon.icns
rm -rf SnapShelf.iconset icon_1024.png
echo "AppIcon.icns regenerated"
