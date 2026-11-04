import AppKit

// Text bodies ⇄ attributed strings. The same attributed string is drawn on slides and edited in place
// (TextKit 1 both ways), so editing is WYSIWYG. Model formatting rides along in boxed attributes.

extension NSAttributedString.Key {
    /// RunBox: the run's own properties (nil = inherited), field and link.
    static let pptRun = NSAttributedString.Key("PPT42.run")
    /// ParaBox: level, paragraph overrides, end-of-paragraph run properties.
    static let pptPara = NSAttributedString.Key("PPT42.para")
    /// Bullet or number in front of a paragraph (not part of the text).
    static let pptMarker = NSAttributedString.Key("PPT42.marker")
}

final class RunBox: NSObject {
    let props: RunProps
    let field: String?
    let link: String?

    init(_ props: RunProps, field: String? = nil, link: String? = nil) {
        self.props = props
        self.field = field
        self.link = link
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? RunBox else { return false }
        return o.props == props && o.field == field && o.link == link
    }

    override var hash: Int { (props.size ?? 0).hashValue ^ (field?.hashValue ?? 0) }
}

final class ParaBox: NSObject {
    let level: Int
    let props: LevelStyle
    let endProps: RunProps

    init(level: Int, props: LevelStyle, endProps: RunProps) {
        self.level = level
        self.props = props
        self.endProps = endProps
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? ParaBox else { return false }
        return o.level == level && o.props == props && o.endProps == endProps
    }

    override var hash: Int { level }
}

/// Font families that are missing on a Mac, mapped to the closest one installed.
enum FontResolver {
    static let substitutes: [String: [String]] = [
        "Calibri": ["Carlito", "Helvetica Neue"], "Calibri Light": ["Carlito", "Helvetica Neue"],
        "Cambria": ["Caladea", "Georgia"], "Aptos": ["Helvetica Neue"], "Aptos Display": ["Helvetica Neue"],
        "Segoe UI": ["Helvetica Neue"], "Segoe UI Light": ["Helvetica Neue"], "Tahoma": ["Verdana", "Helvetica Neue"],
        "Arial": ["Arial", "Helvetica"], "Liberation Sans": ["Arial", "Helvetica"], "Liberation Serif": ["Times New Roman"],
        "DejaVu Sans": ["Verdana", "Helvetica Neue"], "Open Sans": ["Helvetica Neue"], "Century Gothic": ["Avenir Next", "Futura"],
        "Franklin Gothic": ["Avenir Next Condensed", "Helvetica Neue"], "Garamond": ["Garamond", "Baskerville", "Georgia"],
        "Gill Sans MT": ["Gill Sans"], "Trebuchet MS": ["Trebuchet MS", "Helvetica Neue"], "Consolas": ["Menlo"],
    ]
    private static var cache: [String: String] = [:]
    static let fallback = "Helvetica Neue"

    static func family(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return fallback }
        if let c = cache[name] { return c }
        let fm = NSFontManager.shared
        let available = Set(fm.availableFontFamilies)
        var result = fallback
        if available.contains(name) { result = name }
        else if let subs = substitutes[name], let s = subs.first(where: { available.contains($0) }) { result = s }
        else if let lower = available.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { result = lower }
        cache[name] = result
        return result
    }

    static func font(_ family: String?, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let fam = self.family(family)
        let lightRequested = (family ?? "").localizedCaseInsensitiveContains("light")
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let weight = bold ? 9 : (lightRequested ? 3 : 5)
        if let f = NSFontManager.shared.font(withFamily: fam, traits: traits, weight: weight, size: size) { return f }
        var f = NSFont(name: fam, size: size) ?? NSFont(name: fallback, size: size) ?? .systemFont(ofSize: size)
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }
}

/// Symbol-font bullets (Wingdings, Symbol) as Unicode.
private let symbolBullets: [String: String] = ["§": "▪", "Ø": "➢", "ü": "✓", "q": "❑", "v": "❖", "n": "■", "l": "●", "o": "○", "Ü": "➔", "à": "➔", "ð": "➔", "": "•", "·": "•"]

struct TextContext {
    var deck: Deck
    var slide: Slide?
    var object: SlideObject
    /// 1-based slide number shown by slide-number fields.
    var number = 1
    /// Font scale from shrink-on-overflow.
    var scale: CGFloat = 1
    /// Extra defaults under the levels (table cells: header row bold white).
    var cellDefaults: RunProps?
}

