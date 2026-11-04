import AppKit
import Kit42

/// Footnotes, comments, bookmarks, hyperlinks and section breaks in .docx: the system reader drops them,
/// so they become text markers in document.xml ("\u{E00A}" kind payload "\u{E00B}") and are restored after reading.
/// Kinds: n footnote, c/C comment start/end, b bookmark, h/H hyperlink start/end, s section break.
extension DocxStyles {
    /// Size, margins and columns of a sectPr.
    static func sectionSetup(_ sect: XMLElement, base: PageSetup) -> PageSetup {
        var s = base
        if let sz = sect.child("pgSz"), let w = sz.attr("w").flatMap(Double.init), let h = sz.attr("h").flatMap(Double.init) {
            s.size = NSSize(width: w / 20, height: h / 20)
        }
        if let m = sect.child("pgMar") {
            func v(_ k: String, _ d: CGFloat) -> CGFloat { m.attr(k).flatMap(Double.init).map { CGFloat($0) / 20 } ?? d }
            s.margins = NSEdgeInsets(top: v("top", 72), left: v("left", 72), bottom: v("bottom", 72), right: v("right", 72))
        }
        let cols = sect.child("cols")
        s.columns = min(6, max(1, cols?.attr("num").flatMap(Int.init) ?? 1))
        s.columnSpacing = cols?.attr("space").flatMap(Double.init).map { CGFloat($0) / 20 } ?? 36
        return s
    }

    static func mark(_ kind: Character, _ payload: String = "") -> XMLElement {
        let r = XMLElement(name: "w:r", uri: ns)
        let t = XMLElement(name: "w:t", uri: ns)
        t.stringValue = "\u{E00A}\(kind)\(payload)\u{E00B}"
        r.addChild(t)
        return r
    }

    /// Puts a marker run where `e` is (inside a paragraph), or at the start of the next / end of the previous paragraph.
    private static func place(_ run: XMLElement, at e: XMLElement, forward: Bool) {
        guard let parent = e.parent as? XMLElement else { return }
        if ["p", "hyperlink", "smartTag", "ins", "fldSimple", "customXml", "sdtContent"].contains(parent.localName ?? "")
            && descendants(parent, named: "p").isEmpty {
            parent.replaceChild(at: e.index, with: run)
            return
        }
        let siblings = (parent.children ?? []).compactMap { $0 as? XMLElement }
        let i = siblings.firstIndex { $0 === e } ?? 0
        let candidates = forward ? Array(siblings[(i + 1)...]) : Array(siblings[..<i].reversed())
        e.detach()
        for c in candidates {
            let ps = c.localName == "p" ? [c] : descendants(c, named: "p")
            guard let p = forward ? ps.first : ps.last else { continue }
            if forward { p.insertChild(run, at: (p.child("pPr")?.index ?? -1) + 1) } else { p.addChild(run) }
            return
        }
    }

