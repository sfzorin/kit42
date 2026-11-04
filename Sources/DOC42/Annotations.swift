import AppKit
import Kit42

/// Comments (and ODT footnotes) through the system RTF, ODT and HTML writers: the text gets markers
/// ("\u{E00A}c1\u{E00B}" … "\u{E00A}C1\u{E00B}", footnote "\u{E00A}n1\u{E00B}"), the writer's output gets the real objects.
/// Reading goes the other way: the file's comments and notes become the markers `DocxStyles.restoreMarks` handles.
enum CommentMarkers {
    static let pattern = try! NSRegularExpression(pattern: "(?:\u{E00A}|&#57354;|&#xE00A;)([cCn])(\\d+)(?:\u{E00B}|&#57355;|&#xE00B;)")

    /// A copy of the text with markers; comments and notes numbered from 1 in text order.
    /// `clamp`: a comment ends at the end of its first paragraph (HTML elements can't span paragraphs).
    static func insert(_ text: NSAttributedString, notes: Bool, clamp: Bool = false) -> (NSAttributedString, [DocComment], [DocNote]) {
        let ns = text.string as NSString
        struct Event { let at: Int; let order: Int; let marker: String; let replaces: Bool }
        var events: [Event] = []
        let comments = CLI.commentsOf(text)
        func isMark(_ i: Int) -> Bool { [10, 13, 0x2029, 0x0C].contains(ns.character(at: i)) }
        for (k, (range, _)) in comments.enumerated() {
            var start = range.location, end = NSMaxRange(range)
            while start < end, isMark(start) { start += 1 }
            if clamp { end = min(end, NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))) }
            while end > start, isMark(end - 1) { end -= 1 }
            if end <= start { end = NSMaxRange(range); start = range.location }
            events.append(Event(at: start, order: 2, marker: "c\(k + 1)", replaces: false))
            events.append(Event(at: end, order: 0, marker: "C\(k + 1)", replaces: false))
        }
        var noteList: [DocNote] = []
        if notes {
            for (r, n) in Notes.all(in: text) {
                noteList.append(n)
                events.append(Event(at: r.location, order: 1, marker: "n\(noteList.count)", replaces: true))
            }
        }
        guard !events.isEmpty else { return (text, [], []) }
        events.sort { $0.at != $1.at ? $0.at < $1.at : $0.order < $1.order }   // at one place: ends, notes, then starts
        let out = NSMutableAttributedString()
        var last = 0
        for e in events {
            if e.at > last { out.append(text.attributedSubstring(from: NSRange(location: last, length: e.at - last))) }
            last = max(last, e.at)
            var attrs = text.length == 0 ? [:] : text.attributes(at: min(max(0, e.at - (e.order == 0 ? 1 : 0)), text.length - 1), effectiveRange: nil)
            for key in [NSAttributedString.Key.attachment, .docNote, .docComment, .link] { attrs[key] = nil }
            out.append(NSAttributedString(string: "\u{E00A}\(e.marker)\u{E00B}", attributes: attrs))
            if e.replaces { last = e.at + 1 }
        }
        if last < text.length { out.append(text.attributedSubstring(from: NSRange(location: last, length: text.length - last))) }
        return (out, comments.map(\.1), noteList)
    }

    /// Replaces every marker in a writer's output.
    static func replace(_ s: String, _ body: (Character, Int) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            out += body(Character(ns.substring(with: m.range(at: 1))), Int(ns.substring(with: m.range(at: 2))) ?? 0)
        }
        return out + ns.substring(from: last)
    }

    static func localISO(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: d)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) ?? iso.date(from: s + "Z") { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: HTML

    /// Comments as <mark title="Author: text"> around their text.
    static func finishHTML(_ data: Data, comments: [DocComment]) -> Data {
        guard !comments.isEmpty, let s = String(data: data, encoding: .utf8) else { return data }
        let out = replace(s) { kind, n in
            guard n >= 1, n <= comments.count else { return "" }
            let c = comments[n - 1]
            if kind == "C" { return "</mark>" }
            let title = (c.author.isEmpty ? "" : c.author + ": ") + c.text
            return "<mark class=\"comment\" title=\"\(xmlEscape(title))\" data-author=\"\(xmlEscape(c.author))\" data-date=\"\(localISO(c.date))\">"
        }
        return Data(out.utf8)
    }
}

// MARK: - OpenDocument

