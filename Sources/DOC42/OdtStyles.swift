import AppKit
import Kit42

/// Paragraph styles in .odt: named styles in styles.xml (Heading_20_1, Quotations, custom ones), paragraphs
/// referring to them (through an automatic style with that parent, as LibreOffice writes them).
enum OdtStyles {
    static let names: [String: String] = [
        "Normal": "Standard", "Title": "Title", "Heading1": "Heading_20_1", "Heading2": "Heading_20_2", "Heading3": "Heading_20_3",
        "Heading4": "Heading_20_4", "Heading5": "Heading_20_5", "Heading6": "Heading_20_6", "Quote": "Quotations", "ListParagraph": "List",
        "Caption": "Caption", "TOCHeading": "Contents_20_Heading", "TOC1": "Contents_20_1", "TOC2": "Contents_20_2", "TOC3": "Contents_20_3",
        "FootnoteText": "Footnote",
    ]

    static func odtName(_ id: String) -> String { names[id] ?? id.replacingOccurrences(of: " ", with: "_20_") }

    /// Our id for an ODF style name ("Heading_20_1" → Heading1, "Text_20_body" → Normal).
    static func id(_ name: String, display: String?) -> String? {
        if let k = names.first(where: { $0.value == name })?.key { return k }
        if ["Text_20_body", "Default", "Default_20_Paragraph_20_Style", "Body_20_Text"].contains(name) { return "Normal" }
        let n = (display ?? name.replacingOccurrences(of: "_20_", with: " ")).lowercased().replacingOccurrences(of: " ", with: "")
        if n.hasPrefix("heading"), let l = Int(n.dropFirst(7)), (1...10).contains(l) { return "Heading\(min(6, l))" }
        if n.hasPrefix("contents"), let l = Int(n.dropFirst(8)), (1...10).contains(l) { return "TOC\(min(3, l))" }
        return nil
    }

    static let marker = try! NSRegularExpression(pattern: "(?:\u{E00A}|&#57354;|&#xE00A;)y([^\u{E00B}&]+)(?:\u{E00B}|&#57355;|&#xE00B;)")

    /// Marks each styled paragraph's start for the system writer ("\u{E00A}y<id>\u{E00B}").
    static func markParagraphs(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let ns = text.string as NSString
        var starts: [(Int, String)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            guard r.length > 0, let id = text.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String, id != "Normal" else { return }
            starts.append((r.location, id))
        }
        for (at, id) in starts.reversed() {
            var a = out.attributes(at: at, effectiveRange: nil)
            a[.attachment] = nil
            out.insert(NSAttributedString(string: "\u{E00A}y\(id)\u{E00B}", attributes: a), at: at)
        }
        return out
    }

    private static func pt(_ v: CGFloat) -> String { String(format: "%.2fpt", v) }

    /// Named style definitions for styles.xml.
    static func definitions(_ sheet: StyleSheet) -> String {
        var x = ""
        for s in sheet.paragraphStyles where s.id != "Normal" {
            let r = sheet.resolved(s.id)
            let parent = s.basedOn.map(odtName) ?? "Standard"
            let display = s.builtin ? (s.id.hasPrefix("Heading") ? "Heading \(s.id.dropFirst(7))" : s.name) : s.name
            x += "<style:style style:name=\"\(xmlEscape(odtName(s.id)))\" style:display-name=\"\(xmlEscape(display))\" style:family=\"paragraph\""
            x += " style:parent-style-name=\"\(xmlEscape(parent))\""
            if let o = r.outlineLevel { x += " style:default-outline-level=\"\(o + 1)\"" }
            x += " style:class=\"text\">"
            var p = "fo:margin-top=\"\(pt(r.spaceBefore ?? 0))\" fo:margin-bottom=\"\(pt(r.spaceAfter ?? 0))\""
            p += " fo:margin-left=\"\(pt(r.headIndent ?? 0))\" fo:text-indent=\"\(pt((r.firstLineHeadIndent ?? 0) - (r.headIndent ?? 0)))\""
            if let lm = r.lineHeightMultiple { p += " fo:line-height=\"\(Int((lm * 100).rounded()))%\"" }
            switch r.alignment {
            case .center: p += " fo:text-align=\"center\""
            case .right: p += " fo:text-align=\"end\""
            case .justified: p += " fo:text-align=\"justify\""
            default: break
            }
            x += "<style:paragraph-properties \(p)/>"
            var t = ""
            if let f = r.family { t += " fo:font-family=\"\(xmlEscape(f))\"" }
            if let sz = r.size { t += " fo:font-size=\"\(pt(sz))\"" }
            t += " fo:font-weight=\"\((r.isBold ?? false) ? "bold" : "normal")\" fo:font-style=\"\((r.italic ?? false) ? "italic" : "normal")\""
            if let c = r.color { t += " fo:color=\"#\(CLI.hex(c))\"" }
            x += "<style:text-properties\(t)/></style:style>"
        }
        return x
    }