    private static func paragraphsText(_ e: XMLElement) -> String {
        descendants(e, named: "p").map { p in descendants(p, named: "t").compactMap(\.stringValue).joined() }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Footnotes, endnotes, comments, bookmarks, hyperlinks and section breaks → markers.
    static func markFootnotesCommentsLinks(_ body: XMLElement, zip: ZipArchive, rels: [String: String], extras: inout Extras) {
        // Notes
        for (part, tag, prefix) in [("word/footnotes.xml", "footnote", "f"), ("word/endnotes.xml", "endnote", "e")] {
            guard let d = zip[part], let root = (try? XMLDocument(data: d))?.rootElement() else { continue }
            for n in root.children(tag) where !["separator", "continuationSeparator", "continuationNotice"].contains(n.attr("type") ?? "") {
                if let id = n.attr("id") { extras.notes[prefix + id] = paragraphsText(n) }
            }
        }
        for (tag, prefix) in [("footnoteReference", "f"), ("endnoteReference", "e")] {
            for ref in descendants(body, named: tag) {
                guard let id = ref.attr("id"), let run = ref.parent as? XMLElement else { continue }
                let t = XMLElement(name: "w:t", uri: ns)
                t.stringValue = "\u{E00A}n\(prefix)\(id)\u{E00B}"
                run.replaceChild(at: ref.index, with: t)
            }
        }
        // Comments (resolved state from commentsExtended.xml)
        if let d = zip["word/comments.xml"], let root = (try? XMLDocument(data: d))?.rootElement() {
            var done: [String: Bool] = [:]
            if let e = zip["word/commentsExtended.xml"], let r = (try? XMLDocument(data: e))?.rootElement() {
                for c in r.children("commentEx") { if let p = c.attr("paraId") { done[p] = c.attr("done") == "1" } }
            }
            let iso = ISO8601DateFormatter()
            for c in root.children("comment") {
                guard let id = c.attr("id") else { continue }
                let dateText = c.attr("date") ?? ""
                let date = iso.date(from: dateText) ?? iso.date(from: dateText + "Z") ?? Date()
                let lastPara = descendants(c, named: "p").last?.attr("paraId") ?? ""
                extras.comments[id] = DocComment(author: c.attr("author") ?? "", initials: c.attr("initials"), date: date,
                                                 text: paragraphsText(c), resolved: done[lastPara] ?? false)
            }
        }
        for e in descendants(body, named: "commentRangeStart") { if let id = e.attr("id") { place(mark("c", id), at: e, forward: true) } }
        for e in descendants(body, named: "commentRangeEnd") { if let id = e.attr("id") { place(mark("C", id), at: e, forward: false) } }
        for e in descendants(body, named: "commentReference") { e.detach() }
        // Bookmarks (targets of internal links, e.g. table of contents entries)
        for e in descendants(body, named: "bookmarkStart") {
            guard let name = e.attr("name"), !name.isEmpty, name != "_GoBack" else { continue }
            place(mark("b", name), at: e, forward: true)
        }
        // Hyperlinks
        for e in descendants(body, named: "hyperlink") {
            let target = e.attr("anchor").map { "#" + $0 } ?? e.attr("id").flatMap { rels[$0] }
            guard let target, !target.isEmpty else { continue }
            e.insertChild(mark("h", target), at: 0)
            e.addChild(mark("H"))
        }
        // Section breaks: the sectPr in a paragraph ends its section.
        var n = 0
        for p in descendants(body, named: "p") {
            guard let sect = p.child("pPr")?.child("sectPr") else { continue }
            n += 1
            extras.sections[n] = sectionSetup(sect, base: PageSetup())
            p.addChild(mark("s", "\(n)"))
        }
    }

    /// Replaces the markers with footnote references, comment ranges, bookmarks, links and section breaks.
    static func restoreMarks(_ text: NSMutableAttributedString, _ extras: Extras) {
        let pattern = try! NSRegularExpression(pattern: "\u{E00A}([ncCbhHsrRpxXftqeEdT])([^\u{E00B}]*)\u{E00B}")
        let matches = pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return }
        let ns = text.string as NSString
        struct Mark { let kind: String; let payload: String; let at: Int }   // `at`: position once markers are replaced
        var marks: [Mark] = []
        var shift = 0
        for m in matches {
            let kind = ns.substring(with: m.range(at: 1))
            marks.append(Mark(kind: kind, payload: ns.substring(with: m.range(at: 2)), at: m.range.location - shift))
            shift += m.range.length - (kind == "n" || kind == "s" || kind == "f" ? 1 : 0)
        }
        for (m, mark) in zip(matches, marks).reversed() {
            let attrs = text.attributes(at: m.range.location, effectiveRange: nil)
            switch mark.kind {
            case "n":
                var a = attrs
                a[.superscript] = nil
                a[.baselineOffset] = nil
                if m.range.location > 0, let f = text.attribute(.font, at: m.range.location - 1, effectiveRange: nil) { a[.font] = f }
                text.replaceCharacters(in: m.range, with: Notes.reference(DocNote(extras.notes[mark.payload] ?? ""), attributes: a))
            case "f":
                let parts = mark.payload.components(separatedBy: "\u{E00C}")
                let field = DocField.parse(parts[0], result: parts.count > 2 ? parts[2] : "", locked: parts.count > 1 && parts[1] == "1") ?? DocField(.page)
                var a = attrs
                a[.link] = nil
                text.replaceCharacters(in: m.range, with: Fields.reference(field, attributes: a))
            case "s":
                var a = attrs
                a[.docSection] = (extras.sections[Int(mark.payload) ?? 0] ?? PageSetup()).section
                a[.link] = nil
                text.replaceCharacters(in: m.range, with: NSAttributedString(string: "\u{000C}", attributes: a))
            default:
                text.deleteCharacters(in: m.range)
            }
        }
        var commentStarts: [String: Int] = [:]
        var links: [(String, Int)] = []
        var revisionStarts: [String: Int] = [:]
        var charStyles: [(String, Int)] = []
        var tables: [(payload: String, at: Int)] = []
        var boxes: [(payload: String, at: Int)] = []
        var effects: [(String, Int)] = []
        for mark in marks {
            switch mark.kind {
            case "q": boxes.append((mark.payload, mark.at))
            case "T":
                guard text.length > 0 else { continue }
                let para = (text.string as NSString).paragraphRange(for: NSRange(location: min(mark.at, text.length - 1), length: 0))
                let stops = mark.payload.split(separator: ",").compactMap { t -> NSTextTab? in
                    guard let kind = t.first, let pos = Double(t.dropFirst()) else { return nil }
                    let align: NSTextAlignment = kind == "c" ? .center : kind == "r" ? .right : .left
                    return NSTextTab(textAlignment: align, location: CGFloat(pos) / 20, options: kind == "d" ? [.columnTerminators: NSCharacterSet(charactersIn: ".,")] : [:])
                }.sorted { $0.location < $1.location }
                text.enumerateAttribute(.paragraphStyle, in: para) { v, r, _ in
                    let p = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                    p.tabStops = stops
                    text.addAttribute(.paragraphStyle, value: p, range: r)
                }
            case "e": effects.append((mark.payload, mark.at))
            case "E":
                if let (e, start) = effects.popLast(), mark.at > start {
                    let r = NSRange(location: start, length: mark.at - start)
                    if e.contains("smallCaps") { text.addAttribute(.docSmallCaps, value: true, range: r) }
                    if e.split(separator: ",").contains("caps") { text.addAttribute(.docAllCaps, value: true, range: r) }
                }
            case "d":
                if mark.at < text.length, let lines = Int(mark.payload) { text.addAttribute(.docDropCap, value: lines, range: NSRange(location: mark.at, length: 1)) }
            case "t": tables.append((mark.payload, mark.at))
            case "x": charStyles.append((mark.payload, mark.at))
            case "X":
                if let (id, start) = charStyles.popLast(), mark.at > start {
                    text.addAttribute(.docCharStyle, value: id, range: NSRange(location: start, length: mark.at - start))
                }
            case "r": revisionStarts[mark.payload] = mark.at
            case "R":
                if let start = revisionStarts[mark.payload], mark.at > start, let rev = extras.revisions[mark.payload] {
                    text.addAttribute(.docRevision, value: rev, range: NSRange(location: start, length: mark.at - start))
                }
            case "p":
                // Tracked paragraph mark: the newline right after the marker.
                if mark.at < text.length, (text.string as NSString).character(at: mark.at) == 10, let rev = extras.revisions[mark.payload] {
                    text.addAttribute(.docRevision, value: rev, range: NSRange(location: mark.at, length: 1))
                }
            case "c": commentStarts[mark.payload] = mark.at
            case "C":
                if let start = commentStarts[mark.payload], mark.at > start, let c = extras.comments[mark.payload] {
                    text.addAttribute(.docComment, value: c, range: NSRange(location: start, length: mark.at - start))
                } else if let start = commentStarts[mark.payload], mark.at == start, text.length > 0, let c = extras.comments[mark.payload] {
                    // A comment on a point (ODT, RTF): it covers the word before it (or after it).
                    let ns = text.string as NSString
                    func isSpace(_ i: Int) -> Bool { i < 0 || i >= ns.length || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: i)) ?? " ") }
                    var a = start, b = start
                    if !isSpace(start - 1) {
                        while !isSpace(a - 1) { a -= 1 }
                    } else {
                        while !isSpace(b) { b += 1 }
                    }
                    if b == a, start < ns.length { b = start + 1 }
                    if b > a { text.addAttribute(.docComment, value: c, range: NSRange(location: a, length: b - a)) }
                }
            case "b":
                guard text.length > 0 else { continue }
                let p = (text.string as NSString).paragraphRange(for: NSRange(location: min(mark.at, text.length - 1), length: 0))
                if text.attribute(.docBookmark, at: p.location, effectiveRange: nil) == nil { text.addAttribute(.docBookmark, value: mark.payload, range: p) }
            case "h": links.append((mark.payload, mark.at))
            case "H":
                guard let (url, start) = links.popLast(), mark.at > start else { continue }
                let value = linkValue(url)
                text.addAttribute(.link, value: value, range: NSRange(location: start, length: mark.at - start))
            default: break
            }
        }
        // Table of contents entries: dot leaders on their tabs, page numbers at the right margin
        // (the system reader keeps no right tab stops).
        let width = extras.setup.textSize.width
        text.enumerateAttribute(Styles.styleKey, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            guard let s = v as? String, s.hasPrefix("TOC"), s != "TOCHeading" else { return }
            let sub = (text.string as NSString).substring(with: r) as NSString
            for i in 0..<sub.length where sub.character(at: i) == 9 { text.addAttribute(.docTabLeader, value: "dot", range: NSRange(location: r.location + i, length: 1)) }
            text.enumerateAttribute(.paragraphStyle, in: r) { pv, pr, _ in
                let p = ((pv as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                guard !p.tabStops.contains(where: { $0.alignment == .right }) else { return }
                p.tabStops = [NSTextTab(textAlignment: .right, location: width - 1)]
                text.addAttribute(.paragraphStyle, value: p, range: pr)
            }
        }
        restoreBoxes(text, boxes)
        restoreTables(text, tables)
    }
}

