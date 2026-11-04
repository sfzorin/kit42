import AppKit
import Kit42

/// A paragraph or character style: what it sets (nil: inherited from `basedOn`, then from Body).
/// Ids are Word style ids ("Heading1", "Normal", custom ones), so .docx keeps them as they are.
struct DocStyle: Equatable {
    enum Kind: String { case paragraph, character }
    var id: String
    /// Word name ("heading 1") for built-in styles, the user's name for custom ones.
    var name: String
    var kind: Kind = .paragraph
    var basedOn: String?
    var next: String?
    var family: String?
    var size: CGFloat?
    /// NSFontManager weight: 5 regular, 8 semibold, 9 bold.
    var weight: Int?
    var italic: Bool?
    var underline: Bool?
    var color: NSColor?
    var spaceBefore: CGFloat?
    var spaceAfter: CGFloat?
    var lineHeightMultiple: CGFloat?
    var headIndent: CGFloat?
    var firstLineHeadIndent: CGFloat?
    var tailIndent: CGFloat?
    var alignment: NSTextAlignment?
    var outlineLevel: Int?
    var builtin = false
    /// Shown in the Styles panel (technical styles like the contents heading are hidden).
    var hidden = false

    var isBold: Bool? { weight.map { $0 >= 8 } }

    /// Name shown in the interface (built-in styles are localized).
    var displayName: String { builtin ? (DocStyle.displayNames[id] ?? name) : name }

    static let displayNames: [String: String] = [
        "Normal": L("Body"), "Title": L("Title"), "Heading1": L("Heading 1"), "Heading2": L("Heading 2"), "Heading3": L("Heading 3"),
        "Heading4": L("Heading 4"), "Heading5": L("Heading 5"), "Heading6": L("Heading 6"), "Quote": L("Quote"),
        "ListParagraph": L("List"), "Caption": L("Caption"), "TOCHeading": L("Contents Heading"), "TOC1": L("TOC 1"), "TOC2": L("TOC 2"),
        "TOC3": L("TOC 3"), "FootnoteText": L("Footnote"), "Emphasis": L("Emphasis"), "Strong": L("Strong"), "Code": L("Code"),
    ]
}

/// The document's styles. Paragraphs carry their style id in `Styles.styleKey`, character ranges in `.docCharStyle`.
final class StyleSheet {
    private(set) var styles: [DocStyle]

    init(_ styles: [DocStyle] = StyleSheet.builtins) { self.styles = styles }

    static var builtins: [DocStyle] {
        let f = Styles.defaultFamily
        func p(_ id: String, _ name: String, size: CGFloat, weight: Int = 5, italic: Bool = false, color: NSColor = .black,
               before: CGFloat = 0, after: CGFloat = 6, outline: Int? = nil, head: CGFloat? = nil, based: String? = "Normal",
               next: String? = nil, hidden: Bool = false) -> DocStyle {
            DocStyle(id: id, name: name, kind: .paragraph, basedOn: id == "Normal" ? nil : based, next: next, family: f, size: size, weight: weight,
                     italic: italic, underline: false, color: color, spaceBefore: before, spaceAfter: after, lineHeightMultiple: 1.15,
                     headIndent: head ?? 0, firstLineHeadIndent: head ?? 0, tailIndent: 0, alignment: .natural, outlineLevel: outline,
                     builtin: true, hidden: hidden)
        }
        let grey = NSColor(white: 0.25, alpha: 1), quoteGrey = NSColor(white: 0.35, alpha: 1)
        return [
            p("Normal", "Normal", size: 12),
            p("Title", "Title", size: 26, weight: 9, after: 12, next: "Normal"),
            p("Heading1", "heading 1", size: 20, weight: 9, before: 18, after: 6, outline: 0, next: "Normal"),
            p("Heading2", "heading 2", size: 16, weight: 8, before: 14, after: 4, outline: 1, next: "Normal"),
            p("Heading3", "heading 3", size: 13, weight: 8, color: grey, before: 10, after: 2, outline: 2, next: "Normal"),
            p("Heading4", "heading 4", size: 12, weight: 9, before: 10, after: 2, outline: 3, next: "Normal"),
            p("Heading5", "heading 5", size: 12, weight: 9, italic: true, before: 8, after: 2, outline: 4, next: "Normal"),
            p("Heading6", "heading 6", size: 11, weight: 8, color: quoteGrey, before: 8, after: 2, outline: 5, next: "Normal"),
            p("Quote", "Quote", size: 12, italic: true, color: quoteGrey, before: 6, after: 6, head: 24),
            p("ListParagraph", "List Paragraph", size: 12, after: 2),
            p("Caption", "caption", size: 10, italic: true, color: NSColor(white: 0.3, alpha: 1), before: 2, after: 10),
            p("TOCHeading", "TOC Heading", size: 20, weight: 9, before: 18, after: 6, next: "Normal", hidden: true),
            p("TOC1", "toc 1", size: 12, weight: 9, before: 4, after: 4),
            p("TOC2", "toc 2", size: 12, after: 2, head: 18),
            p("TOC3", "toc 3", size: 12, after: 2, head: 36),
            p("FootnoteText", "footnote text", size: 9, after: 0),
            DocStyle(id: "Emphasis", name: "Emphasis", kind: .character, italic: true, builtin: true),
            DocStyle(id: "Strong", name: "Strong", kind: .character, weight: 9, builtin: true),
            DocStyle(id: "Code", name: "Code", kind: .character, family: "Menlo", size: 11, builtin: true),
        ]
    }