extension OdtFormat {
    /// office:annotation (with office:annotation-end) → comment markers; text:note → footnote markers.
    static func markAnnotations(_ root: XMLElement, extras: inout DocxStyles.Extras) {
        var n = 0
        var ids: [String: String] = [:]
        for a in descendants(root, named: "annotation") {
            n += 1
            let id = "o\(n)"
            let author = a.child("creator")?.stringValue ?? ""
            let date = CommentMarkers.parseDate(a.child("date")?.stringValue) ?? Date()
            let text = a.children("p").map { textOf($0) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = a.attr("resolved") == "true"
            extras.comments[id] = DocComment(author: author, date: date, text: text, resolved: resolved)
            if let name = a.attr("name"), !name.isEmpty { ids[name] = id }
            let hasEnd = a.attr("name").map { name in descendants(root, named: "annotation-end").contains { $0.attr("name") == name } } ?? false
            let marker = "\u{E00A}c\(id)\u{E00B}" + (hasEnd ? "" : "\u{E00A}C\(id)\u{E00B}")
            if let parent = a.parent as? XMLElement { parent.replaceChild(at: a.index, with: XMLNode.text(withStringValue: marker) as! XMLNode) }
        }
        for e in descendants(root, named: "annotation-end") {
            guard let name = e.attr("name"), let id = ids[name], let parent = e.parent as? XMLElement else { e.detach(); continue }
            parent.replaceChild(at: e.index, with: XMLNode.text(withStringValue: "\u{E00A}C\(id)\u{E00B}") as! XMLNode)
        }
        var k = 0
        for note in descendants(root, named: "note") {
            k += 1
            let body = note.child("note-body").map { b in b.children("p").map { textOf($0) }.joined(separator: "\n") } ?? ""
            let prefix = note.attr("note-class") == "endnote" ? "oe" : "of"
            extras.notes["\(prefix)\(k)"] = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parent = note.parent as? XMLElement {
                parent.replaceChild(at: note.index, with: XMLNode.text(withStringValue: "\u{E00A}n\(prefix)\(k)\u{E00B}") as! XMLNode)
            }
        }
    }

    private static func textOf(_ e: XMLElement) -> String {
        var s = ""
        for node in e.children ?? [] {
            if let el = node as? XMLElement {
                switch el.localName {
                case "s": s += String(repeating: " ", count: Int(el.attr("c") ?? "1") ?? 1)
                case "tab": s += "\t"
                case "line-break": s += "\n"
                case "note", "annotation": break
                default: s += textOf(el)
                }
            } else if node.kind == .text {
                s += node.stringValue ?? ""
            }
        }
        return s
    }

    /// Comment and footnote markers in the system writer's content.xml → office:annotation / text:note.
    static func finishAnnotations(_ content: String, comments: [DocComment], notes: [DocNote]) -> String {
        guard !comments.isEmpty || !notes.isEmpty else { return content }
        var s = CommentMarkers.replace(content) { kind, n in
            switch kind {
            case "c":
                guard n >= 1, n <= comments.count else { return "" }
                let c = comments[n - 1]
                let paragraphs = c.text.components(separatedBy: "\n").map { "<text:p>\(xmlEscape($0))</text:p>" }.joined()
                return "<office:annotation office:name=\"__Annotation__\(n)\"\(c.resolved ? " loext:resolved=\"true\"" : "")>"
                    + "<dc:creator>\(xmlEscape(c.author))</dc:creator><dc:date>\(CommentMarkers.localISO(c.date))</dc:date>"
                    + paragraphs + "</office:annotation>"
            case "C":
                return n >= 1 && n <= comments.count ? "<office:annotation-end office:name=\"__Annotation__\(n)\"/>" : ""
            default:
                guard n >= 1, n <= notes.count else { return "" }
                let paragraphs = notes[n - 1].text.components(separatedBy: "\n").map { "<text:p>\(xmlEscape($0))</text:p>" }.joined()
                return "<text:note text:id=\"ftn\(n)\" text:note-class=\"footnote\"><text:note-citation>\(n)</text:note-citation>"
                    + "<text:note-body>\(paragraphs)</text:note-body></text:note>"
            }
        }
        // Namespaces the annotations use.
        for (prefix, uri) in [("dc", "http://purl.org/dc/elements/1.1/"), ("loext", "urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0"),
                              ("text", "urn:oasis:names:tc:opendocument:xmlns:text:1.0")] where !s.contains("xmlns:\(prefix)=") {
            if let r = s.range(of: "<office:document-content ") { s.replaceSubrange(r, with: "<office:document-content xmlns:\(prefix)=\"\(uri)\" ") }
        }
        return s
    }
}

// MARK: - RTF (Word annotation syntax)

extension RtfFormat {
    /// Word's packed date-time (minutes, hours, day, month, year − 1900).
    static func dttm(_ d: Date) -> Int {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
        return (c.minute ?? 0) | (c.hour ?? 0) << 6 | (c.day ?? 1) << 11 | (c.month ?? 1) << 16 | ((c.year ?? 2000) - 1900) << 20 | ((c.weekday ?? 1) - 1) << 29
    }

    static func date(dttm v: Int) -> Date? {
        var c = DateComponents()
        c.minute = v & 63
        c.hour = (v >> 6) & 31
        c.day = (v >> 11) & 31
        c.month = (v >> 16) & 15
        c.year = 1900 + ((v >> 20) & 511)
        guard c.day! > 0, c.month! > 0 else { return nil }
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /// Comment markers in the system writer's RTF → {\*\atrfstart}…{\*\atrfend}{\*\atnauthor}\chatn{\*\annotation …}.
    static func finishAnnotations(_ rtf: String, comments: [DocComment]) -> String {
        guard !comments.isEmpty else { return rtf }
        let marker = try! NSRegularExpression(pattern: "(?:\\\\uc0 ?)?\\\\u(?:57354|-8182) ?([cC])(\\d+)(?:\\\\uc0 ?)?\\\\u(?:57355|-8181) ?")
        let ns = rtf as NSString
        var out = ""
        var last = 0
        for m in marker.matches(in: rtf, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let n = Int(ns.substring(with: m.range(at: 2))) ?? 0
            guard n >= 1, n <= comments.count else { continue }
            let c = comments[n - 1]
            if ns.substring(with: m.range(at: 1)) == "c" {
                out += "{\\*\\atrfstart \(n)}"
            } else {
                let text = c.text.components(separatedBy: "\n").map(rtfEscape).joined(separator: "\\par ")
                out += "{\\*\\atrfend \(n)}{\\*\\atnid \(rtfEscape(c.initials))}{\\*\\atnauthor \(rtfEscape(c.author))}\\chatn "
                    + "{\\*\\annotation{\\*\\atnref \(n)}{\\*\\atndate \(dttm(c.date))}\\pard\\plain {\\field{\\*\\fldinst {\\chatn }}{\\fldrslt }}\(text)}"
            }
        }
        return out + ns.substring(from: last)
    }
}
