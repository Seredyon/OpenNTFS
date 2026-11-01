// Draws the installer window background: 640x400 points plus @2x. A soft pastel beige (no pure
// white) on which Finder's black icon labels read well, and a black arrow from OpenNTFS (x 160)
// to Applications (x 480). Icon centres are at y 180 (see make_dsstore.py).
// Usage: swift make_dmg_background.swift <output-folder>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let width: CGFloat = 640, height: CGFloat = 400
let iconY: CGFloat = 180

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

    // Pastel beige with a gentle warm glow in the middle.
    let base = CGGradient(colorsSpace: space, colors: [rgb(0xF1E7D8), rgb(0xE6D9C4)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xF5ECDF, 0.85), rgb(0xF5ECDF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 320, y: iconY), startRadius: 0,
                           endCenter: CGPoint(x: 320, y: iconY), endRadius: 320, options: [])

    // Black arrow with round ends.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 266, y: iconY)); arrow.addLine(to: CGPoint(x: 370, y: iconY))
    arrow.move(to: CGPoint(x: 352, y: iconY - 16)); arrow.addLine(to: CGPoint(x: 372, y: iconY)); arrow.addLine(to: CGPoint(x: 352, y: iconY + 16))
    ctx.addPath(arrow)
    ctx.setStrokeColor(rgb(0x1C1C1E)); ctx.setLineWidth(6); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    return rep.representation(using: .png, properties: [:])!
}

try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try! render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
print("Background written to \(output.path)")
