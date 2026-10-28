import AppKit

// Renders the bars app-icon glyph layers on Icon Composer's 1024pt artboard:
// three stacked capsule meters (tracks + fills) with descending fill levels.
let size = 1024
let outDir = CommandLine.arguments[1]

let meterWidth: CGFloat = 620
let meterHeight: CGFloat = 116
let gap: CGFloat = 78
let fills: [CGFloat] = [0.82, 0.56, 0.30]
let originX = (CGFloat(size) - meterWidth) / 2
let totalHeight = meterHeight * 3 + gap * 2
let topY = (CGFloat(size) + totalHeight) / 2 - meterHeight

func render(_ name: String, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

func meterRect(_ index: Int, fraction: CGFloat) -> CGRect {
    let y = topY - CGFloat(index) * (meterHeight + gap)
    return CGRect(x: originX, y: y, width: meterWidth * fraction, height: meterHeight)
}

func capsule(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

render("tracks.png") { ctx in
    ctx.setFillColor(NSColor.white.cgColor)
    for index in 0..<3 {
        ctx.addPath(capsule(meterRect(index, fraction: 1)))
    }
    ctx.fillPath()
}

render("fills.png") { ctx in
    ctx.setFillColor(NSColor.white.cgColor)
    for (index, fraction) in fills.enumerated() {
        ctx.addPath(capsule(meterRect(index, fraction: fraction)))
    }
    ctx.fillPath()
}
