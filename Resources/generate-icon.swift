#!/usr/bin/env swift
// Generates AppIcon.icns for Switcher.
// Usage: swift Resources/generate-icon.swift
// Requires: macOS with AppKit (runs as a CLI script, no Xcode needed).

import AppKit

_ = NSApplication.shared   // init font/drawing subsystems

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("error: no graphics context\n", stderr); exit(1)
}

// ── Background gradient ───────────────────────────────────────────────────────
let cs      = CGColorSpaceCreateDeviceRGB()
let colors  = [CGColor(srgbRed: 0.10, green: 0.34, blue: 0.90, alpha: 1),   // #1A57E6 top
               CGColor(srgbRed: 0.04, green: 0.13, blue: 0.52, alpha: 1)] as CFArray // #0A2185 bottom
let grad    = CGGradient(colorsSpace: cs, colors: colors, locations: nil)!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: size / 2, y: size),
                       end:   CGPoint(x: size / 2, y: 0),
                       options: [])

// ── Frosted-glass card ────────────────────────────────────────────────────────
let cardW: CGFloat = 780
let cardH: CGFloat = 290
let cardX = (size - cardW) / 2
let cardY = (size - cardH) / 2

ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 50,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))

let cardPath = CGPath(roundedRect: CGRect(x: cardX, y: cardY, width: cardW, height: cardH),
                      cornerWidth: 72, cornerHeight: 72, transform: nil)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13))
ctx.addPath(cardPath)
ctx.fillPath()

ctx.setShadow(offset: .zero, blur: 0, color: nil)

ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
ctx.setLineWidth(3)
ctx.addPath(cardPath)
ctx.strokePath()

// ── Helper: draw centred attributed string ────────────────────────────────────
func draw(_ text: String,
          cx: CGFloat, cy: CGFloat,
          size fontSize: CGFloat,
          color: NSColor = .white,
          weight: NSFont.Weight = .black) {

    let font  = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str   = NSAttributedString(string: text, attributes: attrs)
    let sz    = str.size()
    str.draw(at: NSPoint(x: cx - sz.width / 2, y: cy - sz.height / 2))
}

// ── EN (left key) ─────────────────────────────────────────────────────────────
let lx = size / 2 - 218
let rx = size / 2 + 218
let cy = size / 2

draw("EN", cx: lx, cy: cy, size: 210)

// ── Arrow ─────────────────────────────────────────────────────────────────────
draw("↔", cx: size / 2, cy: cy + 2, size: 88,
     color: NSColor(srgbRed: 0.55, green: 0.80, blue: 1.0, alpha: 0.95),
     weight: .medium)

// ── RU (right key) ───────────────────────────────────────────────────────────
draw("RU", cx: rx, cy: cy, size: 210)

// ── Thin dividers beside the arrow ───────────────────────────────────────────
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
ctx.setLineWidth(2)
let lineTop    = cardY + 52
let lineBottom = cardY + cardH - 52
for x in [size / 2 - 68, size / 2 + 68] {
    ctx.move(to: CGPoint(x: x, y: lineTop))
    ctx.addLine(to: CGPoint(x: x, y: lineBottom))
}
ctx.strokePath()

image.unlockFocus()

// ── Export 1024×1024 PNG ──────────────────────────────────────────────────────
guard let tiff = image.tiffRepresentation,
      let rep  = NSBitmapImageRep(data: tiff),
      let png  = rep.representation(using: .png, properties: [:]) else {
    fputs("error: failed to encode PNG\n", stderr); exit(1)
}

let projectDir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
let pngURL     = projectDir.appendingPathComponent("Resources/icon-1024.png")
try png.write(to: pngURL)
print("PNG → \(pngURL.path)")

// ── Build .iconset ────────────────────────────────────────────────────────────
let iconsetURL = projectDir.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(Int, Bool)] = [
    (16, false), (16, true),
    (32, false), (32, true),
    (128, false), (128, true),
    (256, false), (256, true),
    (512, false), (512, true),
]

for (pt, retina) in sizes {
    let px   = retina ? pt * 2 : pt
    let name = retina ? "icon_\(pt)x\(pt)@2x.png" : "icon_\(pt)x\(pt).png"
    let dest = iconsetURL.appendingPathComponent(name)

    let scaled = NSImage(size: NSSize(width: px, height: px))
    scaled.lockFocus()
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    scaled.unlockFocus()

    guard let t2  = scaled.tiffRepresentation,
          let r2  = NSBitmapImageRep(data: t2),
          let p2  = r2.representation(using: .png, properties: [:]) else { continue }
    try p2.write(to: dest)
}
print("Iconset → \(iconsetURL.path)")

// ── iconutil → .icns ──────────────────────────────────────────────────────────
let icnsURL = projectDir.appendingPathComponent("Resources/AppIcon.icns")
let task    = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments     = ["-c", "icns", "-o", icnsURL.path, iconsetURL.path]
try task.run()
task.waitUntilExit()

if task.terminationStatus == 0 {
    print("ICNS  → \(icnsURL.path)")
    try? FileManager.default.removeItem(at: iconsetURL)
    try? FileManager.default.removeItem(at: pngURL)
    print("✅ Done")
} else {
    fputs("error: iconutil failed\n", stderr); exit(1)
}
