// Draws Narrate's app icon: an open book with sound waves rising from it.
// Usage: swift scripts/make-icon.swift packaging/AppIcon.icns   (also writes AppIcon.png at 1024 px)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging/AppIcon.icns")

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // macOS icon grid: an 824 pt rounded square centred on 1024, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let night = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.13, green: 0.16, blue: 0.36, alpha: 1).cgColor,
        NSColor(red: 0.05, green: 0.36, blue: 0.45, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(night, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    ctx.translateBy(x: 0, y: 40)
    // Sound waves: three arcs above the book's spine, warm and fading outwards.
    let center = CGPoint(x: 512, y: 400)
    ctx.setLineCap(.round)
    for (i, radius) in [150.0, 240.0, 330.0].enumerated() {
        ctx.setStrokeColor(NSColor(red: 1.0, green: 0.74, blue: 0.33, alpha: 1 - CGFloat(i) * 0.25).cgColor)
        ctx.setLineWidth(46 - CGFloat(i) * 6)
        ctx.addArc(center: center, radius: radius, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
        ctx.strokePath()
    }

    // The open book: two pages curving up from the spine.
    func page(_ side: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 512, y: 250))
        p.addCurve(to: CGPoint(x: 512 + side * 300, y: 300), control1: CGPoint(x: 512 + side * 90, y: 300), control2: CGPoint(x: 512 + side * 200, y: 270))
        p.addLine(to: CGPoint(x: 512 + side * 300, y: 450))
        p.addCurve(to: CGPoint(x: 512, y: 410), control1: CGPoint(x: 512 + side * 200, y: 430), control2: CGPoint(x: 512 + side * 90, y: 450))
        p.closeSubpath()
        return p
    }
    for side: CGFloat in [-1, 1] {
        ctx.addPath(page(side))
        ctx.setFillColor(NSColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1).cgColor)
        ctx.fillPath()
    }
    // Spine and a few lines of text on each page.
    ctx.setStrokeColor(NSColor(red: 0.13, green: 0.16, blue: 0.36, alpha: 0.35).cgColor)
    ctx.setLineWidth(8)
    ctx.move(to: CGPoint(x: 512, y: 252))
    ctx.addLine(to: CGPoint(x: 512, y: 408))
    ctx.strokePath()
    ctx.setLineWidth(10)
    for side: CGFloat in [-1, 1] {
        for row in 0..<3 {
            let y = 310 + CGFloat(row) * 36
            ctx.move(to: CGPoint(x: 512 + side * 60, y: y + 8))
            ctx.addLine(to: CGPoint(x: 512 + side * 250, y: y + 18))
        }
    }
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try draw(1024).representation(using: .png, properties: [:])!.write(to: out.deletingPathExtension().appendingPathExtension("png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
print(out.path)
