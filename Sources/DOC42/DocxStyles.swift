import AppKit
import Kit42

/// The system .docx reader honours only direct formatting. Word documents mostly rely on styles
/// (Title, Heading 1, List Bullet, docDefaults, theme fonts), so before reading we copy every
/// paragraph's and run's effective style properties into the document as direct formatting.
enum DocxStyles {
    static let ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// What the system reader drops: pictures (replaced by markers in the text), page setup, header, footer.
    struct Extras {
        var images: [Int: (data: Data, size: NSSize)] = [:]
        var setup = PageSetup()
        var hasSetup = false
        /// "numId:ilvl" → list format; the system reader makes every list a bullet list.
        var lists: [String: ListFormat] = [:]
        /// Footnote ("f2") and endnote ("e1") texts, comments by id, section setups by marker number.
        var notes: [String: String] = [:]
        var comments: [String: DocComment] = [:]
        var sections: [Int: PageSetup] = [:]
    }

    struct ListFormat {
        var format = "bullet"
        var text = "%1."
        var start = 1
    }

    /// Level formats of every numbering instance (overrides applied).
    static func listFormats(_ zip: ZipArchive) -> [String: [Int: ListFormat]] {
        guard let data = zip["word/numbering.xml"], let root = (try? XMLDocument(data: data))?.rootElement() else { return [:] }
        func levels(_ e: XMLElement) -> [Int: ListFormat] {
            var out: [Int: ListFormat] = [:]
            for l in e.children("lvl") {
                if let i = l.attr("ilvl").flatMap(Int.init) { out[i] = levelsOf(l) }
            }
            return out
        }
        var abstracts: [String: [Int: ListFormat]] = [:]
        for a in root.children("abstractNum") { if let id = a.attr("abstractNumId") { abstracts[id] = levels(a) } }
        var out: [String: [Int: ListFormat]] = [:]
        for num in root.children("num") {
            guard let id = num.attr("numId"), let a = num.child("abstractNumId")?.attr("val") else { continue }
            var l = abstracts[a] ?? [:]
            for o in num.children("lvlOverride") {
                guard let i = o.attr("ilvl").flatMap(Int.init) else { continue }
                if let lvl = o.child("lvl") { l[i] = levelsOf(lvl) }
                if let start = o.child("startOverride")?.attr("val").flatMap(Int.init) { l[i, default: ListFormat()].start = start }
            }
            out[id] = l
        }
        return out
    }

    private static func levelsOf(_ lvl: XMLElement) -> ListFormat {
        var f = ListFormat()
        f.format = lvl.child("numFmt")?.attr("val") ?? "bullet"
        f.text = lvl.child("lvlText")?.attr("val") ?? ""
        f.start = lvl.child("start")?.attr("val").flatMap(Int.init) ?? 1
        return f
    }

    static let markerStart: Character = "\u{E000}", markerEnd: Character = "\u{E001}"

    static func flatten(_ data: Data) -> Data { flattenWithExtras(data).data }