    var paragraphStyles: [DocStyle] { styles.filter { $0.kind == .paragraph } }
    var characterStyles: [DocStyle] { styles.filter { $0.kind == .character } }

    subscript(id: String?) -> DocStyle? {
        guard let id else { return nil }
        return styles.first { $0.id == id }
    }

    func replace(_ style: DocStyle) {
        if let i = styles.firstIndex(where: { $0.id == style.id }) { styles[i] = style } else { styles.append(style) }
    }

    func remove(_ id: String) { styles.removeAll { $0.id == id } }

    func setAll(_ s: [DocStyle]) { styles = s }

    /// Merges styles read from a file: definitions of the same id replace ours, new ones are added.
    func merge(_ other: [DocStyle]) {
        for s in other {
            var s = s
            if let mine = self[s.id] { s.builtin = mine.builtin; s.hidden = mine.hidden }
            replace(s)
        }
    }

    /// Ids from the style up its basedOn chain (the style first).
    func chain(_ id: String) -> [String] {
        var out: [String] = []
        var cur: String? = id
        while let c = cur, !out.contains(c), let s = self[c] {
            out.append(c)
            cur = s.basedOn
        }
        return out
    }

    /// Every property set, inherited ones filled in (paragraph styles end at Body).
    func resolved(_ id: String?) -> DocStyle {
        let base = self["Normal"] ?? StyleSheet.builtins[0]
        guard let id, let style = self[id] else { return base }
        var out = style
        var ids = chain(id)
        if style.kind == .paragraph, !ids.contains("Normal") { ids.append("Normal") }
        for sid in ids.dropFirst() {
            guard let s = self[sid] else { continue }
            out.family = out.family ?? s.family
            out.size = out.size ?? s.size
            out.weight = out.weight ?? s.weight
            out.italic = out.italic ?? s.italic
            out.underline = out.underline ?? s.underline
            out.color = out.color ?? s.color
            out.spaceBefore = out.spaceBefore ?? s.spaceBefore
            out.spaceAfter = out.spaceAfter ?? s.spaceAfter
            out.lineHeightMultiple = out.lineHeightMultiple ?? s.lineHeightMultiple
            out.headIndent = out.headIndent ?? s.headIndent
            out.firstLineHeadIndent = out.firstLineHeadIndent ?? s.firstLineHeadIndent
            out.tailIndent = out.tailIndent ?? s.tailIndent
            out.alignment = out.alignment ?? s.alignment
            out.outlineLevel = out.outlineLevel ?? s.outlineLevel
        }
        return out
    }

