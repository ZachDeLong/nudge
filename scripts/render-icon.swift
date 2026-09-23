// Renders Nudge's app icon to assets/AppIcon.icns.
//
//     swift scripts/render-icon.swift        (or `make icon`)
//
// Same look as the badge in the popover header: the orange gradient tile with
// the menu bar glyph in white, on the standard macOS icon grid (an 824pt tile
// centred in a 1024pt canvas, with a soft drop shadow).

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Nudge-\(UUID().uuidString).iconset")
let output = root.appendingPathComponent("assets/AppIcon.icns")

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    // Draw in 1024pt design space whatever the output size.
    let scale = CGFloat(pixels) / 1024
    ctx.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Shadow under the tile only.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // ToolBadge's gradient, top-left to bottom-right.
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.21, alpha: 1),
        ending: NSColor(srgbRed: 0.81, green: 0.32, blue: 0.17, alpha: 1)
    )!
    gradient.draw(in: shape, angle: -45)

    // A faint top sheen so the tile doesn't read as a flat sticker.
    let sheen = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.16),
        ending: NSColor.white.withAlphaComponent(0)
    )!
    sheen.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let size = glyph.size
    glyph.draw(in: NSRect(
        x: tile.midX - size.width / 2,
        y: tile.midY - size.height / 2 - 8,
        width: size.width,
        height: size.height
    ))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * factor).write(to: iconset.appendingPathComponent(name))
    }
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(output.path)")