    static func flattenWithExtras(_ data: Data) -> (data: Data, extras: Extras) {
        var extras = Extras()
        guard var zip = try? ZipArchive(data: data),
              let docData = zip["word/document.xml"],
              let doc = try? XMLDocument(data: docData, options: [.nodePreserveWhitespace]),
              let stylesData = zip["word/styles.xml"],
              let styles = try? XMLDocument(data: stylesData, options: []).rootElement() else { return (data, extras) }

        let themeFonts = themeFontNames(zip)
        let formats = listFormats(zip)
        var byId: [String: XMLElement] = [:]
        var defaultParagraph: String?
        for s in styles.children("style") {
            guard let id = s.attr("styleId") else { continue }
            byId[id] = s
            if s.attr("type") == "paragraph", s.attr("default") == "1" { defaultParagraph = id }
        }
        let defaults = styles.child("docDefaults")
        let defaultRPr = defaults?.child("rPrDefault")?.child("rPr")
        let defaultPPr = defaults?.child("pPrDefault")?.child("pPr")

        /// Style chain from the most basic to the given style.
        func chain(_ id: String?) -> [XMLElement] {
            var out: [XMLElement] = []
            var cur = id
            var seen = Set<String>()
            while let c = cur, let s = byId[c], !seen.contains(c) {
                seen.insert(c)
                out.insert(s, at: 0)
                cur = s.child("basedOn")?.attr("val")
            }
            return out
        }

        guard let body = doc.rootElement()?.child("body") else { return (data, extras) }
        let rels = relations(zip, "word/_rels/document.xml.rels")

        // Pictures → text markers, restored as attachments after reading.
        var n = 0
        for drawing in descendants(body, named: "drawing") {
            guard let blip = descendants(drawing, named: "blip").first,
                  let id = blip.attr("embed"), let target = rels[id], let media = zip["word/" + target] ?? zip[target] else { continue }
            var size = NSSize(width: 200, height: 150)
            if let ext = descendants(drawing, named: "extent").first,
               let cx = ext.attr("cx").flatMap(Double.init), let cy = ext.attr("cy").flatMap(Double.init) {
                size = NSSize(width: cx / 12700, height: cy / 12700)
            }
            n += 1
            extras.images[n] = (media, size)
            let t = XMLElement(name: "w:t", uri: ns)
            t.stringValue = "\(markerStart)\(n)\(markerEnd)"
            if let parent = drawing.parent as? XMLElement { parent.replaceChild(at: drawing.index, with: t) }
        }

        markFootnotesCommentsLinks(body, zip: zip, rels: rels, extras: &extras)

        // Page setup, header and footer from the (last) section.
        if let sect = body.child("sectPr") {
            extras.hasSetup = true
            extras.setup = sectionSetup(sect, base: extras.setup)
            func part(_ name: String) -> XMLElement? {
                let refs = sect.children(name + "Reference")
                let ref = refs.first { $0.attr("type") == "default" } ?? refs.first
                guard let id = ref?.attr("id"), let target = rels[id], let d = zip["word/" + target] else { return nil }
                return (try? XMLDocument(data: d))?.rootElement()
            }
            func text(_ root: XMLElement?) -> String {
                guard let root else { return "" }
                return descendants(root, named: "p").map { p in descendants(p, named: "t").compactMap(\.stringValue).joined() }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
            }
            let header = part("header"), footer = part("footer")
            extras.setup.header = text(header)
            let footerText = text(footer)
            let pageField = footer.map { f in
                descendants(f, named: "fldSimple").contains { ($0.attr("instr") ?? "").uppercased().contains("PAGE") }
                    || descendants(f, named: "instrText").contains { ($0.stringValue ?? "").uppercased().contains("PAGE") }
            } ?? false
            extras.setup.pageNumbers = pageField
            // Drop the field's cached number ("1") from the footer text.
            extras.setup.footer = pageField ? footerText.replacingOccurrences(of: "\\s*\\d+\\s*$", with: "", options: .regularExpression) : footerText
        }
        for p in descendants(body, named: "p") {
            let pPr = p.child("pPr") ?? {
                let e = XMLElement(name: "w:pPr", uri: ns)
                p.insertChild(e, at: 0)
                return e
            }()
            let styleId = pPr.child("pStyle")?.attr("val") ?? defaultParagraph
            let styleChain = chain(styleId)
            // Keep Word heading/title styles through the system reader: a marker run at the paragraph start.
            if let id = styleId, let name = byId[id]?.child("name")?.attr("val"), let word = wordStyle(forName: name, id: id) {
                let r = XMLElement(name: "w:r", uri: ns)
                let t = XMLElement(name: "w:t", uri: ns)
                t.stringValue = "\u{E002}\(word)\u{E003}"
                r.addChild(t)
                p.insertChild(r, at: pPr.index + 1)
            }

            // Paragraph properties: defaults < style chain < direct
            var inheritedP: [XMLElement] = []
            if let d = defaultPPr { inheritedP.append(d) }
            inheritedP += styleChain.compactMap { $0.child("pPr") }
            merge(into: pPr, from: inheritedP, skip: ["pStyle", "rPr", "sectPr", "pPrChange"])
            // List format marker: restored by `restoreLists` after reading.
            if let numPr = pPr.child("numPr"), let numId = numPr.child("numId")?.attr("val") {
                let level = numPr.child("ilvl")?.attr("val").flatMap(Int.init) ?? 0
                let key = "\(numId):\(level)"
                if extras.lists[key] == nil { extras.lists[key] = formats[numId]?[level] ?? ListFormat(format: numId == "0" ? "none" : "bullet") }
                let r = XMLElement(name: "w:r", uri: ns)
                let t = XMLElement(name: "w:t", uri: ns)
                t.stringValue = "\u{E004}\(key)\u{E005}"
                r.addChild(t)
                p.insertChild(r, at: pPr.index + 1)
            }

            // Run properties: defaults < paragraph style chain < character style chain < direct
            var inheritedR: [XMLElement] = []
            if let d = defaultRPr { inheritedR.append(d) }
            inheritedR += styleChain.compactMap { $0.child("rPr") }
            for r in descendants(p, named: "r") {
                let rPr = r.child("rPr") ?? {
                    let e = XMLElement(name: "w:rPr", uri: ns)
                    r.insertChild(e, at: 0)
                    return e
                }()
                let charChain = chain(rPr.child("rStyle")?.attr("val")).compactMap { $0.child("rPr") }
                merge(into: rPr, from: inheritedR + charChain, skip: ["rStyle", "rPrChange"])
                resolveThemeFonts(rPr, themeFonts)
            }
        }
        zip["word/document.xml"] = doc.xmlData(options: [.nodePreserveWhitespace])
        return (zip.data(), extras)
    }

