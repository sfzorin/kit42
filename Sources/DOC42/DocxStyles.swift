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
        /// Tracked changes by marker id; track changes on in the file's settings.
        var revisions: [String: DocRevision] = [:]
        var trackRevisions = false
        /// Style definitions of the file (styles.xml).
        var styles: [DocStyle] = []
        /// Title and author (docProps/core.xml).
        var info = DocInfo()
        /// Wrap, position, border and crop of pictures by marker number.
        var imageProps: [Int: DocImage] = [:]
        /// Page colour, watermark text, automatic hyphenation.
        var background: NSColor?
        var watermark = ""
        var hyphenate = false
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

    /// A .docx read into text with everything restored (`isPart`: a header or footer read as a document).
    static func read(_ data: Data, isPart: Bool = false) throws -> (NSMutableAttributedString, Extras) {
        let (source, extras) = flattenWithExtras(data, isPart: isPart)
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(data: source, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil))
        restoreImages(text, extras.images, props: extras.imageProps)
        restoreStyles(text)
        restoreLists(text, extras.lists)
        restoreMarks(text, extras)
        ListMarkers.insert(into: text)
        return (text, extras)
    }

    static func flattenWithExtras(_ data: Data, isPart: Bool = false) -> (data: Data, extras: Extras) {
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

        // Style definitions; character styles become markers around their runs.
        var used = Set<String>()
        for e in descendants(body, named: "pStyle") + descendants(body, named: "rStyle") { if let v = e.attr("val") { used.insert(v) } }
        extras.styles = readStyles(styles, themeFonts: themeFonts, used: used)
        let charStyles = Set(extras.styles.filter { $0.kind == .character }.map(\.id))
        for r in descendants(body, named: "r") {
            guard let fileId = r.child("rPr")?.child("rStyle")?.attr("val"), let parent = r.parent as? XMLElement else { continue }
            let id = styleId(fileId, name: byId[fileId]?.child("name")?.attr("val"))
            guard charStyles.contains(id) else { continue }
            parent.insertChild(mark("x", id), at: r.index)
            parent.insertChild(mark("X"), at: r.index + 1)
        }

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
            extras.imageProps[n] = imageProps(drawing)
            let t = XMLElement(name: "w:t", uri: ns)
            t.stringValue = "\(markerStart)\(n)\(markerEnd)"
            if let parent = drawing.parent as? XMLElement { parent.replaceChild(at: drawing.index, with: t) }
        }

        markFields(body)
        markTables(body, styles: styles)
        markFootnotesCommentsLinks(body, zip: zip, rels: rels, extras: &extras)
        extras.info = coreProperties(zip)
        markRevisions(body, extras: &extras)
        if let settings = zip["word/settings.xml"], let root = (try? XMLDocument(data: settings))?.rootElement(),
           let track = root.child("trackRevisions") {
            extras.trackRevisions = !["false", "0", "off"].contains(track.attr("val") ?? "")
        }

        // Page setup, header and footer from the (last) section.
        if let sect = body.child("sectPr") {
            extras.hasSetup = true
            extras.setup = sectionSetup(sect, base: extras.setup)
        }
        if !isPart {
            readHeaders(body, zip: zip, rels: rels, extras: &extras)
            if let d = zip["word/settings.xml"], let root = (try? XMLDocument(data: d))?.rootElement(), let h = root.child("autoHyphenation") { extras.hyphenate = onOff(h) }
            if let bg = doc.rootElement()?.child("background")?.attr("color"), let c = hexColor(bg) { extras.background = c }
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
            if let id = styleId, id != defaultParagraph, case let word = Self.styleId(id, name: byId[id]?.child("name")?.attr("val")), word != "Normal", byId[id] != nil {
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
                for k in 0..<level where extras.lists["\(numId):\(k)"] == nil { if let f = formats[numId]?[k] { extras.lists["\(numId):\(k)"] = f } }
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
                // The system reader takes <w:b w:val="0"/> for bold: switched-off toggles are left out.
                for case let e as XMLElement in rPr.children ?? [] where ["b", "bCs", "i", "iCs", "strike", "dstrike", "caps", "smallCaps", "vanish"].contains(e.localName ?? "") && !onOff(e) {
                    e.detach()
                }
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
        if n.hasPrefix("heading"), let level = Int(n.dropFirst(7)), (1...9).contains(level) { return "Heading\(min(level, 6))" }
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
                // The list of every level up to this one (shared by all paragraphs of the numbering).
                let numId = ns.substring(with: m.range(at: 1))
                style.textLists = (0...level).map { k in
                    let lk = "\(numId):\(k)"
                    if let l = lists[lk] { return l }
                    let fk = formats[lk] ?? (k == level ? f : ListFormat(format: f.format, text: f.format == "bullet" ? "•" : "%\(k + 1).", start: 1))
                    let prepend = fk.format != "bullet" && k > 0 && fk.text.range(of: "%[1-\(k)]", options: .regularExpression) != nil
                    let l = NSTextList(markerFormat: markerFormat(fk, level: k), options: prepend ? Int(NSTextList.Options.prependEnclosingMarker.rawValue) : 0)
                    l.startingItemNumber = fk.start
                    lists[lk] = l
                    return l
                }
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
        // "%1." → "{decimal}."; outer levels ("%1.%2.") are the enclosing lists' markers, only this level's part stays.
        var own = f.text
        if let r = own.range(of: "%\(level + 1)") { own = String(own[r.lowerBound...]) }
        var s = own.replacingOccurrences(of: "%\(level + 1)", with: token)
        s = s.replacingOccurrences(of: "%[0-9]\\.?", with: "", options: .regularExpression)
        return NSTextList.MarkerFormat(rawValue: s.contains(token) ? s : token + ".")
    }

    static func restoreStyles(_ text: NSMutableAttributedString) {
        let pattern = try! NSRegularExpression(pattern: "\u{E002}([^\u{E003}]+)\u{E003}")
        for m in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let id = (text.string as NSString).substring(with: m.range(at: 1))
            text.deleteCharacters(in: m.range)
            let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: m.range.location, length: 0))
            text.addAttribute(Styles.styleKey, value: id, range: paragraph)
        }
    }

    /// Replaces picture markers with image attachments.
    static func restoreImages(_ text: NSMutableAttributedString, _ images: [Int: (data: Data, size: NSSize)], props: [Int: DocImage] = [:]) {
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
            attachment.attachmentCell = ImageCell(imageCell: image)
            let attrs = text.attributes(at: m.range.location, effectiveRange: nil).filter { $0.key == .paragraphStyle }
            let s = NSMutableAttributedString(attachment: attachment)
            s.addAttributes(attrs, range: NSRange(location: 0, length: s.length))
            if let p = props[n] { s.addAttribute(.docImage, value: p, range: NSRange(location: 0, length: s.length)) }
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
        // Markers in text order; the paragraph ranges move as markers go in (work backwards).
        for m in ListNumbering.markers(text).reversed() {
            let r = m.range
            let paragraphText = (text.string as NSString).substring(with: r)
            if paragraphText.hasPrefix("\t") { continue }   // already has a marker
            guard let style = text.attribute(.paragraphStyle, at: min(r.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle else { continue }
            let p = style.mutableCopy() as! NSMutableParagraphStyle
            let heading = (text.attribute(Styles.styleKey, at: min(r.location, text.length - 1), effectiveRange: nil) as? String)?.hasPrefix("Heading") == true
            if heading {
                ListNumbering.indent(p, level: m.level, heading: true)
            } else {
                if p.headIndent == 0 { p.headIndent = 36 + CGFloat(m.level) * 24 }
                p.firstLineHeadIndent = max(0, p.headIndent - 36)
                p.tabStops = [NSTextTab(textAlignment: .left, location: p.firstLineHeadIndent + 12), NSTextTab(textAlignment: .left, location: p.headIndent)]
            }
            var attrs = r.length > 0 ? text.attributes(at: r.location, effectiveRange: nil) : [:]
            attrs[.paragraphStyle] = p
            attrs[.attachment] = nil
            attrs[.docField] = nil
            attrs[.docNote] = nil
            let marker = NSAttributedString(string: "\t\(m.marker)\t", attributes: attrs)
            text.insert(marker, at: r.location)
            text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: r.location, length: r.length + marker.length))
        }
    }
}
