// Draws Narrate's app icon: an abstract open book (two soft strokes) with a waveform rising from it.
// Usage: swift scripts/make-icon.swift packaging/AppIcon.icns   (also writes AppIcon.png at 1024 px)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "packaging/AppIcon.icns")
let space = CGColorSpace(name: CGColorSpace.displayP3)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Fill `path` with a linear gradient from `a` to `b`.
func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func draw(_ size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Tile on the macOS icon grid.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(tile); ctx.setFillColor(rgb(0.10, 0.10, 0.30)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    // Deep indigo to violet, with a teal glow low left and a warm one behind the waveform.
    ctx.drawLinearGradient(gradient([(0, rgb(0.20, 0.13, 0.52)), (1, rgb(0.07, 0.09, 0.30))]),
                           start: CGPoint(x: 220, y: 924), end: CGPoint(x: 800, y: 100), options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(0.10, 0.62, 0.72, 0.55)), (1, rgb(0.10, 0.62, 0.72, 0))]),
                           startCenter: CGPoint(x: 210, y: 200), startRadius: 0, endCenter: CGPoint(x: 210, y: 200), endRadius: 560, options: [])
    ctx.drawRadialGradient(gradient([(0, rgb(1.0, 0.55, 0.35, 0.40)), (1, rgb(1.0, 0.55, 0.35, 0))]),
                           startCenter: CGPoint(x: 512, y: 640), startRadius: 0, endCenter: CGPoint(x: 512, y: 640), endRadius: 380, options: [])

    // Waveform: seven capsules of speech-like, uneven heights, warm gradient, soft glow.
    let heights: [CGFloat] = [120, 230, 330, 200, 300, 210, 110]
    let barWidth: CGFloat = 46, gap: CGFloat = 24
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = 512 - total / 2 + CGFloat(i) * (barWidth + gap)
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: 640 - h / 2, width: barWidth, height: h), cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: rgb(1.0, 0.50, 0.35, 0.65))
    ctx.addPath(bars); ctx.setFillColor(rgb(1.0, 0.62, 0.35)); ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, bars, gradient([(0, rgb(1.0, 0.40, 0.42)), (0.55, rgb(1.0, 0.62, 0.30)), (1, rgb(1.0, 0.86, 0.45))]),
         from: CGPoint(x: 512, y: 475), to: CGPoint(x: 512, y: 805))

    // The book: two broad strokes meeting in a soft V, like pages opening. White glass.
    let book = CGMutablePath()
    book.move(to: CGPoint(x: 236, y: 418))
    book.addCurve(to: CGPoint(x: 512, y: 330), control1: CGPoint(x: 340, y: 430), control2: CGPoint(x: 440, y: 400))
    book.addCurve(to: CGPoint(x: 788, y: 418), control1: CGPoint(x: 584, y: 400), control2: CGPoint(x: 684, y: 430))
    let pages = book.copy(strokingWithWidth: 56, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0.03, 0.02, 0.15, 0.45))
    ctx.addPath(pages); ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, pages, gradient([(0, rgb(1, 1, 1)), (1, rgb(0.84, 0.86, 0.98))]), from: CGPoint(x: 512, y: 440), to: CGPoint(x: 512, y: 300))
    // A second, fainter page edge underneath.
    let under = CGMutablePath()
    under.move(to: CGPoint(x: 280, y: 330))
    under.addCurve(to: CGPoint(x: 512, y: 262), control1: CGPoint(x: 370, y: 336), control2: CGPoint(x: 450, y: 316))
    under.addCurve(to: CGPoint(x: 744, y: 330), control1: CGPoint(x: 574, y: 316), control2: CGPoint(x: 654, y: 336))
    ctx.addPath(under.copy(strokingWithWidth: 30, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.setFillColor(rgb(1, 1, 1, 0.38)); ctx.fillPath()

    // Glass: a soft sheen across the top of the tile and a hairline rim.
    ctx.drawLinearGradient(gradient([(0, rgb(1, 1, 1, 0.16)), (0.35, rgb(1, 1, 1, 0))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()
    ctx.addPath(tile); ctx.setStrokeColor(rgb(1, 1, 1, 0.12)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

func png(_ image: CGImage) -> Data { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])! }

let master = draw(1024)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try png(draw(CGFloat(points * scale))).write(to: iconset.appendingPathComponent(name))
    }
}
try png(master).write(to: out.deletingPathExtension().appendingPathExtension("png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
print(out.path)
