// Draws the installer window background: 640x400 points plus @2x, dark (no pure white, easy on
// the eyes in a dark room), with soft cards under the two icons, an arrow from OpenNTFS (x 160)
// to Applications (x 480) and a short caption. Icon centres are at y 180 (see make_dsstore.py).
// Usage: swift make_dmg_background.swift <output-folder>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let width: CGFloat = 640, height: CGFloat = 400
let iconY: CGFloat = 180, appX: CGFloat = 160, applicationsX: CGFloat = 480

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    // Work in Finder's top-left coordinates.
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)

    // Base: deep slate gradient with a faint blue glow behind the arrow.
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x1E2530), rgb(0x141920)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0x3A6FD8, 0.20), rgb(0x3A6FD8, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 320, y: iconY), startRadius: 0,
                           endCenter: CGPoint(x: 320, y: iconY), endRadius: 300, options: [])

    // Soft cards holding each icon and its label.
    for x in [appX, applicationsX] {
        let card = CGRect(x: x - 82, y: iconY - 90, width: 164, height: 192)
        let shape = CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil)
        let fill = CGGradient(colorsSpace: space, colors: [rgb(0x8FA6C8, 0.09), rgb(0x8FA6C8, 0.03)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: card.minY), end: CGPoint(x: 0, y: card.maxY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setStrokeColor(rgb(0xA9BBD6, 0.10)); ctx.setLineWidth(1); ctx.strokePath()
    }

    // Arrow with a blue gradient stroke.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 264, y: iconY)); arrow.addLine(to: CGPoint(x: 372, y: iconY))
    arrow.move(to: CGPoint(x: 354, y: iconY - 16)); arrow.addLine(to: CGPoint(x: 374, y: iconY)); arrow.addLine(to: CGPoint(x: 354, y: iconY + 16))
    let outline = arrow.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let stroke = CGGradient(colorsSpace: space, colors: [rgb(0x2F6BEA, 0.55), rgb(0x6FA3FF, 0.95)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(outline); ctx.clip()
    ctx.drawLinearGradient(stroke, start: CGPoint(x: 264, y: 0), end: CGPoint(x: 376, y: 0), options: [])
    ctx.restoreGState()

    // Caption, drawn unflipped.
    let caption = NSAttributedString(string: "Drag OpenNTFS to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(cgColor: rgb(0x8C97A8))!,
    ])
    let line = CTLineCreateWithAttributedString(caption)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = CGPoint(x: (width - bounds.width) / 2, y: height - 330)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    return rep.representation(using: .png, properties: [:])!
}

try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try! render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
print("Background written to \(output.path)")