extension DocxStyles {
    /// "t=sz:color:space;l=…;b=…;r=…;f=fill" for a paragraph's w:pBdr and w:shd (nil: none).
    static func paragraphBoxPayload(_ pPr: XMLElement) -> String? {
        var parts: [String] = []
        if let b = pPr.child("pBdr") {
            for (name, key) in [("top", "t"), ("left", "l"), ("bottom", "b"), ("right", "r")] {
                guard let e = b.child(name) ?? (name == "left" ? b.child("start") : name == "right" ? b.child("end") : nil),
                      !["nil", "none"].contains(e.attr("val") ?? "single") else { continue }
                parts.append("\(key)=\(e.attr("sz") ?? "4"):\(e.attr("color").flatMap { $0 == "auto" ? nil : $0 } ?? "000000"):\(e.attr("space") ?? "1")")
            }
        }
        if let fill = pPr.child("shd")?.attr("fill"), fill != "auto", fill.uppercased() != "FFFFFF" { parts.append("f=\(fill)") }
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }

    /// Paragraphs with the same borders next to each other share one box (an NSTextBlock).
    static func restoreBoxes(_ text: NSMutableAttributedString, _ marks: [(payload: String, at: Int)]) {
        let ns = text.string as NSString
        var last: (payload: String, end: Int, block: NSTextBlock)?
        for m in marks where m.at <= text.length && text.length > 0 {
            let para = ns.paragraphRange(for: NSRange(location: min(m.at, text.length - 1), length: 0))
            let block: NSTextBlock
            if let l = last, l.payload == m.payload, l.end == para.location { block = l.block } else {
                block = NSTextBlock()
                var pad: CGFloat = 1
                for kv in m.payload.split(separator: ";") {
                    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    guard p.count == 2 else { continue }
                    if p[0] == "f" { block.backgroundColor = hexColor(p[1]); continue }
                    let v = p[1].split(separator: ":").map(String.init)
                    let edge: NSRectEdge = ["t": .minY, "l": .minX, "b": .maxY, "r": .maxX][p[0]] ?? .minY
                    block.setWidth(CGFloat(Double(v.first ?? "4") ?? 4) / 8, type: .absoluteValueType, for: .border, edge: edge)
                    if v.count > 1 { block.setBorderColor(hexColor(v[1]) ?? .black, for: edge) }
                    if v.count > 2 { pad = max(pad, CGFloat(Double(v[2]) ?? 1)) }
                }
                block.setWidth(pad, type: .absoluteValueType, for: .padding)
                block.setValue(100, type: .percentageValueType, for: .width)
            }
            text.enumerateAttribute(.paragraphStyle, in: para) { v, r, _ in
                let p = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                guard !(p.textBlocks.last is NSTextTableBlock) else { return }
                p.textBlocks = [block]
                text.addAttribute(.paragraphStyle, value: p, range: r)
            }
            last = (m.payload, NSMaxRange(para), block)
        }
    }

