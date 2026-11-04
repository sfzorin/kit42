import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Realistic inputs for the virtual scanner and the pipeline tests (developer tool, not localised):
/// a skewed A4 page on a grey glass with a shadow, three photos on the glass, and feeder pages
/// (straight, blank with noise, skewed, upside down, yellowed with a shadow, turned sideways).
enum TestImages {
    static let dpi = 200.0

    static let heading = "Invoice No. 4217 — Счёт № 4217"
    static let paragraphs = [
        "Thank you for your order. This document confirms the delivery of twelve boxes of printer paper and two scanner lamps to the main office.",
        "Payment is due within thirty days. Please quote the invoice number when you pay, so that we can match the transfer quickly.",
        "Спасибо за заказ. Документ подтверждает доставку бумаги для принтера и двух ламп для сканера в главный офис.",
        "Teşekkür ederiz. Bu belge, kağıt ve tarayıcı lambalarının teslim edildiğini onaylar.",
        "Questions about this invoice can be sent to the accounts department at any time during working hours.",
    ]

    /// Writes every test input into `folder` and returns the file names.
    @discardableResult
    static func write(to folder: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var names: [String] = []
        func save(_ image: CGImage?, _ name: String) throws {
            guard let image else { return }
            try png(image, dpi: dpi).write(to: folder.appendingPathComponent(name))
            names.append(name)
        }
        try save(documentOnGlass(angle: 5), "glass-1-document.png")
        try save(photosOnGlass(), "glass-2-photos.png")
        try save(documentOnGlass(angle: -3.5, small: true), "glass-3-receipt.png")
        try save(feederPage(1, skew: 0), "feed-1.png")
        try save(blankPage(), "feed-2-blank.png")
        try save(feederPage(3, skew: 3), "feed-3-skewed.png")
        try save(feederPage(4, skew: 0, turn: 180), "feed-4-upside-down.png")
        try save(feederPage(5, skew: 1.5, yellowed: true), "feed-5-yellowed.png")
        try save(feederPage(6, skew: 0, turn: 90), "feed-6-sideways.png")
        return names
    }

