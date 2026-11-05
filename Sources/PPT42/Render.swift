import AppKit
import Kit42

/// Decoded pictures by media name (data identity checked by size and a prefix hash).
enum MediaCache {
    private static var images: [String: (Int, NSImage)] = [:]

    static func image(_ name: String, _ data: Data?) -> NSImage? {
        guard let data else { return nil }
        let key = data.count ^ data.prefix(64).hashValue
        if let (k, img) = images[name], k == key { return img }
        guard let img = NSImage(data: data) else { return nil }
        images[name] = (key, img)
        return img
    }
}

struct RenderOptions {
    /// Editing view: placeholder prompts and outlines of empty placeholders.
    var editing = false
    /// Objects not drawn (pending builds in the slide show, the object whose text is being edited draws without text).
    var hidden: Set<Int> = []
    var textHidden: Set<Int> = []
    /// 1-based number for slide-number fields.
    var number = 1
    /// Only the slide's own objects (no background, master or layout shapes): build animations.
    var objectsOnly = false
}

enum Renderer {
    // MARK: - Slide

    /// Draws a slide in slide coordinates (points, y down) into a flipped context.
    static func draw(_ slide: Slide, deck: Deck, in ctx: CGContext, options: RenderOptions = RenderOptions()) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = CGRect(origin: .zero, size: deck.size)
        ctx.saveGState()
        ctx.clip(to: bounds)
        let layout = deck.layout(of: slide)
        if !options.objectsOnly {
            drawFill(slide.background ?? layout?.background ?? deck.master.background, in: CGPath(rect: bounds, transform: nil), bounds: bounds, deck: deck, ctx: ctx)
            if slide.showMasterShapes && (layout?.showMasterShapes ?? true) {
                for o in deck.master.objects { drawObject(o, slide: nil, deck: deck, ctx: ctx, options: options) }
            }
            for o in layout?.objects ?? [] { drawObject(o, slide: nil, deck: deck, ctx: ctx, options: options) }
        }
        for o in slide.objects where !options.hidden.contains(o.id) {
            drawObject(o, slide: slide, deck: deck, ctx: ctx, options: options)
        }
        ctx.restoreGState()
    }

    /// Master view: master background and shapes, then the sample placeholders (master styles only) with dashed outlines.
    static func drawMaster(deck: Deck, objects: [SlideObject], in ctx: CGContext, textHidden: Set<Int> = []) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = CGRect(origin: .zero, size: deck.size)
        drawFill(deck.master.background, in: CGPath(rect: bounds, transform: nil), bounds: bounds, deck: deck, ctx: ctx)
        var options = RenderOptions()
        options.textHidden = textHidden
        for o in deck.master.objects { drawObject(o, slide: nil, deck: deck, ctx: ctx, options: options) }
        for o in objects {
            drawObject(o, slide: nil, deck: deck, ctx: ctx, options: options)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.6).cgColor)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.setLineWidth(0.75)
            ctx.stroke(o.frame)
            ctx.restoreGState()
        }
    }

    // MARK: - Objects

    static func transform(for o: SlideObject, ctx: CGContext, flips: Bool) {
        let f = o.frame
        ctx.translateBy(x: f.midX, y: f.midY)
        if o.rotation != 0 { ctx.rotate(by: o.rotation * .pi / 180) }
        if flips { ctx.scaleBy(x: o.flipH ? -1 : 1, y: o.flipV ? -1 : 1) }
        ctx.translateBy(x: -f.width / 2, y: -f.height / 2)
    }

    static func deviceScale(_ ctx: CGContext) -> CGFloat {
        let m = ctx.ctm
        return max(0.01, hypot(m.a, m.b))
    }

    static func setShadow(_ ctx: CGContext) {
        let s = deviceScale(ctx)
        ctx.setShadow(offset: CGSize(width: 2.5 * s, height: -2.5 * s), blur: 5 * s, color: NSColor.black.withAlphaComponent(0.38).cgColor)
    }

    static func drawObject(_ o: SlideObject, slide: Slide?, deck: Deck, ctx: CGContext, options: RenderOptions) {
        if options.hidden.contains(o.id) { return }
        // Empty placeholders are only hints for editing.
        if let ph = o.placeholder, o.kind != .picture, o.kind != .table, (o.text?.isEmpty ?? true) {
            if options.editing && slide != nil { drawPrompt(o, ph: ph, slide: slide, deck: deck, ctx: ctx) }
            return
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if o.opacity < 1 {
            ctx.setAlpha(o.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if o.opacity < 1 { ctx.endTransparencyLayer() } }

        switch o.kind {
        case .group:
            if o.rotation != 0 {
                ctx.translateBy(x: o.frame.midX, y: o.frame.midY)
                ctx.rotate(by: o.rotation * .pi / 180)
                ctx.translateBy(x: -o.frame.midX, y: -o.frame.midY)
            }
            for c in o.children { drawObject(c, slide: slide, deck: deck, ctx: ctx, options: options) }
            return
        case .line:
            drawLine(o, deck: deck, ctx: ctx)
            return
        case .picture:
            drawPicture(o, deck: deck, ctx: ctx)
            if options.editing, let clip = o.clip { drawMediaBadge(o, audio: clip.audio, ctx: ctx) }
        case .table:
            ctx.saveGState()
            transform(for: o, ctx: ctx, flips: false)
            if let t = o.table { drawTable(t, object: o, slide: slide, deck: deck, ctx: ctx, options: options) }
            ctx.restoreGState()
            return
        case .chart:
            ctx.saveGState()
            transform(for: o, ctx: ctx, flips: false)
            let box = CGRect(origin: .zero, size: o.frame.size)
            if !o.fill.isNone { drawFill(o.fill, in: CGPath(rect: box, transform: nil), bounds: box, deck: deck, ctx: ctx) }
            if let m = o.chart { ChartRenderer.draw(m, deck: deck, in: box, ctx: ctx) }
            if o.line.color != nil { stroke(CGPath(rect: box, transform: nil), o.line, deck: deck, ctx: ctx) }
            ctx.restoreGState()
            return
        case .shape, .textBox:
            ctx.saveGState()
            transform(for: o, ctx: ctx, flips: true)
            let subs = Shapes.subpaths(o)
            if o.shadow && (!o.fill.isNone || o.line.color != nil) { setShadow(ctx) }
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let box = CGRect(origin: .zero, size: o.frame.size)
            for sp in subs where sp.fill != .none && !o.fill.isNone {
                drawFill(o.fill, in: sp.path, bounds: box, deck: deck, ctx: ctx)
                if sp.fill != .norm {
                    // Shading of parts that look 3-D (can top, folded corner…).
                    let dark = sp.fill == .darken || sp.fill == .darkenLess
                    let k: CGFloat = sp.fill == .darken || sp.fill == .lighten ? 0.4 : 0.2
                    ctx.saveGState()
                    ctx.addPath(sp.path)
                    ctx.setFillColor((dark ? NSColor.black : NSColor.white).withAlphaComponent(k).cgColor)
                    ctx.fillPath(using: .evenOdd)
                    ctx.restoreGState()
                }
            }
            if o.line.color != nil { for sp in subs where sp.stroke { stroke(sp.path, o.line, deck: deck, ctx: ctx) } }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if o.unsupported != nil, o.media == nil {
            ctx.saveGState()
            transform(for: o, ctx: ctx, flips: false)
            let r = CGRect(origin: .zero, size: o.frame.size)
            ctx.setStrokeColor(NSColor(white: 0.6, alpha: 1).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
            let s = NSAttributedString(string: o.unsupported ?? "", attributes: [.font: NSFont(name: "Helvetica Neue", size: 12) ?? .systemFont(ofSize: 12),
                                                                                  .foregroundColor: NSColor(white: 0.45, alpha: 1)])
            s.draw(at: CGPoint(x: 6, y: 6))
            ctx.restoreGState()
        }
        if let body = o.text, !options.textHidden.contains(o.id), !body.isEmpty {
            ctx.saveGState()
            transform(for: o, ctx: ctx, flips: false)
            drawText(body, object: o, slide: slide, deck: deck, number: options.number, in: textFrame(o), ctx: ctx)
            ctx.restoreGState()
        }
    }

    /// Text area of an object in its own coordinates (geometry text rect minus insets).
    static func textFrame(_ o: SlideObject) -> CGRect {
        let insets = o.text?.insets ?? NSEdgeInsets()
        let r = Shapes.textRect(o)
        return CGRect(x: r.minX + insets.left, y: r.minY + insets.top,
                      width: max(1, r.width - insets.left - insets.right), height: max(1, r.height - insets.top - insets.bottom))
    }

    /// Font scale that makes the text fit (shrink on overflow).
    static func fitScale(_ body: TextBody, _ c: TextContext, width: CGFloat, height: CGFloat) -> CGFloat {
        guard body.autofit == .shrink else { return 1 }
        var cc = c
        cc.scale = 1
        if TextLayout(TextRender.attributed(body, cc), width: width).usedHeight <= height + 0.5 { return 1 }
        var lo: CGFloat = 0.25, hi: CGFloat = 1
        for _ in 0..<7 {
            let mid = (lo + hi) / 2
            cc.scale = mid
            if TextLayout(TextRender.attributed(body, cc), width: width).usedHeight <= height { lo = mid } else { hi = mid }
        }
        return lo
    }

    static func drawText(_ body: TextBody, object: SlideObject, slide: Slide?, deck: Deck, number: Int, in rect: CGRect, ctx: CGContext,
                         cellDefaults: RunProps? = nil) {
        var c = TextContext(deck: deck, slide: slide, object: object, number: number, cellDefaults: cellDefaults)
        let width = body.wrap ? rect.width : 10000
        c.scale = fitScale(body, c, width: width, height: rect.height)
        let layout = TextLayout(TextRender.attributed(body, c), width: width)
        let h = layout.usedHeight
        var y = rect.minY
        switch body.anchor {
        case .top: break
        case .middle: y = rect.minY + (rect.height - h) / 2
        case .bottom: y = rect.maxY - h
        }
        var x = rect.minX
        if !body.wrap {
            // Unwrapped text keeps its alignment around the box.
            let w = layout.usedWidth
            let align = body.paragraphs.first.map { $0.props.over(TextRender.levelStyle(c, level: $0.level)).align ?? .left } ?? .left
            if align == .center { x = rect.midX - w / 2 } else if align == .right { x = rect.maxX - w }
            layout.container.size = CGSize(width: w + 1, height: .greatestFiniteMagnitude)
        }
        layout.draw(at: CGPoint(x: x, y: y))
    }

    static func drawPrompt(_ o: SlideObject, ph: Placeholder, slide: Slide?, deck: Deck, ctx: CGContext) {
        ctx.saveGState()
        transform(for: o, ctx: ctx, flips: false)
        let r = CGRect(origin: .zero, size: o.frame.size)
        ctx.setStrokeColor(NSColor(white: 0.55, alpha: 0.7).cgColor)
        ctx.setLineWidth(0.75)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        ctx.setLineDash(phase: 0, lengths: [])
        if ph.type == "pic" {
            let s = NSAttributedString(string: L("Click to add picture"), attributes: [.font: NSFont(name: "Helvetica Neue", size: 14) ?? .systemFont(ofSize: 14),
                                                                                       .foregroundColor: NSColor(white: 0.5, alpha: 1)])
            let sz = s.size()
            if let img = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 28, weight: .light)) {
                let tinted = NSImage(size: img.size, flipped: false) { b in img.draw(in: b); NSColor(white: 0.55, alpha: 1).set(); b.fill(using: .sourceAtop); return true }
                tinted.draw(in: CGRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height - 4, width: img.size.width, height: img.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY + 6))
        } else if !ph.isFooter, let body = o.text {
            let prompt = ph.isTitle ? L("Click to add title") : ph.type == "subTitle" ? L("Click to add subtitle") : L("Click to add text")
            var c = TextContext(deck: deck, slide: slide, object: o)
            c.scale = 1
            let rect = textFrame(o)
            let layout = TextLayout(TextRender.attributed(body, c, prompt: prompt), width: rect.width)
            let h = layout.usedHeight
            let y = body.anchor == .middle ? rect.minY + (rect.height - h) / 2 : body.anchor == .bottom ? rect.maxY - h : rect.minY
            layout.draw(at: CGPoint(x: rect.minX, y: y))
        }
        ctx.restoreGState()
    }

    // MARK: - Fill and stroke

    static func drawFill(_ fill: Fill, in path: CGPath, bounds: CGRect, deck: Deck, ctx: CGContext) {
        switch fill {
        case .none: return
        case .solid(let c):
            ctx.addPath(path)
            ctx.setFillColor(c.resolved(deck.theme).cgColor)
            ctx.fillPath(using: .evenOdd)
        case .gradient(let g):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: .evenOdd)
            let colors = g.stops.map { $0.color.resolved(deck.theme).cgColor } as CFArray
            let locations = g.stops.map(\.position)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else {
                ctx.restoreGState(); return
            }
            if g.radial {
                let c = CGPoint(x: bounds.midX, y: bounds.midY)
                ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: hypot(bounds.width, bounds.height) / 2,
                                       options: [.drawsAfterEndLocation])
            } else {
                let a = g.angle * .pi / 180
                let len = abs(bounds.width * cos(a)) + abs(bounds.height * sin(a))
                let d = CGPoint(x: cos(a) * len / 2, y: sin(a) * len / 2)
                let c = CGPoint(x: bounds.midX, y: bounds.midY)
                ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        case .picture(let name):
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let img = MediaCache.image(name, deck.media[name]) {
                img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            ctx.restoreGState()
        }
    }

    static func stroke(_ path: CGPath, _ line: LineStyle, deck: Deck, ctx: CGContext) {
        guard let color = line.color else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color.resolved(deck.theme).cgColor)
        ctx.setLineWidth(max(0.25, line.width))
        ctx.setLineJoin(.round)
        if line.dash != .solid { ctx.setLineDash(phase: 0, lengths: line.dash.pattern.map { $0 * max(1, line.width) }) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawLine(_ o: SlideObject, deck: Deck, ctx: CGContext) {
        guard let color = o.line.color else { return }
        var a = o.lineStart, b = o.lineEnd
        if o.rotation != 0 {
            let c = CGPoint(x: o.frame.midX, y: o.frame.midY), r = o.rotation * .pi / 180
            func rot(_ p: CGPoint) -> CGPoint {
                CGPoint(x: c.x + (p.x - c.x) * cos(r) - (p.y - c.y) * sin(r), y: c.y + (p.x - c.x) * sin(r) + (p.y - c.y) * cos(r))
            }
            a = rot(a); b = rot(b)
        }
        let w = max(0.25, o.line.width)
        if o.shadow { setShadow(ctx) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Shorten the line under filled heads so the tip stays sharp.
        let len = hypot(b.x - a.x, b.y - a.y)
        func inset(_ p: CGPoint, toward q: CGPoint, _ head: Arrowhead) -> CGPoint {
            guard head != .none, head != .arrow, len > 0 else { return p }
            let d = min(len / 2, max(6, w * 3.5) * 0.8)
            return CGPoint(x: p.x + (q.x - p.x) / len * d, y: p.y + (q.y - p.y) / len * d)
        }
        let path = CGMutablePath()
        path.move(to: inset(a, toward: b, o.line.head))
        path.addLine(to: inset(b, toward: a, o.line.tail))
        stroke(path, o.line, deck: deck, ctx: ctx)
        let cg = color.resolved(deck.theme).cgColor
        for (kind, tip, from) in [(o.line.head, a, b), (o.line.tail, b, a)] {
            guard let head = Shapes.arrowhead(kind, tip: tip, from: from, width: w) else { continue }
            ctx.addPath(head)
            if kind == .arrow {
                ctx.setStrokeColor(cg)
                ctx.setLineWidth(w)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            } else {
                ctx.setFillColor(cg)
                ctx.fillPath()
            }
        }
        ctx.endTransparencyLayer()
    }

    /// Play badge on video and audio objects in the editing view.
    static func drawMediaBadge(_ o: SlideObject, audio: Bool, ctx: CGContext) {
        ctx.saveGState()
        transform(for: o, ctx: ctx, flips: false)
        let s = min(36, min(o.frame.width, o.frame.height) * 0.3)
        let c = CGPoint(x: o.frame.width / 2, y: o.frame.height / 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.move(to: CGPoint(x: c.x - s * 0.35, y: c.y - s * 0.5))
        ctx.addLine(to: CGPoint(x: c.x + s * 0.55, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x - s * 0.35, y: c.y + s * 0.5))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func drawPicture(_ o: SlideObject, deck: Deck, ctx: CGContext) {
        guard let name = o.media, let img = MediaCache.image(name, deck.media[name]) else { return }
        ctx.saveGState()
        transform(for: o, ctx: ctx, flips: true)
        let box = CGRect(origin: .zero, size: o.frame.size)
        let path = Shapes.path(o)
        if o.shadow {
            ctx.saveGState()
            setShadow(ctx)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let s = img.size
        let c = o.crop
        let src = CGRect(x: s.width * c.left, y: s.height * c.bottom, width: s.width * max(0.01, 1 - c.left - c.right),
                         height: s.height * max(0.01, 1 - c.top - c.bottom))
        img.draw(in: box, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        ctx.restoreGState()
        if o.line.color != nil { stroke(path, o.line, deck: deck, ctx: ctx) }
        ctx.restoreGState()
    }

    // MARK: - Tables

    static func cellDefaults(_ t: TableModel, row: Int) -> RunProps? {
        guard t.firstRow, row == 0 else { return RunProps(size: 18) }
        return RunProps(size: 18, bold: true, color: PColor(scheme: "bg1"))
    }

    static func drawTable(_ t: TableModel, object o: SlideObject, slide: Slide?, deck: Deck, ctx: CGContext, options: RenderOptions) {
        for (ri, row) in t.cells.enumerated() {
            for (ci, cell) in row.enumerated() where !cell.merged {
                let r = t.rect(row: ri, column: ci)
                drawFill(cell.fill ?? t.defaultFill(row: ri), in: CGPath(rect: r, transform: nil), bounds: r, deck: deck, ctx: ctx)
            }
        }
        if let bc = t.borderColor, t.borderWidth > 0 {
            ctx.setStrokeColor(bc.resolved(deck.theme).cgColor)
            ctx.setLineWidth(t.borderWidth)
            for (ri, row) in t.cells.enumerated() {
                for (ci, cell) in row.enumerated() where !cell.merged { ctx.stroke(t.rect(row: ri, column: ci)) }
            }
        }
        for (ri, row) in t.cells.enumerated() {
            for (ci, cell) in row.enumerated() where !cell.merged && !cell.text.isEmpty {
                if options.textHidden.contains(o.id), TableEditing.current == (o.id, ri, ci) { continue }
                let r = t.rect(row: ri, column: ci)
                let ins = cell.text.insets
                let inner = CGRect(x: r.minX + ins.left, y: r.minY + ins.top, width: max(1, r.width - ins.left - ins.right),
                                   height: max(1, r.height - ins.top - ins.bottom))
                drawText(cell.text, object: o, slide: slide, deck: deck, number: options.number, in: inner, ctx: ctx, cellDefaults: cellDefaults(t, row: ri))
            }
        }
    }

    // MARK: - Images and PDF

    /// Bitmap of a slide at `pixelWidth`.
    static func image(_ slide: Slide, deck: Deck, pixelWidth: Int, options: RenderOptions = RenderOptions(), opaque: Bool = true) -> CGImage? {
        let scale = CGFloat(pixelWidth) / deck.size.width
        let w = pixelWidth, h = max(1, Int(round(deck.size.height * scale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if opaque {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        draw(slide, deck: deck, in: ctx, options: options)
        return ctx.makeImage()
    }

    static func nsImage(_ slide: Slide, deck: Deck, pixelWidth: Int, options: RenderOptions = RenderOptions()) -> NSImage {
        guard let cg = image(slide, deck: deck, pixelWidth: pixelWidth, options: options) else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func number(of index: Int, deck: Deck) -> Int { deck.firstSlideNumber + index }

    /// PDF: one page per slide (hidden slides skipped unless asked), or notes pages.
    static func pdf(_ deck: Deck, notes: Bool = false, includeHidden: Bool = false, handouts: Int = 0) -> Data {
        let data = NSMutableData()
        let pageSize = notes || handouts > 0 ? CGSize(width: 595, height: 842) : deck.size
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator as String: "PPT42"] as CFDictionary) else { return Data() }
        let slides = deck.slides.enumerated().filter { includeHidden || !$0.element.hidden }
        func begin() {
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        func end() {
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        if handouts > 0 {
            let perPage = handouts
            for chunk in stride(from: 0, to: slides.count, by: perPage) {
                begin()
                drawHandout(Array(slides[chunk..<min(slides.count, chunk + perPage)]), perPage: perPage, deck: deck, page: pageSize, ctx: ctx)
                end()
            }
        } else {
            for (i, slide) in slides {
                begin()
                var o = RenderOptions()
                o.number = number(of: i, deck: deck)
                if notes { drawNotesPage(slide, index: i, deck: deck, page: pageSize, ctx: ctx) } else { draw(slide, deck: deck, in: ctx, options: o) }
                end()
            }
        }
        ctx.closePDF()
        return data as Data
    }

    /// Notes page: the slide in the upper half, the notes text below.
    static func drawNotesPage(_ slide: Slide, index: Int, deck: Deck, page: CGSize, ctx: CGContext) {
        let margin: CGFloat = 54
        let w = page.width - margin * 2
        let h = w * deck.size.height / deck.size.width
        let slideRect = CGRect(x: margin, y: margin, width: w, height: h)
        drawSlide(slide, index: index, deck: deck, in: slideRect, ctx: ctx)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 6
        let font = NSFont(name: "Helvetica Neue", size: 12) ?? .systemFont(ofSize: 12)
        let text = NSAttributedString(string: slide.notes, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: p])
        text.draw(with: CGRect(x: margin, y: slideRect.maxY + 28, width: w, height: page.height - slideRect.maxY - 28 - margin),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let num = NSAttributedString(string: "\(number(of: index, deck: deck))", attributes: [.font: font, .foregroundColor: NSColor.gray])
        num.draw(at: CGPoint(x: page.width - margin - num.size().width, y: page.height - margin + 12))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Handout page: 1, 2, 3, 4, 6 or 9 slides with frames.
    static func drawHandout(_ slides: [(offset: Int, element: Slide)], perPage: Int, deck: Deck, page: CGSize, ctx: CGContext) {
        let cols = perPage <= 2 ? 1 : perPage <= 6 ? 2 : 3
        let rows = Int(ceil(Double(perPage) / Double(cols)))
        let margin: CGFloat = 40, gap: CGFloat = 24
        let cellW = (page.width - margin * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (page.height - margin * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (k, item) in slides.enumerated() {
            let c = k % cols, r = k / cols
            var w = cellW, h = w * deck.size.height / deck.size.width
            if h > cellH { h = cellH; w = h * deck.size.width / deck.size.height }
            let rect = CGRect(x: margin + CGFloat(c) * (cellW + gap) + (cellW - w) / 2, y: margin + CGFloat(r) * (cellH + gap) + (cellH - h) / 2, width: w, height: h)
            drawSlide(item.element, index: item.offset, deck: deck, in: rect, ctx: ctx)
        }
    }

    /// A slide scaled into `rect` with a hairline frame.
    static func drawSlide(_ slide: Slide, index: Int, deck: Deck, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / deck.size.width, y: rect.height / deck.size.height)
        var o = RenderOptions()
        o.number = number(of: index, deck: deck)
        draw(slide, deck: deck, in: ctx, options: o)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0.6, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(rect)
    }
}

/// Table cell being edited (its text is not drawn under the editor).
enum TableEditing {
    static var current: (Int, Int, Int)?
}

func == (a: (Int, Int, Int)?, b: (Int, Int, Int)) -> Bool {
    guard let a else { return false }
    return a.0 == b.0 && a.1 == b.1 && a.2 == b.2
}
