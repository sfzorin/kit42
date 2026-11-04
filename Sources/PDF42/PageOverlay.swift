import AppKit
import CoreText
import Kit42
import PDFKit

/// Annotation drawn over the page in the editor and baked into the page content when the document
/// is saved (`PageOverlay.bakedData`): watermarks, page numbers, edited text. Until saved it can be
/// undone, re-edited or removed like any annotation.
class PageOverlay: PDFAnnotation {
    init(bounds: CGRect) {
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        userName = NSFullUserName()
        modificationDate = Date()
    }

    required init?(coder: NSCoder) { nil }

    /// Edited text can be clicked, moved and re-edited; watermarks and page numbers never block the page.
    var allowsPicking: Bool { false }

    /// Draws in page space. `box` is the page's crop box, `rotation` its /Rotate.
    func render(in ctx: CGContext, box: CGRect, rotation: Int) {}

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let page else { return }
        context.saveGState()
        render(in: context, box: page.bounds(for: .cropBox), rotation: page.rotation)
        context.restoreGState()
    }

    /// Transform from "as displayed" coordinates (origin bottom left of the visible page, rotation applied)
    /// to page space, and the displayed size.
    static func displayTransform(box: CGRect, rotation: Int) -> (CGAffineTransform, CGSize) {
        let w = box.width, h = box.height
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.minX + w, ty: box.minY), CGSize(width: h, height: w))
        case 180: return (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.minX + w, ty: box.minY + h), box.size)
        case 270: return (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: box.minX, ty: box.minY + h), CGSize(width: h, height: w))
        default: return (CGAffineTransform(translationX: box.minX, y: box.minY), box.size)
        }
    }

    static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color.cgColor]))
    }

    static func width(of line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    /// Glyph outlines of a line (watermarks are drawn as shapes, so they don't pollute text search and copy).
    static func outlines(of line: CTLine) -> CGPath {
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (g, p) in zip(glyphs, positions) {
                if let glyph = CTFontCreatePathForGlyph(font, g, nil) { path.addPath(glyph, transform: CGAffineTransform(translationX: p.x, y: p.y)) }
            }
        }
        return path
    }
}

// MARK: - Watermark

struct WatermarkSpec {
    var text = "CONFIDENTIAL"
    var image: CGImage?
    var fontSize: CGFloat = 72
    var color: NSColor = .systemRed
    var opacity: CGFloat = 0.25
    /// Degrees counter-clockwise; 45 = diagonal from bottom left to top right.
    var rotation: CGFloat = 45
}

final class WatermarkOverlay: PageOverlay {
    let spec: WatermarkSpec

    init(spec: WatermarkSpec, page: PDFPage) {
        self.spec = spec
        super.init(bounds: page.bounds(for: .cropBox))
    }

    required init?(coder: NSCoder) { nil }

    override func render(in ctx: CGContext, box: CGRect, rotation: Int) {
        let (t, size) = Self.displayTransform(box: box, rotation: rotation)
        ctx.concatenate(t)
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: spec.rotation * .pi / 180)
        ctx.setAlpha(spec.opacity)
        if let image = spec.image {
            let w = size.width * 0.5, h = w * CGFloat(image.height) / max(1, CGFloat(image.width))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            return
        }
        let font = NSFont(name: "Helvetica-Bold", size: spec.fontSize) ?? .boldSystemFont(ofSize: spec.fontSize)
        let line = Self.line(spec.text, font: font, color: spec.color)
        let w = Self.width(of: line)
        ctx.translateBy(x: -w / 2, y: -(font.capHeight) / 2)
        ctx.addPath(Self.outlines(of: line))
        ctx.setFillColor((spec.color.usingColorSpace(.sRGB) ?? spec.color).cgColor)
        ctx.fillPath()
    }
}

// MARK: - Page numbers

struct PageNumberSpec {
    enum Position: Int, CaseIterable { case bottomCenter, bottomRight, bottomLeft, topCenter, topRight, topLeft }
    enum Format: Int, CaseIterable { case plain, pageOfTotal, dashes }
    var position: Position = .bottomCenter
    var format: Format = .plain
    var start = 1
    var skipFirst = false
    var fontSize: CGFloat = 10
    var margin: CGFloat = 28

    func text(_ n: Int, of total: Int) -> String {
        switch format {
        case .plain: return "\(n)"
        case .pageOfTotal: return L("Page %d of %d", n, total)
        case .dashes: return "- \(n) -"
        }
    }

    /// Number text for each page index of `indices` (pages in document order).
    func labels(for indices: [Int]) -> [(index: Int, text: String)] {
        let numbered = skipFirst ? Array(indices.sorted().dropFirst()) : indices.sorted()
        let total = start + numbered.count - 1
        return numbered.enumerated().map { ($0.element, text(start + $0.offset, of: total)) }
    }
}