    /// Word's drop cap is a framed paragraph holding the letter: the letter moves to the start of the next paragraph.
    static func markDropCaps(_ body: XMLElement) {
        for p in descendants(body, named: "p") {
            guard let frame = p.child("pPr")?.child("framePr"), let kind = frame.attr("dropCap"), kind == "drop" || kind == "margin",
                  let parent = p.parent as? XMLElement else { continue }
            let letter = descendants(p, named: "t").compactMap(\.stringValue).joined()
            let lines = frame.attr("lines").flatMap(Int.init) ?? 3
            let siblings = (parent.children ?? []).compactMap { $0 as? XMLElement }
            guard let i = siblings.firstIndex(where: { $0 === p }), i + 1 < siblings.count, siblings[i + 1].localName == "p", !letter.isEmpty else { continue }
            let next = siblings[i + 1]
            let run = XMLElement(name: "w:r", uri: ns)
            if let rPr = descendants(next, named: "r").first?.child("rPr")?.copy() as? XMLElement { run.addChild(rPr) }
            let t = XMLElement(name: "w:t", uri: ns)
            t.stringValue = letter
            t.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
            run.addChild(t)
            let at = (next.child("pPr")?.index ?? -1) + 1
            next.insertChild(run, at: at)
            next.insertChild(mark("d", "\(lines)"), at: at)
            p.detach()
        }
    }
}

/// Link attribute value: "#bookmark" stays a string, addresses become URLs.
func linkValue(_ s: String) -> Any {
    if !s.hasPrefix("#"), let u = URL(string: s) { return u }
    return s
}
