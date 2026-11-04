// Draws AppIcon.iconset (16…1024 px) for a Suite42 app, macOS 11+ style.
// usage: swift make_icon.swift <out-dir> <PDF42|DOC42|XLS42|IMG42|PPT42> [preview.png]
//
// Family look: a coloured squircle (Apple icon grid: 824/1024 body, 100 px margins, soft drop shadow)
// carrying a white document sheet with a folded corner; the sheet shows what the app is about.
// Sizes ≤ 32 px use a simplified drawing with fewer, thicker marks so they stay recognisable.
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args[1])
let app = args[2]

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Background gradient (top, bottom) and the mark colour on the sheet.
let palette: [String: (top: NSColor, bottom: NSColor, mark: NSColor)] = [
    "PDF42": (rgb(0xFF6A5C), rgb(0xD81E35), rgb(0xE2283A)),
    "DOC42": (rgb(0x4FA3FF), rgb(0x1659D6), rgb(0x1E63E0)),
    "XLS42": (rgb(0x3FD486), rgb(0x0E8A4A), rgb(0x12924F)),
    "IMG42": (rgb(0xB57CFF), rgb(0x6A2BD9), rgb(0x7A3BE6)),
    "PPT42": (rgb(0xFFB547), rgb(0xE5671A), rgb(0xEC6F1C)),
]
guard let colors = palette[app] else { fatalError("unknown app \(app)") }

/// Superellipse (n = 5) — close to Apple's continuous-corner icon shape.
func squircle(_ r: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let n: CGFloat = 5, steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c)
        let y = r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? p.move(to: NSPoint(x: x, y: y)) : p.line(to: NSPoint(x: x, y: y))
    }
    p.close()
    return p
}

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

func withShadow(_ color: NSColor, blur: CGFloat, dy: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = color
    sh.shadowBlurRadius = blur
    sh.shadowOffset = NSSize(width: 0, height: dy)
    sh.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Sheet outline with the top-right corner cut for the fold.
func sheetPath(_ r: NSRect, fold: CGFloat, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX + radius, y: r.minY))
    p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
    p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
    p.line(to: NSPoint(x: r.maxX, y: r.maxY - fold))
    p.line(to: NSPoint(x: r.maxX - fold, y: r.maxY))
    p.line(to: NSPoint(x: r.minX + radius, y: r.maxY))
    p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 180)
    p.line(to: NSPoint(x: r.minX, y: r.minY + radius))
    p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
    p.close()
    return p
}

