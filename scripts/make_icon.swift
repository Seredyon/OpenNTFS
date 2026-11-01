// Builds AppIcon.icns from a square artwork PNG following the macOS icon grid:
// 1024 canvas, 824 pt rounded-rectangle body (continuous corners), soft drop shadow.
// Usage: swift make_icon.swift <artwork.png> <output.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else { fatalError("usage: make_icon <png> <iconset>") }
let out = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    // Shadow under the body.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
    NSColor(calibratedRed: 0, green: 0.33, blue: 1, alpha: 1).setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Artwork clipped to the body.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    art.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    // Hairline edge for definition on light backgrounds.
    NSColor.black.withAlphaComponent(0.08).setStroke(); shape.lineWidth = 2; shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("iconset written to \(out.path)")