    /// A fresh id for a new style named `name`.
    func newId(for name: String) -> String {
        let base = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        var id = base.isEmpty ? "Style" : base
        var n = 1
        while self[id] != nil { n += 1; id = (base.isEmpty ? "Style" : base) + "\(n)" }
        return id
    }

    func copy() -> StyleSheet { StyleSheet(styles) }

    // MARK: Attributes

    static func font(family: String?, size: CGFloat, weight: Int, italic: Bool) -> NSFont {
        let fam = family ?? Styles.defaultFamily
        var font = NSFontManager.shared.font(withFamily: fam, traits: [], weight: weight, size: size)
            ?? NSFontManager.shared.font(withFamily: Styles.defaultFamily, traits: [], weight: weight, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight >= 9 ? .bold : weight >= 8 ? .semibold : .regular)
        if weight >= 8, !NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// Font, colour and paragraph attributes of a paragraph style.
    func attributes(_ id: String?) -> [NSAttributedString.Key: Any] {
        let s = resolved(id)
        var a: [NSAttributedString.Key: Any] = [
            .font: Self.font(family: s.family, size: s.size ?? 12, weight: s.weight ?? 5, italic: s.italic ?? false),
            .foregroundColor: s.color ?? NSColor.black,
            .paragraphStyle: paragraph(s, onto: nil),
        ]
        if s.underline == true { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let id, id != "Normal" { a[Styles.styleKey] = id }
        return a
    }

    /// The style's paragraph settings on top of an existing paragraph style (tables, lists and tabs are kept).
    /// With `old` (the style before Modify Style), only settings still equal to the old style's change.
    func paragraph(_ s: DocStyle, onto existing: NSParagraphStyle?, old: DocStyle? = nil) -> NSParagraphStyle {
        let p = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        func take(_ current: CGFloat, _ was: CGFloat?) -> Bool { old == nil || existing == nil || abs(current - (was ?? 0)) < 0.01 }
        if take(p.paragraphSpacingBefore, old?.spaceBefore) { p.paragraphSpacingBefore = s.spaceBefore ?? 0 }
        if take(p.paragraphSpacing, old?.spaceAfter) { p.paragraphSpacing = s.spaceAfter ?? 0 }
        let exact = p.minimumLineHeight > 0 && p.minimumLineHeight == p.maximumLineHeight
        if old == nil || (!exact && take(p.lineHeightMultiple == 0 ? 1 : p.lineHeightMultiple, old?.lineHeightMultiple ?? 1.15)) {
            p.lineHeightMultiple = s.lineHeightMultiple ?? 1.15
            p.minimumLineHeight = 0
            p.maximumLineHeight = 0
        }
        if old == nil || existing == nil || p.alignment == (old?.alignment ?? .natural) { p.alignment = s.alignment ?? .natural }
        if existing?.textLists.isEmpty ?? true {
            if take(p.headIndent, old?.headIndent) { p.headIndent = s.headIndent ?? 0 }
            if take(p.firstLineHeadIndent, old?.firstLineHeadIndent) { p.firstLineHeadIndent = s.firstLineHeadIndent ?? 0 }
        }
        if take(p.tailIndent, old?.tailIndent) { p.tailIndent = s.tailIndent ?? 0 }
        return p
    }

    // MARK: Reapplying

    /// Applies a paragraph style to `range` (whole paragraphs): style settings replace what the old style set;
    /// formatting the user added on top (a bold word, another colour) stays unless `clearDirect`.
    /// `update`: the style itself changed (Modify Style): every property the user set by hand stays.
    /// Otherwise (applying a style): font and colour come from the style; bold or italic words stay.
    func apply(paragraphStyle id: String, to storage: NSMutableAttributedString, range: NSRange, from old: StyleSheet? = nil, update: Bool = false) {
        let new = resolved(id)
        let before = update ? (old ?? self).resolved(id) : nil
        storage.enumerateAttribute(.paragraphStyle, in: range) { v, r, _ in
            storage.addAttribute(.paragraphStyle, value: paragraph(new, onto: v as? NSParagraphStyle, old: before), range: r)
        }
        let fm = NSFontManager.shared
        let ns = storage.string as NSString
        storage.enumerateAttributes(in: range) { a, r, _ in
            let oldStyle = (old ?? self).resolved(a[Styles.styleKey] as? String)
            let charStyle = self[a[.docCharStyle] as? String]
            var font = a[.font] as? NSFont ?? Styles.normal.font
            let traits = fm.traits(of: font)
            let para = ns.paragraphRange(for: r)
            let part = r.length < para.length - (NSMaxRange(para) > 0 && [10, 13, 0x2029].contains(ns.character(at: NSMaxRange(para) - 1)) ? 1 : 0)
            let isBold = traits.contains(.boldFontMask), isItalic = traits.contains(.italicFontMask)
            let family = charStyle?.family ?? (update && font.familyName != oldStyle.family ? font.familyName : nil) ?? new.family ?? Styles.defaultFamily
            let size = charStyle?.size ?? (update && abs(font.pointSize - (oldStyle.size ?? 12)) > 0.01 ? font.pointSize : (new.size ?? 12))
            let directBold = isBold != (oldStyle.isBold ?? false) && (update || part)
            let directItalic = isItalic != (oldStyle.italic ?? false) && (update || part)
            let bold = charStyle?.isBold ?? (directBold ? isBold : (new.isBold ?? false))
            let italic = charStyle?.italic ?? (directItalic ? isItalic : (new.italic ?? false))
            font = Self.font(family: family, size: size, weight: bold ? max(new.weight ?? 9, 8) : 5, italic: italic)
            if fm.traits(of: font).contains(.boldFontMask) != bold { font = bold ? fm.convert(font, toHaveTrait: .boldFontMask) : fm.convert(font, toNotHaveTrait: .boldFontMask) }
            storage.addAttribute(.font, value: font, range: r)
            let color = a[.foregroundColor] as? NSColor ?? .black
            if a[.link] != nil {
                storage.addAttribute(.foregroundColor, value: DocWindowController.linkColor, range: r)
            } else if !(update && !Self.same(color, oldStyle.color ?? .black)) {
                storage.addAttribute(.foregroundColor, value: charStyle?.color ?? new.color ?? NSColor.black, range: r)
            }
        }
        if id == "Normal" { storage.removeAttribute(Styles.styleKey, range: range) } else { storage.addAttribute(Styles.styleKey, value: id, range: range) }
    }

    /// Applies a character style (nil: removes it, the paragraph style's font comes back).
    func apply(characterStyle id: String?, to storage: NSMutableAttributedString, range: NSRange) {
        storage.enumerateAttributes(in: range) { a, r, _ in
            let para = resolved(a[Styles.styleKey] as? String)
            let s = self[id]
            let font = Self.font(family: s?.family ?? para.family, size: s?.size ?? para.size ?? 12,
                                 weight: s?.weight ?? para.weight ?? 5, italic: s?.italic ?? para.italic ?? false)
            storage.addAttribute(.font, value: font, range: r)
            if a[.link] == nil { storage.addAttribute(.foregroundColor, value: s?.color ?? para.color ?? NSColor.black, range: r) }
        }
        if let id { storage.addAttribute(.docCharStyle, value: id, range: range) } else { storage.removeAttribute(.docCharStyle, range: range) }
    }

    static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a == b }
        return abs(x.redComponent - y.redComponent) < 0.01 && abs(x.greenComponent - y.greenComponent) < 0.01 && abs(x.blueComponent - y.blueComponent) < 0.01
    }