/// Draws in a 1024×1024 coordinate space (origin bottom-left).
func drawIcon(small: Bool) {
    // Body
    let body = squircle(NSRect(x: 100, y: 100, width: 824, height: 824))
    withShadow(NSColor.black.withAlphaComponent(0.28), blur: 28, dy: -12) {
        colors.bottom.setFill()
        body.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    NSGradient(starting: colors.top, ending: colors.bottom)!.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824), angle: -90)
    // Soft top light
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.18).setStroke()
    body.lineWidth = 4
    body.stroke()

    // Sheet
    let sheet = small ? NSRect(x: 262, y: 196, width: 500, height: 632) : NSRect(x: 282, y: 206, width: 460, height: 612)
    let fold: CGFloat = small ? 150 : 132
    let outline = sheetPath(sheet, fold: fold, radius: small ? 30 : 26)
    withShadow(NSColor.black.withAlphaComponent(0.30), blur: 34, dy: -14) {
        NSColor.white.setFill()
        outline.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    NSGradient(starting: .white, ending: rgb(0xEEF0F4))!.draw(in: sheet, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Folded corner
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
    corner.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 18))
    corner.curve(to: NSPoint(x: sheet.maxX - fold + 18, y: sheet.maxY - fold),
                 controlPoint1: NSPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 8), controlPoint2: NSPoint(x: sheet.maxX - fold + 8, y: sheet.maxY - fold))
    corner.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
    corner.close()
    withShadow(NSColor.black.withAlphaComponent(0.22), blur: 14, dy: -6) {
        rgb(0xD9DDE5).setFill()
        corner.fill()
    }
    NSGradient(starting: rgb(0xF7F8FA), ending: rgb(0xCDD2DC))!.draw(in: corner, angle: -45)

    // Content area of the sheet
    let inner = NSRect(x: sheet.minX + 56, y: sheet.minY + 60, width: sheet.width - 112, height: sheet.height - 120 - fold * 0.35)
    let gray = rgb(0xC3C8D2)
    let mark = colors.mark

    switch app {
    case "PDF42":
        // Text lines above a red "PDF" label.
        let lines = small ? 2 : 4
        for i in 0..<lines {
            let w = inner.width * (i == lines - 1 ? 0.55 : (i == 0 ? 0.62 : 1)) * (small ? 1 : 1)
            let h: CGFloat = small ? 34 : 22
            let y = inner.maxY - CGFloat(i) * (small ? 70 : 50) - h - (small ? 10 : 0)
            gray.setFill()
            rounded(NSRect(x: inner.minX, y: y, width: i == 0 ? w * (small ? 1 : 0.7) : w, height: h), h / 2).fill()
        }
        // Small sizes keep the label inside the sheet so the white edge separates it from the red body.
        let label = small ? NSRect(x: sheet.minX + 44, y: sheet.minY + 64, width: sheet.width - 88, height: 250)
            : NSRect(x: sheet.minX - 34, y: sheet.minY + 88, width: sheet.width + 68, height: 196)
        withShadow(NSColor.black.withAlphaComponent(0.25), blur: 16, dy: -6) {
            mark.setFill()
            rounded(label, small ? 44 : 36).fill()
        }
        NSGradient(starting: rgb(0xFF5A4E), ending: rgb(0xCC1730))!.draw(in: rounded(label, small ? 44 : 36), angle: -90)
        if !small {
            let font = NSFont.systemFont(ofSize: 150, weight: .heavy)
            let text = NSAttributedString(string: "PDF", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 6])
            let sz = text.size()
            text.draw(at: NSPoint(x: label.midX - sz.width / 2 + 3, y: label.midY - sz.height / 2 + 4))
        } else {
            NSColor.white.setFill()
            rounded(NSRect(x: label.minX + 60, y: label.midY - 26, width: label.width - 120, height: 52), 26).fill()
        }

    case "DOC42":
        // Heading bar and paragraphs of text lines.
        let lineH: CGFloat = small ? 40 : 22
        let gap: CGFloat = small ? 82 : 44
        var y = inner.maxY - (small ? 40 : 34)
        mark.setFill()
        rounded(NSRect(x: inner.minX, y: y, width: inner.width * 0.62, height: small ? 52 : 34), small ? 26 : 17).fill()
        y -= small ? 100 : 74
        let widths: [CGFloat] = small ? [1, 1, 0.7, 1] : [1, 1, 0.92, 0.6, 0, 1, 0.96, 1, 0.7]
        for w in widths {
            if w > 0 {
                (small ? rgb(0x8FA6C9) : rgb(0xA9B8CF)).setFill()
                rounded(NSRect(x: inner.minX, y: y, width: inner.width * w, height: lineH), lineH / 2).fill()
            }
            y -= gap
        }

    case "XLS42":
        // Grid with a coloured header row and first column.
        let rows = small ? 4 : 6, cols = small ? 2 : 3
        let grid = NSRect(x: inner.minX - 10, y: inner.minY + 8, width: inner.width + 20, height: inner.height - 30)
        let rh = grid.height / CGFloat(rows), cw = grid.width / CGFloat(cols)
        mark.withAlphaComponent(0.14).setFill()
        NSRect(x: grid.minX, y: grid.minY, width: cw, height: grid.height).fill()
        mark.setFill()
        rounded(NSRect(x: grid.minX, y: grid.maxY - rh, width: grid.width, height: rh), small ? 18 : 12).fill()
        NSRect(x: grid.minX, y: grid.maxY - rh, width: grid.width, height: rh / 2).fill()
        mark.withAlphaComponent(0.55).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = small ? 16 : 7
        for r in 1..<rows { lines.move(to: NSPoint(x: grid.minX, y: grid.minY + CGFloat(r) * rh)); lines.line(to: NSPoint(x: grid.maxX, y: grid.minY + CGFloat(r) * rh)) }
        for c in 1..<cols { lines.move(to: NSPoint(x: grid.minX + CGFloat(c) * cw, y: grid.minY)); lines.line(to: NSPoint(x: grid.minX + CGFloat(c) * cw, y: grid.maxY - rh)) }
        lines.stroke()
        let frame = rounded(grid, small ? 18 : 12)
        frame.lineWidth = small ? 16 : 7
        frame.stroke()
        if !small {
            // A few values in the cells
            rgb(0x6E8F7C).setFill()
            for r in 0..<(rows - 1) {
                for c in 1..<cols where (r + c) % 3 != 0 {
                    let w = cw * (0.35 + CGFloat((r * 7 + c * 3) % 4) * 0.1)
                    rounded(NSRect(x: grid.minX + CGFloat(c + 1) * cw - w - 22, y: grid.minY + CGFloat(r) * rh + rh / 2 - 9, width: w, height: 18), 9).fill()
                }
            }
        }

    case "PPT42":
        // A slide (landscape, orange title bar) with a bar chart, and a pie under it.
        let slide = NSRect(x: inner.minX - 18, y: inner.maxY - (small ? 300 : 262), width: inner.width + 36, height: small ? 290 : 248)
        let slidePath = rounded(slide, small ? 26 : 18)
        rgb(0xFFF3E6).setFill()
        slidePath.fill()
        mark.setStroke()
        slidePath.lineWidth = small ? 16 : 8
        slidePath.stroke()
        // Title bar
        mark.setFill()
        rounded(NSRect(x: slide.minX + (small ? 40 : 34), y: slide.maxY - (small ? 82 : 62), width: slide.width * 0.5, height: small ? 36 : 24), small ? 18 : 12).fill()
        // Bars
        let heights: [CGFloat] = small ? [0.35, 0.7] : [0.3, 0.55, 0.42, 0.8]
        let base = slide.minY + (small ? 36 : 30)
        let maxH = slide.height - (small ? 140 : 112)
        let bw: CGFloat = small ? 70 : 42
        let gap = (slide.width - (small ? 80 : 68) - bw * CGFloat(heights.count)) / CGFloat(max(1, heights.count - 1))
        for (i, h) in heights.enumerated() {
            (i == heights.count - 1 ? mark : rgb(0xF5A25A)).setFill()
            rounded(NSRect(x: slide.minX + (small ? 40 : 34) + CGFloat(i) * (bw + gap), y: base, width: bw, height: maxH * h), small ? 10 : 7).fill()
        }
        // Pie and legend lines below the slide
        let pieR: CGFloat = small ? 78 : 64
        let pieCenter = NSPoint(x: inner.minX + pieR + 4, y: slide.minY - (small ? 40 : 46) - pieR)
        rgb(0xF5A25A).setFill()
        NSBezierPath(ovalIn: NSRect(x: pieCenter.x - pieR, y: pieCenter.y - pieR, width: pieR * 2, height: pieR * 2)).fill()
        let wedge = NSBezierPath()
        wedge.move(to: pieCenter)
        wedge.appendArc(withCenter: pieCenter, radius: pieR, startAngle: 90, endAngle: -30, clockwise: true)
        wedge.close()
        mark.setFill()
        wedge.fill()
        if !small {
            gray.setFill()
            for i in 0..<3 {
                rounded(NSRect(x: pieCenter.x + pieR + 36, y: pieCenter.y + 34 - CGFloat(i) * 42, width: inner.width - pieR * 2 - 40 - CGFloat(i) * 30, height: 20), 10).fill()
            }
        }

    default: // IMG42
        // Landscape photo: sky, sun, two mountains.
        let photo = NSRect(x: inner.minX - 16, y: inner.minY + (small ? 10 : 40), width: inner.width + 32, height: inner.height - (small ? 20 : 60))
        let frame = rounded(photo, small ? 30 : 22)
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        NSGradient(starting: rgb(0xD9C6FF), ending: rgb(0x9C6CF5))!.draw(in: photo, angle: -90)
        rgb(0xFFD35A).setFill()
        let sunR = photo.width * (small ? 0.16 : 0.13)
        NSBezierPath(ovalIn: NSRect(x: photo.maxX - photo.width * 0.32 - sunR, y: photo.maxY - photo.height * 0.3 - sunR, width: sunR * 2, height: sunR * 2)).fill()
        let back = NSBezierPath()
        back.move(to: NSPoint(x: photo.minX + photo.width * 0.25, y: photo.minY))
        back.line(to: NSPoint(x: photo.minX + photo.width * 0.66, y: photo.minY + photo.height * 0.62))
        back.line(to: NSPoint(x: photo.maxX + 40, y: photo.minY + photo.height * 0.18))
        back.line(to: NSPoint(x: photo.maxX + 40, y: photo.minY))
        back.close()
        rgb(0x7B45DB).setFill()
        back.fill()
        let front = NSBezierPath()
        front.move(to: NSPoint(x: photo.minX - 40, y: photo.minY))
        front.line(to: NSPoint(x: photo.minX - 40, y: photo.minY + photo.height * 0.22))
        front.line(to: NSPoint(x: photo.minX + photo.width * 0.32, y: photo.minY + photo.height * 0.56))
        front.line(to: NSPoint(x: photo.minX + photo.width * 0.78, y: photo.minY))
        front.close()
        rgb(0x5A23B8).setFill()
        front.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let t = NSAffineTransform()
    t.scale(by: CGFloat(px) / 1024)
    t.concat()
    drawIcon(small: px <= 32)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