    /// Paragraph markers → paragraphs in their named styles (a copy of the automatic style with that parent).
    static func apply(_ content: String) -> (String, [String]) {
        var s = content
        var clones: [String: (auto: String?, id: String)] = [:]
        while let m = marker.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s), let idRange = Range(m.range(at: 1), in: s) {
            let id = String(s[idRange])
            s.removeSubrange(r)
            // The paragraph that holds the marker.
            let before = s.startIndex..<r.lowerBound
            let p = s.range(of: "<text:p", options: .backwards, range: before), h = s.range(of: "<text:h", options: .backwards, range: before)
            guard let start = [p, h].compactMap({ $0 }).max(by: { $0.lowerBound < $1.lowerBound }),
                  let close = s.range(of: ">", range: start.upperBound..<s.endIndex) else { continue }
            let open = start.lowerBound..<close.upperBound
            let tag = String(s[open])
            let auto = tag.range(of: "text:style-name=\"([^\"]+)\"", options: .regularExpression).map { String(tag[$0]).replacingOccurrences(of: "text:style-name=\"", with: "").dropLast() }.map(String.init)
            let name = "K42" + (auto ?? "") + "_" + odtName(id)
            clones[name] = (auto, id)
            var newTag: String
            if auto != nil {
                newTag = tag.replacingOccurrences(of: "text:style-name=\"[^\"]+\"", with: "text:style-name=\"\(name)\"", options: .regularExpression)
            } else {
                newTag = tag.replacingOccurrences(of: ">", with: " text:style-name=\"\(name)\">", options: [], range: tag.index(before: tag.endIndex)..<tag.endIndex)
            }
            s.replaceSubrange(open, with: newTag)
        }
        // Automatic styles: copies of the originals with the named style as parent.
        var styles: [String] = []
        for (name, c) in clones {
            var body = "<style:paragraph-properties/>"
            if let a = c.auto, let r = s.range(of: "<style:style style:name=\"\(a)\"[^>]*>[\\s\\S]*?</style:style>", options: .regularExpression) {
                let def = String(s[r])
                if let inner = def.range(of: ">") { body = String(def[inner.upperBound...]).replacingOccurrences(of: "</style:style>", with: "") }
            }
            styles.append("<style:style style:name=\"\(name)\" style:family=\"paragraph\" style:parent-style-name=\"\(xmlEscape(odtName(c.id)))\">\(body)</style:style>")
        }
        if !styles.isEmpty {
            if let r = s.range(of: "</office:automatic-styles>") { s.replaceSubrange(r, with: styles.joined() + "</office:automatic-styles>") }
            else if let r = s.range(of: "<office:automatic-styles/>") { s.replaceSubrange(r, with: "<office:automatic-styles>" + styles.joined() + "</office:automatic-styles>") }
        }
        return (s, Array(clones.keys))
    }

    /// Named paragraph styles of an .odt (styles.xml office:styles) as our styles.
    static func read(_ styles: XMLElement?) -> [DocStyle] {
        guard let styles else { return [] }
        var out: [DocStyle] = []
        for e in OdtFormat.descendants(styles, named: "style") where e.attr("family") == "paragraph" && (e.parent as? XMLElement)?.localName == "styles" {
            guard let name = e.attr("name") else { continue }
            let display = e.attr("display-name")
            let id = Self.id(name, display: display) ?? name
            guard id != "Normal" || name == "Standard" else { continue }
            var s = DocStyle(id: id, name: display ?? name.replacingOccurrences(of: "_20_", with: " "))
            if let p = e.attr("parent-style-name") { s.basedOn = Self.id(p, display: nil) ?? p }
            if s.basedOn == id { s.basedOn = nil }
            if let tp = e.child("text-properties") {
                s.family = tp.attr("font-family") ?? tp.attr("font-name")
                s.size = odfLength(tp.attr("font-size"))
                if let w = tp.attr("font-weight") { s.weight = w == "bold" || (Int(w) ?? 400) >= 600 ? 9 : 5 }
                if let st = tp.attr("font-style") { s.italic = st == "italic" || st == "oblique" }
                if let c = tp.attr("color"), c.hasPrefix("#") { s.color = DocxStyles.hexColor(String(c.dropFirst())) }
            }
            if let pp = e.child("paragraph-properties") {
                s.spaceBefore = odfLength(pp.attr("margin-top"))
                s.spaceAfter = odfLength(pp.attr("margin-bottom"))
                if let l = odfLength(pp.attr("margin-left")) { s.headIndent = l; s.firstLineHeadIndent = l + (odfLength(pp.attr("text-indent")) ?? 0) }
                if let a = pp.attr("text-align") { s.alignment = ["center": .center, "end": .right, "right": .right, "justify": .justified][a] ?? .left }
                if let lh = pp.attr("line-height"), lh.hasSuffix("%"), let v = Double(lh.dropLast()) { s.lineHeightMultiple = CGFloat(v) / 100 }
            }
            if let o = e.attr("default-outline-level").flatMap(Int.init) { s.outlineLevel = o - 1 }
            out.append(s)
        }
        return out
    }
}