    static func relations(_ zip: ZipArchive, _ path: String) -> [String: String] {
        guard let d = zip[path], let root = (try? XMLDocument(data: d))?.rootElement() else { return [:] }
        var out: [String: String] = [:]
        for r in root.children("Relationship") { if let id = r.attr("Id"), let t = r.attr("Target") { out[id] = t } }
        return out
    }

    /// Word style id we keep (Title, Heading1–3, Quote) for a style's name/id.
    static func wordStyle(forName name: String, id: String) -> String? {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        if n == "title" { return "Title" }
        if n == "quote" || n == "intensequote" { return "Quote" }
        if n.hasPrefix("heading"), let level = Int(n.dropFirst(7)), (1...9).contains(level) { return "Heading\(min(level, 3))" }
        if n == "tocheading" || n == "contentsheading" { return "TOCHeading" }
        if n.hasPrefix("toc"), let level = Int(n.dropFirst(3)), (1...9).contains(level) { return "TOC\(min(level, 3))" }
        if n.hasPrefix("contents"), let level = Int(n.dropFirst(8)), (1...9).contains(level) { return "TOC\(min(level, 3))" }
        return nil
    }

    /// Moves style markers into the DOC42 style attribute of their paragraphs.
    /// Gives list paragraphs their real format (numbered, lettered, none) from the markers.
    static func restoreLists(_ text: NSMutableAttributedString, _ formats: [String: ListFormat]) {
        let pattern = try! NSRegularExpression(pattern: "\u{E004}(\\d+):(\\d+)\u{E005}")
        var lists: [String: NSTextList] = [:]
        for m in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let ns = text.string as NSString
            let key = ns.substring(with: m.range(at: 1)) + ":" + ns.substring(with: m.range(at: 2))
            let level = Int(ns.substring(with: m.range(at: 2))) ?? 0
            text.deleteCharacters(in: m.range)
            let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: m.range.location, length: 0))
            guard paragraph.length > 0 || paragraph.location < text.length,
                  let style = (text.attribute(.paragraphStyle, at: min(paragraph.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            else { continue }
            let f = formats[key] ?? ListFormat()
            if f.format == "none" || (f.format != "bullet" && f.text.isEmpty) {
                style.textLists = []
            } else {
                let list = lists[key] ?? {
                    let l = NSTextList(markerFormat: markerFormat(f, level: level), options: 0)
                    l.startingItemNumber = f.start
                    return l
                }()
                lists[key] = list
                style.textLists = Array(style.textLists.dropLast()) + [list]
            }
            text.addAttribute(.paragraphStyle, value: style, range: paragraph)
        }
    }

    private static func markerFormat(_ f: ListFormat, level: Int) -> NSTextList.MarkerFormat {
        let token: String
        switch f.format {
        case "decimal", "decimalZero": token = "{decimal}"
        case "lowerLetter": token = "{lower-alpha}"
        case "upperLetter": token = "{upper-alpha}"
        case "lowerRoman": token = "{lower-roman}"
        case "upperRoman": token = "{upper-roman}"
        default:
            // Symbol-font bullets are private-use characters: show a plain bullet.
            let ch = f.text.unicodeScalars.first
            if let ch, !(0xE000...0xF8FF).contains(ch.value), f.text.count == 1 { return NSTextList.MarkerFormat(rawValue: f.text) }
            return [.disc, .circle, .square][level % 3]
        }
        // "%1." → "{decimal}."; references to outer levels ("%1.%2.") keep only this level's number.
        var s = f.text.replacingOccurrences(of: "%\(level + 1)", with: token)
        s = s.replacingOccurrences(of: "%[0-9]\\.?", with: "", options: .regularExpression)
        return NSTextList.MarkerFormat(rawValue: s.contains(token) ? s : token + ".")
    }

    static func restoreStyles(_ text: NSMutableAttributedString) {
        let pattern = try! NSRegularExpression(pattern: "\u{E002}([A-Za-z0-9]+)\u{E003}")
        for m in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let id = (text.string as NSString).substring(with: m.range(at: 1))
            text.deleteCharacters(in: m.range)
            let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: m.range.location, length: 0))
            text.addAttribute(Styles.styleKey, value: id, range: paragraph)
        }
    }

    /// Replaces picture markers with image attachments.
    static func restoreImages(_ text: NSMutableAttributedString, _ images: [Int: (data: Data, size: NSSize)]) {
        guard !images.isEmpty else { return }
        let pattern = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")
        for m in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let n = Int((text.string as NSString).substring(with: m.range(at: 1))) ?? 0
            guard let (data, size) = images[n], let image = NSImage(data: data) else { continue }
            let attachment = NSTextAttachment()
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = "image\(n).png"
            attachment.fileWrapper = wrapper
            attachment.image = image
            attachment.bounds = NSRect(origin: .zero, size: size)
            let attrs = text.attributes(at: m.range.location, effectiveRange: nil).filter { $0.key == .paragraphStyle }
            let s = NSMutableAttributedString(attachment: attachment)
            s.addAttributes(attrs, range: NSRange(location: 0, length: s.length))
            text.replaceCharacters(in: m.range, with: s)
        }
    }

    /// Adds inherited children that the element doesn't set itself (later sources win over earlier).
    private static func merge(into target: XMLElement, from sources: [XMLElement], skip: Set<String>) {
        var effective: [String: XMLElement] = [:]
        var order: [String] = []
        for source in sources {
            for case let child as XMLElement in source.children ?? [] {
                guard let name = child.localName, !skip.contains(name) else { continue }
                if effective[name] == nil { order.append(name) }
                effective[name] = child
            }
        }
        let own = Set((target.children ?? []).compactMap { ($0 as? XMLElement)?.localName })
        for name in order where !own.contains(name) {
            if let copy = effective[name]?.copy() as? XMLElement { target.addChild(copy) }
        }
        sortBySchema(target)
    }

    // Element order required by the WordprocessingML schema; readers apply properties in sequence.
    static let rPrOrder = ["rStyle", "rFonts", "b", "bCs", "i", "iCs", "caps", "smallCaps", "strike", "dstrike", "outline", "shadow",
                           "emboss", "imprint", "noProof", "snapToGrid", "vanish", "webHidden", "color", "spacing", "w", "kern",
                           "position", "sz", "szCs", "highlight", "u", "effect", "bdr", "shd", "fitText", "vertAlign", "rtl", "cs",
                           "em", "lang", "eastAsianLayout", "specVanish", "oMath", "rPrChange"]
    static let pPrOrder = ["pStyle", "keepNext", "keepLines", "pageBreakBefore", "framePr", "widowControl", "numPr",
                           "suppressLineNumbers", "pBdr", "shd", "tabs", "suppressAutoHyphens", "kinsoku", "wordWrap",
                           "overflowPunct", "topLinePunct", "autoSpaceDE", "autoSpaceDN", "bidi", "adjustRightInd", "snapToGrid",
                           "spacing", "ind", "contextualSpacing", "mirrorIndents", "suppressOverlap", "jc", "textDirection",
                           "textAlignment", "textboxTightWrap", "outlineLvl", "divId", "cnfStyle", "rPr", "sectPr", "pPrChange"]

    private static func sortBySchema(_ e: XMLElement) {
        let order = e.localName == "rPr" ? rPrOrder : pPrOrder
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let kids = (e.children ?? []).enumerated().sorted { a, b in
            let ra = rank[a.element.localName ?? ""] ?? 1000, rb = rank[b.element.localName ?? ""] ?? 1000
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        e.setChildren(nil)
        kids.forEach { e.addChild($0) }
    }

    private static func resolveThemeFonts(_ rPr: XMLElement, _ fonts: (major: String?, minor: String?)) {
        guard let f = rPr.child("rFonts") else { return }
        for (themeAttr, attr) in [("asciiTheme", "ascii"), ("hAnsiTheme", "hAnsi"), ("cstheme", "cs"), ("eastAsiaTheme", "eastAsia")] {
            guard let theme = f.attr(themeAttr) else { continue }
            let name = theme.hasPrefix("major") ? fonts.major : fonts.minor
            if let name, f.attr(attr) == nil || f.attribute(forName: "w:" + attr) == nil {
                f.removeAttribute(forName: "w:" + attr)
                f.addAttribute(XMLNode.attribute(withName: "w:" + attr, uri: ns, stringValue: name) as! XMLNode)
            }
            f.removeAttribute(forName: "w:" + themeAttr)
        }
    }

    private static func themeFontNames(_ zip: ZipArchive) -> (major: String?, minor: String?) {
        guard let data = zip["word/theme/theme1.xml"],
              let scheme = (try? XMLDocument(data: data))?.rootElement()?.child("themeElements")?.child("fontScheme") else { return (nil, nil) }
        return (scheme.child("majorFont")?.child("latin")?.attr("typeface"), scheme.child("minorFont")?.child("latin")?.attr("typeface"))
    }

    static func descendants(_ e: XMLElement, named name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for case let c as XMLElement in e.children ?? [] {
            if c.localName == name { out.append(c) }
            // Paragraphs inside tables, text boxes etc., but runs are not nested in runs.
            if c.localName != "r" || name != "r" { out += descendants(c, named: name) }
        }
        return out
    }
}