final class PageNumberOverlay: PageOverlay {
    let text: String
    let spec: PageNumberSpec

    init(text: String, spec: PageNumberSpec, page: PDFPage) {
        self.text = text
        self.spec = spec
        super.init(bounds: page.bounds(for: .cropBox))
    }

    required init?(coder: NSCoder) { nil }

    override func render(in ctx: CGContext, box: CGRect, rotation: Int) {
        let (t, size) = Self.displayTransform(box: box, rotation: rotation)
        ctx.concatenate(t)
        let font = NSFont(name: "Helvetica", size: spec.fontSize) ?? .systemFont(ofSize: spec.fontSize)
        let line = Self.line(text, font: font, color: .black)
        let w = Self.width(of: line), m = spec.margin
        let x: CGFloat
        switch spec.position {
        case .bottomCenter, .topCenter: x = (size.width - w) / 2
        case .bottomRight, .topRight: x = size.width - m - w
        case .bottomLeft, .topLeft: x = m
        }
        let top = [.topCenter, .topRight, .topLeft].contains(spec.position)
        ctx.textPosition = CGPoint(x: x, y: top ? size.height - m - font.ascender : m)
        CTLineDraw(line, ctx)
    }
}

// MARK: - Edited text

/// Replacement for a run of page text: a white cover over the original glyphs and the new text
/// on the same baseline, in the original font (when installed) and size.
final class EditedTextOverlay: PageOverlay {
    var text: String
    let textFont: NSFont
    let originalText: String
    /// Original cover width; the cover grows when the new text is longer.
    let originalWidth: CGFloat
    /// Baseline above `bounds.minY`.
    let baseline: CGFloat

    init(cover: CGRect, text: String, originalText: String, font: NSFont, color: NSColor, baseline: CGFloat) {
        self.text = text
        self.textFont = font
        self.originalText = originalText
        self.originalWidth = cover.width
        self.baseline = baseline
        super.init(bounds: cover)
        self.color = color
        self.bounds = Self.cover(for: text, font: font, origin: cover.origin, minWidth: cover.width, height: cover.height)
        contents = text
    }

    required init?(coder: NSCoder) { nil }

    override var allowsPicking: Bool { true }

    static func cover(for text: String, font: NSFont, origin: CGPoint, minWidth: CGFloat, height: CGFloat) -> CGRect {
        let w = width(of: line(text, font: font, color: .black)) + 2
        return CGRect(x: origin.x, y: origin.y, width: max(minWidth, w), height: height)
    }

    /// Changes the text, keeping the left edge and cover height.
    func setText(_ text: String) {
        self.text = text
        contents = text
        bounds = Self.cover(for: text, font: textFont, origin: bounds.origin, minWidth: originalWidth, height: bounds.height)
    }

    override func render(in ctx: CGContext, box: CGRect, rotation: Int) {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(bounds)
        ctx.textPosition = CGPoint(x: bounds.minX + 1, y: bounds.minY + baseline)
        CTLineDraw(Self.line(text, font: textFont, color: color), ctx)
    }

    /// Font of the page text: the embedded font's family when it is installed, else Helvetica (bold/italic kept).
    static func matchingFont(_ source: NSFont?, size: CGFloat) -> NSFont {
        guard let source else { return NSFont(name: "Helvetica", size: size)! }
        var name = source.fontName
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { name = String(name[name.index(after: plus)...]) }
        if let font = NSFont(name: name, size: size) { return font }
        let lower = name.lowercased()
        let bold = lower.contains("bold") || lower.contains("black") || lower.contains("heavy")
        let italic = lower.contains("italic") || lower.contains("oblique")
        let serif = lower.contains("times") || lower.contains("serif") && !lower.contains("sans") || lower.contains("georgia") || lower.contains("garamond")
        let family = serif ? "Times New Roman" : "Helvetica"
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size) ?? NSFont(name: "Helvetica", size: size)!
    }

    /// Overlay replacing the text of `line` (a single-line selection) with `text`.
    static func make(replacing line: PDFSelection, on page: PDFPage, with text: String) -> EditedTextOverlay {
        let b = line.bounds(for: page)
        let attrs = line.attributedString.flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
        let source = attrs[.font] as? NSFont
        let size = source.map(\.pointSize).flatMap { $0 > 1 ? $0 : nil } ?? max(4, b.height * 0.8)
        let font = matchingFont(source, size: size)
        let color = (attrs[.foregroundColor] as? NSColor) ?? .black
        // PDFKit's line bounds span the font's descent..ascent; put the baseline at the descent.
        let scale = b.height / max(1, font.ascender - font.descender)
        let baseline = -font.descender * min(1.2, max(0.8, scale))
        let original = (line.string ?? "").trimmingCharacters(in: .newlines)
        return EditedTextOverlay(cover: b.insetBy(dx: -1, dy: -1), text: text, originalText: original,
                                 font: font, color: color, baseline: baseline + 1)
    }
}