    static func png(_ image: CGImage, dpi: Double) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    // MARK: - Drawing

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }

    /// Text page content in a rect of `size` points-as-pixels (origin bottom-left of the page).
    static func drawText(_ ctx: CGContext, size: CGSize, scale: CGFloat, page: Int) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let margin = 0.9 * 72 * scale
        var y = size.height - margin
        let head = NSAttributedString(string: heading, attributes: [.font: NSFont.boldSystemFont(ofSize: 20 * scale), .foregroundColor: NSColor(white: 0.08, alpha: 1)])
        y -= head.size().height
        head.draw(at: NSPoint(x: margin, y: y))
        let sub = NSAttributedString(string: "Page \(page) · 4 November 2026", attributes: [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: NSColor(white: 0.3, alpha: 1)])
        y -= sub.size().height + 10 * scale
        sub.draw(at: NSPoint(x: margin, y: y))
        y -= 24 * scale
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3 * scale
        for p in paragraphs + paragraphs.prefix(3) {
            let s = NSAttributedString(string: p, attributes: [.font: NSFont(name: "Times New Roman", size: 12.5 * scale) ?? NSFont.systemFont(ofSize: 12.5 * scale),
                                                               .foregroundColor: NSColor(white: 0.1, alpha: 1), .paragraphStyle: style])
            let r = s.boundingRect(with: NSSize(width: size.width - 2 * margin, height: 2000 * scale), options: [.usesLineFragmentOrigin])
            y -= r.height
            guard y > margin else { break }
            s.draw(with: NSRect(x: margin, y: y, width: size.width - 2 * margin, height: r.height), options: [.usesLineFragmentOrigin])
            y -= 12 * scale
        }
        // A table-like block of figures.
        let rows = [("Paper A4, 80 g/m²", "12", "54.00"), ("Scanner lamp", "2", "38.50"), ("Total", "", "92.50")]
        for (a, b, c) in rows where y > margin + 30 * scale {
            y -= 18 * scale
            let f: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12 * scale, weight: a == "Total" ? .bold : .regular), .foregroundColor: NSColor(white: 0.1, alpha: 1)]
            NSAttributedString(string: a, attributes: f).draw(at: NSPoint(x: margin, y: y))
            NSAttributedString(string: b, attributes: f).draw(at: NSPoint(x: size.width * 0.6, y: y))
            NSAttributedString(string: c, attributes: f).draw(at: NSPoint(x: size.width * 0.78, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func glassBackground(_ ctx: CGContext, _ w: Int, _ h: Int) {
        let colors = [CGColor(srgbRed: 0.56, green: 0.57, blue: 0.59, alpha: 1), CGColor(srgbRed: 0.50, green: 0.51, blue: 0.53, alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }

    /// Grain like a scanner sensor.
    static func addNoise(_ image: CGImage, amount: Int, specks: Int = 0, seed: UInt64 = 42) -> CGImage {
        var bmp = Bitmap(image, gray: false)
        var s = seed
        func rnd() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        bmp.data.withUnsafeMutableBufferPointer { d in
            for i in 0..<(bmp.width * bmp.height) {
                let n = Int(rnd() % UInt64(2 * amount + 1)) - amount
                for c in 0..<3 { d[i * 4 + c] = UInt8(max(0, min(255, Int(d[i * 4 + c]) + n))) }
            }
            for _ in 0..<specks {
                let x = Int(rnd() % UInt64(bmp.width - 2)), y = Int(rnd() % UInt64(bmp.height - 2))
                for (dx, dy) in [(0, 0), (1, 0), (0, 1)] { for c in 0..<3 { d[((y + dy) * bmp.width + x + dx) * 4 + c] = 90 } }
            }
        }
        return bmp.cgImage() ?? image
    }

    /// An A4 page (or a receipt-sized slip) lying tilted on a grey glass, with a soft shadow.
    static func documentOnGlass(angle: Double, small: Bool = false) -> CGImage? {
        let w = Int(10 * dpi), h = Int(13.3 * dpi)
        let ctx = context(w, h)
        glassBackground(ctx, w, h)
        let page = small ? CGSize(width: 3.2 * dpi, height: 7.5 * dpi) : CGSize(width: 8.27 * dpi, height: 11.69 * dpi)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(w) / 2 + (small ? -120 : 10), y: CGFloat(h) / 2 + (small ? 200 : -20))
        ctx.rotate(by: -angle * .pi / 180)
        ctx.translateBy(x: -page.width / 2, y: -page.height / 2)
        ctx.setShadow(offset: CGSize(width: 10, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.55))
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: page))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        drawText(ctx, size: page, scale: CGFloat(dpi / 72) * (small ? 0.8 : 1), page: 1)
        ctx.restoreGState()
        return ctx.makeImage().map { addNoise($0, amount: 5) }
    }

    /// Three photos (different sizes and angles) on the glass.
    static func photosOnGlass() -> CGImage? {
        let w = Int(10 * dpi), h = Int(13.3 * dpi)
        let ctx = context(w, h)
        glassBackground(ctx, w, h)
        let photos: [(CGPoint, CGSize, Double, [CGFloat], Bool)] = [
            (CGPoint(x: 0.28, y: 0.78), CGSize(width: 4, height: 3), -4, [0.95, 0.55, 0.25], false),
            (CGPoint(x: 0.72, y: 0.72), CGSize(width: 3, height: 4.2), 3, [0.25, 0.55, 0.9], true),
            (CGPoint(x: 0.42, y: 0.28), CGSize(width: 5, height: 3.4), 7, [0.3, 0.7, 0.35], false),
        ]
        for (center, inches, angle, tint, border) in photos {
            let size = CGSize(width: inches.width * dpi, height: inches.height * dpi)
            ctx.saveGState()
            ctx.translateBy(x: center.x * CGFloat(w), y: center.y * CGFloat(h))
            ctx.rotate(by: -angle * .pi / 180)
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
            ctx.setShadow(offset: CGSize(width: 6, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.5))
            ctx.setFillColor(CGColor(gray: border ? 0.97 : 0.2, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let inner = border ? CGRect(origin: .zero, size: size).insetBy(dx: 0.18 * dpi, dy: 0.18 * dpi) : CGRect(origin: .zero, size: size)
            drawPhoto(ctx, inner, tint)
            ctx.restoreGState()
        }
        return ctx.makeImage().map { addNoise($0, amount: 5) }
    }

    /// Sky, sun and hills in a tint.
    static func drawPhoto(_ ctx: CGContext, _ r: CGRect, _ t: [CGFloat]) {
        ctx.saveGState()
        ctx.clip(to: r)
        let sky = [CGColor(srgbRed: min(1, t[0] + 0.3), green: min(1, t[1] + 0.3), blue: min(1, t[2] + 0.35), alpha: 1),
                   CGColor(srgbRed: t[0], green: t[1], blue: t[2], alpha: 1)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sky, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: r.maxX - r.width * 0.35, y: r.maxY - r.height * 0.4, width: r.width * 0.18, height: r.width * 0.18))
        ctx.setFillColor(CGColor(srgbRed: t[0] * 0.45, green: t[1] * 0.45, blue: t[2] * 0.45, alpha: 1))
        ctx.move(to: CGPoint(x: r.minX, y: r.minY))
        ctx.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.35))
        ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.35, y: r.minY + r.height * 0.6))
        ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.7, y: r.minY + r.height * 0.3))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.45))
        ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// A full-frame feeder page: optional skew, quarter turns and old yellowed paper with a light falloff.
    static func feederPage(_ n: Int, skew: Double, turn: Int = 0, yellowed: Bool = false, dpi d: Double = dpi) -> CGImage? {
        let pw = Int(8.27 * d), ph = Int(11.69 * d)
        let ctx = context(pw, ph)
        let paper = yellowed ? CGColor(srgbRed: 0.93, green: 0.87, blue: 0.70, alpha: 1) : CGColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(pw) / 2, y: CGFloat(ph) / 2)
        ctx.rotate(by: -skew * .pi / 180)
        ctx.translateBy(x: -CGFloat(pw) / 2, y: -CGFloat(ph) / 2)
        ctx.setFillColor(paper)
        ctx.fill(CGRect(x: -40, y: -40, width: pw + 80, height: ph + 80))
        drawText(ctx, size: CGSize(width: pw, height: ph), scale: CGFloat(d / 72), page: n)
        ctx.restoreGState()
        if yellowed {
            // Shadow from a book spine on the left.
            let colors = [CGColor(gray: 0, alpha: 0.45), CGColor(gray: 0, alpha: 0)] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: CGFloat(pw) * 0.35, y: 0), options: [])
        }
        guard var image = ctx.makeImage() else { return nil }
        if turn != 0, let r = Processor.rotate90(image, clockwise: turn) { image = r }
        return addNoise(image, amount: 4)
    }

    /// An empty page with sensor noise and a few dust specks.
    static func blankPage() -> CGImage? {
        let pw = Int(8.27 * dpi), ph = Int(11.69 * dpi)
        let ctx = context(pw, ph)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        return ctx.makeImage().map { addNoise($0, amount: 8, specks: 40, seed: 7) }
    }
}