/// The system reader sets NSTextList on list paragraphs but leaves out the marker text that
/// NSTextView displays ("\t•\t", "\t1.\t"). Adds markers and list indentation where missing.
enum ListMarkers {
    static func insert(into text: NSMutableAttributedString) {
        let ns = text.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in
            paragraphs.append(r)
        }
        var counters: [ObjectIdentifier: Int] = [:]
        var offset = 0
        for original in paragraphs {
            let r = NSRange(location: original.location + offset, length: original.length)
            guard r.length > 0 || r.location < text.length,
                  let style = text.attribute(.paragraphStyle, at: min(r.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle,
                  let list = style.textLists.last else { continue }
            let key = ObjectIdentifier(list)
            let number = (counters[key] ?? (list.startingItemNumber - 1)) + 1
            counters[key] = number
            let paragraphText = (text.string as NSString).substring(with: r)
            if paragraphText.hasPrefix("\t") { continue }   // already has a marker
            let level = CGFloat(style.textLists.count - 1)
            let p = style.mutableCopy() as! NSMutableParagraphStyle
            if p.headIndent == 0 { p.headIndent = 36 + level * 24 }
            p.firstLineHeadIndent = max(0, p.headIndent - 36)
            p.tabStops = [NSTextTab(textAlignment: .left, location: p.firstLineHeadIndent + 12), NSTextTab(textAlignment: .left, location: p.headIndent)]
            var attrs = r.length > 0 ? text.attributes(at: r.location, effectiveRange: nil) : [:]
            attrs[.paragraphStyle] = p
            let marker = NSAttributedString(string: "\t\(list.marker(forItemNumber: number))\t", attributes: attrs)
            text.insert(marker, at: r.location)
            text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: r.location, length: r.length + marker.length))
            offset += marker.length
        }
    }
}
