// Draws the app icon and writes Resources/AppIcon.icns. Usage: swift scripts/icon.swift [preview.png]
import AppKit

let size = 1024.0
let accent = CGColor(srgbRed: 1, green: 0.58, blue: 0.20, alpha: 1)

func roundedRect(_ r: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // Full bleed: macOS 26+ masks it to the system shape; a pre-shaped icon gets boxed in a grey tile instead.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.scaleBy(x: size / tile.width, y: size / tile.height)
    ctx.translateBy(x: -tile.minX, y: -tile.minY)

    let bg = CGGradient(colorsSpace: rgb, colors: [CGColor(srgbRed: 0.20, green: 0.20, blue: 0.24, alpha: 1),
                                                   CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: tile.maxY), end: CGPoint(x: 700, y: tile.minY),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glow = CGGradient(colorsSpace: rgb, colors: [accent.copy(alpha: 0.42)!, accent.copy(alpha: 0)!] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 300), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 300), endRadius: 400, options: [])

    // Keycap skirt, with the dished top set back so the front of the cap shows
    let skirt = CGRect(x: 262, y: 262, width: 500, height: 500)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: CGColor(gray: 0, alpha: 0.6))
    ctx.addPath(roundedRect(skirt, 96))
    ctx.setFillColor(CGColor(gray: 0.7, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(skirt, 96))
    ctx.clip()
    let skirtFill = CGGradient(colorsSpace: rgb, colors: [CGColor(gray: 0.84, alpha: 1), CGColor(gray: 0.62, alpha: 1)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(skirtFill, start: CGPoint(x: 512, y: skirt.maxY), end: CGPoint(x: 512, y: skirt.minY), options: [])
    ctx.restoreGState()

    let top = CGRect(x: 318, y: 350, width: 388, height: 372)
    ctx.saveGState()
    ctx.addPath(roundedRect(top, 70))
    ctx.clip()
    let topFill = CGGradient(colorsSpace: rgb, colors: [CGColor(gray: 0.99, alpha: 1), CGColor(gray: 0.88, alpha: 1)] as CFArray,
                             locations: [0, 1])!
    ctx.drawLinearGradient(topFill, start: CGPoint(x: 512, y: top.maxY), end: CGPoint(x: 512, y: top.minY), options: [])
    let dish = CGGradient(colorsSpace: rgb, colors: [CGColor(gray: 0, alpha: 0.07), CGColor(gray: 0, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(dish, startCenter: CGPoint(x: 512, y: 536), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 536), endRadius: 230, options: [])
    ctx.restoreGState()

    // Legend: a down arrow, the downstroke
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(46)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 512, y: 640))
    ctx.addLine(to: CGPoint(x: 512, y: 440))
    ctx.move(to: CGPoint(x: 432, y: 520))
    ctx.addLine(to: CGPoint(x: 512, y: 440))
    ctx.addLine(to: CGPoint(x: 592, y: 520))
    ctx.strokePath()
    return ctx.makeImage()!
}

func png(_ image: CGImage, _ px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.imageInterpolation = .high
    NSGraphicsContext.current = g
    NSImage(cgImage: image, size: NSSize(width: size, height: size)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let image = render()
let args = CommandLine.arguments
if args.count > 1 {
    png(image, 1024, to: URL(fileURLWithPath: args[1]))
    exit(0)
}
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    png(image, pt, to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    png(image, pt * 2, to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
