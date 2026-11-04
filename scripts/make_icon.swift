// Renders AppIcon.icns for a Suite42 app.
// usage: swift make_icon.swift <out-dir> <LABEL> <r1 g1 b1> <r2 g2 b2>
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args[1])
let label = args[2]
let c = args[3...].compactMap { Double($0) }.map { CGFloat($0) }
let top = NSColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
let bottom = NSColor(red: c[3], green: c[4], blue: c[5], alpha: 1)

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with a soft shadow.
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset * 1.1, width: s - inset * 2, height: s - inset * 2)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    let body = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor.white.setFill()
    body.fill()
    NSShadow().set()

    // Coloured header band
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    let band = NSRect(x: rect.minX, y: rect.maxY - rect.height * 0.36, width: rect.width, height: rect.height * 0.36)
    NSGradient(starting: top, ending: bottom)!.draw(in: band, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.15, weight: .bold),
        .foregroundColor: NSColor.white,
        .kern: s * 0.004,
    ]
    let ls = (label as NSString).size(withAttributes: labelAttrs)
    (label as NSString).draw(at: NSPoint(x: rect.midX - ls.width / 2, y: band.midY - ls.height / 2), withAttributes: labelAttrs)

    // Text lines
    NSColor(white: 0.86, alpha: 1).setFill()
    for i in 0..<3 {
        let w = rect.width * (i == 2 ? 0.34 : 0.62)
        NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.12, y: band.minY - s * (0.09 + CGFloat(i) * 0.065),
                                         width: w, height: s * 0.028), xRadius: s * 0.014, yRadius: s * 0.014).fill()
    }

    let num = "42" as NSString
    let numAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.2, weight: .heavy),
        .foregroundColor: bottom,
    ]
    let ns = num.size(withAttributes: numAttrs)
    num.draw(at: NSPoint(x: rect.maxX - ns.width - rect.width * 0.1, y: rect.minY + rect.height * 0.04), withAttributes: numAttrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