    /// Paragraph ranges whose style is `id` or based on it.
    func paragraphs(using id: String, in storage: NSAttributedString) -> [NSRange] {
        var out: [NSRange] = []
        let ns = storage.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in
            let sid = (storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String) ?? "Normal"
            if self.chain(sid).contains(id) || (id == "Normal" && self[sid]?.kind == .paragraph) { out.append(r) }
        }
        return out
    }

    /// A style with the look of the text at `index` (font, colour, paragraph).
    static func style(from storage: NSAttributedString, at index: Int, id: String, name: String, kind: DocStyle.Kind, basedOn: String?) -> DocStyle {
        var s = DocStyle(id: id, name: name, kind: kind, basedOn: basedOn)
        guard storage.length > 0 else { return s }
        let a = storage.attributes(at: min(index, storage.length - 1), effectiveRange: nil)
        if let font = a[.font] as? NSFont {
            s.family = font.familyName
            s.size = font.pointSize
            let t = NSFontManager.shared.traits(of: font)
            s.weight = t.contains(.boldFontMask) ? 9 : 5
            s.italic = t.contains(.italicFontMask)
        }
        s.color = a[.foregroundColor] as? NSColor ?? .black
        s.underline = (a[.underlineStyle] as? Int ?? 0) != 0
        if kind == .paragraph, let p = a[.paragraphStyle] as? NSParagraphStyle {
            s.spaceBefore = p.paragraphSpacingBefore
            s.spaceAfter = p.paragraphSpacing
            s.lineHeightMultiple = p.lineHeightMultiple == 0 ? 1 : p.lineHeightMultiple
            if p.textLists.isEmpty {
                s.headIndent = p.headIndent
                s.firstLineHeadIndent = p.firstLineHeadIndent
            }
            s.tailIndent = p.tailIndent
            s.alignment = p.alignment
        }
        return s
    }

    // MARK: .docx

    /// Definitions for the .docx writer (every property resolved, so readers see the same look).
    func docxStyles() -> [DocxWriter.Style] {
        styles.map { s in
            let r = s.kind == .paragraph ? resolved(s.id) : s
            var d = DocxWriter.Style(id: s.id, name: s.builtin ? s.name : s.name, character: s.kind == .character)
            d.basedOn = s.basedOn
            d.next = s.next
            d.custom = !s.builtin
            d.family = r.family
            d.size = r.size
            d.bold = r.isBold
            d.italic = r.italic
            d.underline = r.underline
            d.color = r.color
            if s.kind == .paragraph {
                d.spaceBefore = r.spaceBefore
                d.spaceAfter = r.spaceAfter
                d.lineHeightMultiple = r.lineHeightMultiple
                d.headIndent = r.headIndent
                d.firstLineHeadIndent = r.firstLineHeadIndent
                d.tailIndent = r.tailIndent
                d.alignment = r.alignment
                d.outlineLevel = r.outlineLevel
            }
            return d
        }
    }
}