// MARK: - Baking on save

extension PageOverlay {
    /// File bytes with overlays drawn into the page content. Temporary annotations (compare highlights)
    /// are dropped unless `keepTemporary`. The live document is left as it was.
    static func bakedData(_ pdf: PDFDocument, keepTemporary: Bool = false) -> Data? {
        var overlays: [Int: [PageOverlay]] = [:]
        var lifted: [(PDFAnnotation, PDFPage)] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            for a in page.annotations {
                if let o = a as? PageOverlay { overlays[i, default: []].append(o); lifted.append((a, page)) }
                else if a is TemporaryHighlight, !keepTemporary { lifted.append((a, page)) }
            }
        }
        guard !lifted.isEmpty else { return pdf.dataRepresentation() }
        lifted.forEach { $0.1.removeAnnotation($0.0) }
        defer { lifted.forEach { $0.1.addAnnotation($0.0) } }
        guard let data = pdf.dataRepresentation() else { return nil }
        guard !overlays.isEmpty else { return data }
        guard let out = PDFDocument(data: data) else { return nil }
        var replacements: [(Int, PDFPage)] = []
        for (i, list) in overlays {
            guard let page = out.page(at: i) else { continue }
            let rotation = page.rotation, box = page.bounds(for: .cropBox)
            if let baked = redraw(page, overlay: { ctx in
                for o in list { ctx.saveGState(); o.render(in: ctx, box: box, rotation: rotation); ctx.restoreGState() }
            }) { replacements.append((i, baked)) }
        }
        replace(replacements, in: out)
        return out.dataRepresentation()
    }

    /// Bakes overlays into a copy of the document (export, print).
    static func bakedDocument(_ pdf: PDFDocument) -> PDFDocument {
        guard pdf.pageCount > 0, (0..<pdf.pageCount).contains(where: { pdf.page(at: $0)?.annotations.contains { $0 is PageOverlay || $0 is TemporaryHighlight } == true }),
              let data = bakedData(pdf), let copy = PDFDocument(data: data) else { return pdf }
        return copy
    }

    /// New page: the original content plus `overlay`, drawn in page space. Annotations (form fields,
    /// links, markup) are moved to the new page, the crop box and rotation are kept.
    static func redraw(_ page: PDFPage, overlay: (CGContext) -> Void) -> PDFPage? {
        let media = page.bounds(for: .mediaBox), crop = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let annotations = page.annotations
        annotations.forEach { page.removeAnnotation($0) }
        page.rotation = 0
        let data = NSMutableData()
        var box = media
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.saveGState()
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        overlay(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        page.rotation = rotation
        guard let newPage = PDFDocument(data: data as Data)?.page(at: 0) else {
            annotations.forEach { page.addAnnotation($0) }
            return nil
        }
        newPage.setBounds(crop, for: .cropBox)
        newPage.rotation = rotation
        annotations.forEach { newPage.addAnnotation($0) }
        return newPage
    }

    /// Swaps pages in `pdf` and points outline entries and links at the new pages.
    static func replace(_ replacements: [(Int, PDFPage)], in pdf: PDFDocument) {
        var map: [ObjectIdentifier: PDFPage] = [:]
        for (i, page) in replacements where i < pdf.pageCount {
            if let old = pdf.page(at: i) { map[ObjectIdentifier(old)] = page }
        }
        // Destinations lose their page when it is removed: collect the new ones first.
        var fixes: [() -> Void] = []
        func remap(_ d: PDFDestination?) -> PDFDestination? {
            guard let d, let p = d.page, let new = map[ObjectIdentifier(p)] else { return nil }
            return PDFDestination(page: new, at: d.point)
        }
        func walk(_ item: PDFOutline) {
            if let d = remap(item.destination) { fixes.append { item.destination = d } }
            if let a = item.action as? PDFActionGoTo, let d = remap(a.destination) { fixes.append { item.action = PDFActionGoTo(destination: d) } }
            for i in 0..<item.numberOfChildren { if let c = item.child(at: i) { walk(c) } }
        }
        if let root = pdf.outlineRoot { walk(root) }
        for i in 0..<pdf.pageCount {
            for a in pdf.page(at: i)?.annotations ?? [] {
                if let d = remap(a.destination) { fixes.append { a.destination = d } }
                if let g = a.action as? PDFActionGoTo, let d = remap(g.destination) { fixes.append { a.action = PDFActionGoTo(destination: d) } }
            }
        }
        for (i, page) in replacements where i < pdf.pageCount {
            pdf.removePage(at: i)
            pdf.insert(page, at: i)
        }
        fixes.forEach { $0() }
    }
}

/// Highlight from "Compare With…": shown in the editor, not saved unless the user asks.
final class TemporaryHighlight: PDFAnnotation {}