enum TextRender {
    static func levelStyle(_ c: TextContext, level: Int) -> LevelStyle {
        var s = c.deck.levelStyle(for: c.object, on: c.slide, level: level)
        if let d = c.cellDefaults { s.run = d.over(s.run) }
        return s
    }

    static func fieldText(_ field: String?, fallback: String, number: Int) -> String {
        switch field {
        case "slidenum": return "\(number)"
        case let f? where f.hasPrefix("datetime"):
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            return df.string(from: Date())
        default: return fallback
        }
    }

    /// Display attributes for run properties (already merged with inherited ones).
    static func attributes(_ r: RunProps, theme: Theme, scale: CGFloat, para: NSParagraphStyle, link: Bool = false) -> [NSAttributedString.Key: Any] {
        var size = (r.size ?? 18) * scale
        if let b = r.baseline, b != 0 { size *= 0.66 }
        let font = FontResolver.font(theme.font(r.font), size: max(1, size), bold: r.bold ?? false, italic: r.italic ?? false)
        var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        a[.foregroundColor] = (link ? PColor(scheme: "hlink") : (r.color ?? PColor(scheme: "tx1"))).resolved(theme)
        if r.underline == true || link { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if r.strike == true { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let b = r.baseline, b != 0 { a[.baselineOffset] = (r.size ?? 18) * scale * b / 100 * 0.8 }
        return a
    }

    static func paragraphStyle(_ s: LevelStyle, scale: CGFloat, firstLine: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = (s.align ?? .left).ns
        let marL = (s.marL ?? 0), indent = (s.indent ?? 0)
        p.headIndent = marL
        p.firstLineHeadIndent = max(0, marL + indent)
        p.tabStops = [NSTextTab(textAlignment: .left, location: max(marL, 1))]
        p.defaultTabInterval = 72
        let size = (s.run.size ?? 18) * scale
        if let ls = s.lineSpacing {
            if ls < 0 { p.minimumLineHeight = -ls * scale; p.maximumLineHeight = -ls * scale } else { p.lineHeightMultiple = ls }
        }
        p.paragraphSpacingBefore = (s.spaceBefore ?? 0) * scale
        p.paragraphSpacing = (s.spaceAfter ?? 0) * scale
        _ = size
        p.lineBreakMode = .byWordWrapping
        return p
    }

    /// The attributed string for a text body. `prompt` replaces an empty body (placeholder hint, grey).
    static func attributed(_ body: TextBody, _ c: TextContext, prompt: String? = nil, forEditing: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let theme = c.deck.theme
        var counters = Array(repeating: 0, count: 10)
        let paragraphs = body.isEmpty && prompt != nil ? [Paragraph(prompt!, level: body.paragraphs.first?.level ?? 0,
                                                                     props: body.paragraphs.first?.props ?? LevelStyle())] : body.paragraphs
        for (i, para) in paragraphs.enumerated() {
            let base = levelStyle(c, level: para.level)
            let style = para.props.over(base)
            let ps = paragraphStyle(style, scale: c.scale)
            let paraBox = ParaBox(level: para.level, props: para.props, endProps: para.endProps)
            let start = out.length
            // Numbering continues while paragraphs stay at the level.
            let lvl = min(max(para.level, 0), 9)
            for k in (lvl + 1)..<10 { counters[k] = 0 }
            let bullet = style.bullet ?? .none
            let hasText = !para.text.isEmpty || forEditing
            if bullet.kind != .none, hasText, !(body.isEmpty && prompt != nil && !forEditing) {
                let n = counters[lvl]
                if bullet.kind == .number { counters[lvl] += 1 } else { counters[lvl] = 0 }
                var mark = bullet.marker(n)
                let firstRun = (para.runs.first?.props ?? para.endProps).over(style.run)
                var mr = firstRun
                if let f = bullet.font, f.contains("Wingdings") || f.contains("Symbol") { mark = symbolBullets[mark] ?? "•" }
                else if let f = bullet.font, bullet.kind == .char, f != "+mj-lt", f != "+mn-lt" { mr.font = f }
                if bullet.kind == .char, mark.isEmpty { mark = "•" }
                if let col = bullet.color { mr.color = col }
                if let pct = bullet.sizePercent { mr.size = (firstRun.size ?? 18) * pct }
                mr.underline = false
                mr.strike = false
                var attrs = attributes(mr, theme: theme, scale: c.scale, para: ps)
                attrs[.pptMarker] = true
                attrs[.pptPara] = paraBox
                attrs[.pptRun] = RunBox(para.runs.first?.props ?? para.endProps)
                out.append(NSAttributedString(string: mark + "\t", attributes: attrs))
            } else {
                counters[lvl] = 0
            }
            for run in para.runs {
                var r = run.props.over(style.run)
                if body.isEmpty && prompt != nil { r.color = PColor(rgb: 0x8A8A8A) }
                var attrs = attributes(r, theme: theme, scale: c.scale, para: ps, link: run.link != nil)
                attrs[.pptRun] = RunBox(run.props, field: run.field, link: run.link)
                attrs[.pptPara] = paraBox
                let text = run.field != nil ? fieldText(run.field, fallback: run.text, number: c.number) : run.text
                out.append(NSAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}")
                    .replacingOccurrences(of: "\u{0B}", with: "\u{2028}"), attributes: attrs))
            }
            let endRun = para.endProps.over(style.run)
            var endAttrs = attributes(endRun, theme: theme, scale: c.scale, para: ps)
            endAttrs[.pptPara] = paraBox
            endAttrs[.pptRun] = RunBox(para.endProps)
            if i < paragraphs.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: endAttrs))
            } else if para.runs.isEmpty && out.length == start {
                // Empty last paragraph: a zero-width carrier gives the line its height when drawing (editing gets typing attributes).
                if !forEditing { out.append(NSAttributedString(string: "\u{200B}", attributes: endAttrs)) }
            }
        }
        return out
    }

    /// Typing attributes for an empty editor (end of the last paragraph).
    static func typingAttributes(_ body: TextBody, _ c: TextContext) -> [NSAttributedString.Key: Any] {
        let para = body.paragraphs.last ?? Paragraph()
        let style = para.props.over(levelStyle(c, level: para.level))
        var a = attributes(para.endProps.over(style.run), theme: c.deck.theme, scale: c.scale, para: paragraphStyle(style, scale: c.scale))
        a[.pptPara] = ParaBox(level: para.level, props: para.props, endProps: para.endProps)
        a[.pptRun] = RunBox(para.runs.last?.props ?? para.endProps)
        return a
    }

    /// Back from an edited attributed string to paragraphs (markers dropped, boxes read).
    static func paragraphs(from s: NSAttributedString) -> [Paragraph] {
        let ns = s.string as NSString
        var result: [Paragraph] = []
        var loc = 0
        for part in ns.components(separatedBy: "\n") {
            let len = (part as NSString).length
            let content = NSRange(location: loc, length: len)
            var para = Paragraph()
            // The paragraph's own characters (or its "\n") carry the paragraph box; an empty last one copies the one before.
            let probe = loc < s.length ? loc : loc - 1
            if probe >= 0, probe < s.length, let box = s.attribute(.pptPara, at: probe, effectiveRange: nil) as? ParaBox {
                para.level = box.level
                para.props = box.props
                para.endProps = box.endProps
            }
            if len > 0 {
                s.enumerateAttributes(in: content) { attrs, r, _ in
                    if attrs[.pptMarker] != nil { return }
                    var text = ns.substring(with: r).replacingOccurrences(of: "\u{200B}", with: "")
                    text = text.replacingOccurrences(of: "\u{2028}", with: "\u{0B}")
                    guard !text.isEmpty else { return }
                    let box = attrs[.pptRun] as? RunBox
                    let run = TextRun(text: text, props: box?.props ?? RunProps(), field: box?.field, link: box?.link)
                    if let last = para.runs.last, last.props == run.props, last.field == nil, run.field == nil, last.link == run.link {
                        para.runs[para.runs.count - 1].text += text
                    } else {
                        para.runs.append(run)
                    }
                }
                if let last = para.runs.last { para.endProps = last.props }
            }
            result.append(para)
            loc += len + 1
        }
        return result.isEmpty ? [Paragraph()] : result
    }
}

/// Lays out and draws text the way the in-place editor does (TextKit 1).
final class TextLayout {
    let storage: NSTextStorage
    let manager = NSLayoutManager()
    let container: NSTextContainer

    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.usesFontLeading = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    var usedHeight: CGFloat {
        let r = manager.usedRect(for: container)
        return storage.length == 0 ? 0 : ceil(r.maxY)
    }

    var usedWidth: CGFloat { ceil(manager.usedRect(for: container).width) }

    /// Draws at `origin` in a flipped context.
    func draw(at origin: CGPoint) {
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