// MARK: - Reading styles.xml

extension DocxStyles {
    /// Our style id for a Word style (built-in ones by name, custom ones keep their id).
    static func styleId(_ id: String, name: String?) -> String {
        if let name, let w = wordStyle(forName: name, id: id) { return w }
        let n = (name ?? id).lowercased().replacingOccurrences(of: " ", with: "")
        switch n {
        case "normal": return "Normal"
        case "listparagraph": return "ListParagraph"
        case "caption": return "Caption"
        case "footnotetext": return "FootnoteText"
        case "emphasis": return "Emphasis"
        case "strong": return "Strong"
        default: return id
        }
    }

    /// Paragraph and character styles of a styles.xml, with docDefaults and the basedOn chain resolved.
    static func readStyles(_ root: XMLElement, themeFonts: (major: String?, minor: String?), used: Set<String>) -> [DocStyle] {
        var byId: [String: XMLElement] = [:]
        for s in root.children("style") { if let id = s.attr("styleId") { byId[id] = s } }
        let defaults = root.child("docDefaults")
        let defaultRPr = defaults?.child("rPrDefault")?.child("rPr")
        let defaultPPr = defaults?.child("pPrDefault")?.child("pPr")
        let technical: Set<String> = ["DefaultParagraphFont", "Hyperlink", "FootnoteReference", "CommentReference", "CommentText", "TableNormal",
                                      "NoList", "FollowedHyperlink", "EndnoteReference", "EndnoteText", "BalloonText", "Header", "Footer"]
        var out: [DocStyle] = []
        for (fileId, s) in byId {
            let type = s.attr("type")
            guard type == "paragraph" || type == "character", !technical.contains(fileId) else { continue }
            let name = s.child("name")?.attr("val")
            let id = styleId(fileId, name: name)
            let builtin = StyleSheet.builtins.contains { $0.id == id }
            // Only styles in use, ours, or the file's own (custom) ones.
            guard builtin || used.contains(fileId) || s.attr("customStyle") == "1" else { continue }
            if type == "character", s.child("link") != nil, !used.contains(fileId) { continue }
            var chain: [XMLElement] = []
            var cur: String? = fileId
            var seen = Set<String>()
            while let c = cur, let e = byId[c], !seen.contains(c) { seen.insert(c); chain.insert(e, at: 0); cur = e.child("basedOn")?.attr("val") }
            var st = DocStyle(id: id, name: name ?? fileId, kind: type == "character" ? .character : .paragraph)
            st.basedOn = s.child("basedOn")?.attr("val").map { styleId($0, name: byId[$0]?.child("name")?.attr("val")) }
            st.next = s.child("next")?.attr("val").map { styleId($0, name: byId[$0]?.child("name")?.attr("val")) }
            if st.next == id { st.next = nil }
            // Run properties: defaults (paragraph styles only) < chain.
            var rPrs: [XMLElement] = []
            if type == "paragraph", let d = defaultRPr { rPrs.append(d) }
            rPrs += chain.compactMap { $0.child("rPr") }
            var pPrs: [XMLElement] = []
            if type == "paragraph", let d = defaultPPr { pPrs.append(d) }
            pPrs += chain.compactMap { $0.child("pPr") }
            for r in rPrs {
                if let f = r.child("rFonts") {
                    if let a = f.attr("ascii") ?? f.attr("hAnsi") { st.family = a } else if let t = f.attr("asciiTheme") {
                        st.family = (t.hasPrefix("major") ? themeFonts.major : themeFonts.minor) ?? st.family
                    }
                }
                if let sz = r.child("sz")?.attr("val").flatMap(Double.init) { st.size = CGFloat(sz) / 2 }
                if let b = r.child("b") { st.weight = onOff(b) ? 9 : 5 }
                if let i = r.child("i") { st.italic = onOff(i) }
                if let u = r.child("u") { st.underline = (u.attr("val") ?? "single") != "none" }
                if let c = r.child("color")?.attr("val"), c != "auto", let color = hexColor(c) { st.color = color }
            }
            if type == "paragraph" {
                for p in pPrs {
                    if let sp = p.child("spacing") {
                        if let v = sp.attr("before").flatMap(Double.init) { st.spaceBefore = CGFloat(v) / 20 }
                        if let v = sp.attr("after").flatMap(Double.init) { st.spaceAfter = CGFloat(v) / 20 }
                        if let v = sp.attr("line").flatMap(Double.init), (sp.attr("lineRule") ?? "auto") == "auto" { st.lineHeightMultiple = CGFloat(v) / 240 }
                    }
                    if let ind = p.child("ind") {
                        let left = (ind.attr("left") ?? ind.attr("start")).flatMap(Double.init).map { CGFloat($0) / 20 }
                        if let left { st.headIndent = left }
                        let head = left ?? st.headIndent ?? 0
                        if let h = ind.attr("hanging").flatMap(Double.init) { st.firstLineHeadIndent = head - CGFloat(h) / 20 } else if let f = ind.attr("firstLine").flatMap(Double.init) {
                            st.firstLineHeadIndent = head + CGFloat(f) / 20
                        } else if left != nil { st.firstLineHeadIndent = head }
                        if let r = (ind.attr("right") ?? ind.attr("end")).flatMap(Double.init) { st.tailIndent = -CGFloat(r) / 20 }
                    }
                    if let jc = p.child("jc")?.attr("val") {
                        st.alignment = ["center": .center, "right": .right, "end": .right, "both": .justified, "distribute": .justified][jc] ?? .left
                    }
                    if let o = p.child("outlineLvl")?.attr("val").flatMap(Int.init) { st.outlineLevel = o }
                }
            }
            out.append(st)
        }
        return out.sorted { $0.id < $1.id }
    }

    static func onOff(_ e: XMLElement) -> Bool { !["0", "false", "off", "none"].contains(e.attr("val") ?? "true") }

    static func hexColor(_ s: String) -> NSColor? {
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
