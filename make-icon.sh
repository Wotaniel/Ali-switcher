#!/bin/bash
# Генерирует build/AliSwitcher.icns (простая картинка, без Xcode).
set -euo pipefail
cd "$(dirname "$0")"

if [ -f "$HOME/.swiftly/env.sh" ]; then
    . "$HOME/.swiftly/env.sh"
fi

ICON_SWIFT="build/makeicon.swift"
cat > "$ICON_SWIFT" <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.21, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
             xRadius: 180, yRadius: 180).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 250, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
]
let text = NSAttributedString(string: "RU EN", attributes: attrs)
let ts = text.size()
text.draw(in: NSRect(x: 0, y: (size - ts.height) / 2, width: size, height: ts.height))

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: "build/icon-1024.png"))
SWIFT

swiftc -O -swift-version 5 "$ICON_SWIFT" -o build/makeicon
build/makeicon

rm -rf build/icon.iconset
mkdir -p build/icon.iconset
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" build/icon-1024.png --out "build/icon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" build/icon-1024.png --out "build/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/icon.iconset -o build/AliSwitcher.icns
echo "✓ Иконка: build/AliSwitcher.icns"
