import AppKit
import Kit42

/// Title and author of the document (docProps/core.xml, PDF metadata, TITLE/AUTHOR fields).
struct DocInfo: Equatable {
    var title = ""
    var author = ""
    var fileName = ""
}

extension DocField {
    var displayName: String {
        switch kind {
        case .page: return L("Page Number")
        case .pageCount: return L("Page Count")
        case .date: return L("Date") + (fixed ? " (" + L("fixed") + ")" : "")
        case .time: return L("Time")
        case .title: return L("Title")
        case .author: return L("Author")
        case .fileName: return L("File Name")
        case .chapter: return L("Chapter")
        case .sequence: return L("Number Sequence") + " \(argument)"
        case .formula: return L("Formula") + " =\(argument)"
        }
    }
}

/// Where a field is shown: the page (headers, footers) and document facts.
struct FieldContext {
    var page: Int
    var pages: Int
    var info: DocInfo
    var storage: NSAttributedString?
    /// First character of the page (chapter fields in headers).
    var pageStart: Int?
}

enum Fields {
    /// Word date pictures to Unicode patterns ("am/pm" → "a").
    static func pattern(_ word: String) -> String {
        word.replacingOccurrences(of: "am/pm", with: "a", options: .caseInsensitive).replacingOccurrences(of: "\\", with: "")
    }

    static let datePresets = ["dd.MM.yyyy", "d MMMM yyyy", "MMMM d, yyyy", "yyyy-MM-dd", "dd/MM/yy", "EEEE, d MMMM yyyy"]
    static let timePresets = ["HH:mm", "HH:mm:ss", "h:mm a"]

    /// The text a field shows at a character index (-1 in headers and footers).
    static func value(_ f: DocField, at index: Int, _ c: FieldContext) -> String {
        if f.fixed, !f.result.isEmpty { return f.result }
        switch f.kind {
        case .page: return "\(c.page)"
        case .pageCount: return "\(c.pages)"
        case .date, .time:
            let fmt = DateFormatter()
            if f.format.isEmpty {
                fmt.dateStyle = f.kind == .date ? .long : .none
                fmt.timeStyle = f.kind == .time ? .short : .none
            } else {
                fmt.dateFormat = pattern(f.format)
            }
            return fmt.string(from: Date())
        case .title: return c.info.title
        case .author: return c.info.author
        case .fileName: return c.info.fileName
        case .chapter:
            guard let s = c.storage else { return "" }
            let level = Int(f.format) ?? 1
            return chapter(level, in: s, at: index >= 0 ? index : (c.pageStart ?? 0), forward: index < 0) ?? ""
        case .sequence:
            guard let s = c.storage, index >= 0 else { return "1" }
            var n = 0
            s.enumerateAttribute(.docField, in: NSRange(location: 0, length: min(s.length, index + 1))) { v, r, _ in
                if let g = v as? DocField, g.kind == .sequence, g.argument == f.argument { n += r.length }
            }
            return "\(max(1, n))"
        case .formula:
            guard let s = c.storage, index >= 0 else { return "0" }
            return formula(f.argument, in: s, at: index)
        }
    }

    /// Text of the last heading of `level` before `index` (headers: the first one on the page if any).
    static func chapter(_ level: Int, in s: NSAttributedString, at index: Int, forward: Bool) -> String? {
        let ns = s.string as NSString
        let id = "Heading\(level)"
        var last: String?
        var found: String?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, stop in
            guard r.length > 0, s.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String == id else { return }
            let text = ns.substring(with: r).replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            if r.location <= index { last = text } else {
                if forward, found == nil { found = text }
                stop.pointee = true
            }
        }
        return last ?? found
    }

    /// SUM/AVERAGE/MIN/MAX/COUNT of the numbers ABOVE, LEFT, BELOW or RIGHT of the field's table cell.
    static func formula(_ expr: String, in s: NSAttributedString, at index: Int) -> String {
        let e = expr.uppercased().replacingOccurrences(of: " ", with: "")
        guard let open = e.firstIndex(of: "("), let close = e.lastIndex(of: ")"), open < close else { return "!" }
        let fn = String(e[..<open]), dir = String(e[e.index(after: open)..<close])
        guard let grid = TableGrid(s, at: index), let me = grid.cell(containing: index) else { return "!" }
        var values: [Double] = []
        for cell in grid.cells where cell !== me {
            let take: Bool
            switch dir {
            case "ABOVE": take = cell.col == me.col && cell.row < me.row
            case "BELOW": take = cell.col == me.col && cell.row > me.row
            case "LEFT": take = cell.row == me.row && cell.col < me.col
            case "RIGHT": take = cell.row == me.row && cell.col > me.col
            default: take = false
            }
            if take, let v = number(cell.text(in: s)) { values.append(v) }
        }
        let r: Double
        switch fn {
        case "SUM": r = values.reduce(0, +)
        case "AVERAGE": r = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        case "MIN": r = values.min() ?? 0
        case "MAX": r = values.max() ?? 0
        case "COUNT": r = Double(values.count)
        case "PRODUCT": r = values.reduce(1, *)
        default: return "!"
        }
        return format(r)
    }

    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "€$£₽₺%\n\t\u{FFFC}"))
        return t.isEmpty ? nil : Double(t)
    }

    static func format(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.2f", v)
    }

    /// The field character to insert.
    static func reference(_ field: DocField, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let a = NSTextAttachment()
        a.attachmentCell = FieldCell()
        var attrs = attributes.filter { [.font, .foregroundColor, .paragraphStyle, .backgroundColor, Styles.styleKey, .docCharStyle, .underlineStyle].contains($0.key) }
        attrs[.attachment] = a
        attrs[.docField] = field
        return NSAttributedString(string: "\u{FFFC}", attributes: attrs)
    }

    /// Fields replaced by their values (formats without fields: RTF, ODT, HTML, Markdown, text).
    static func flatten(_ text: NSAttributedString, info: DocInfo = DocInfo()) -> NSAttributedString {
        var any = false
        text.enumerateAttribute(.docField, in: NSRange(location: 0, length: text.length)) { v, _, stop in if v != nil { any = true; stop.pointee = true } }
        guard any else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        var found: [(NSRange, DocField)] = []
        text.enumerateAttribute(.docField, in: NSRange(location: 0, length: text.length)) { v, r, _ in if let f = v as? DocField { found.append((r, f)) } }
        for (r, f) in found.reversed() {
            var a = out.attributes(at: r.location, effectiveRange: nil)
            a[.attachment] = nil
            a[.docField] = nil
            let v = f.result.isEmpty ? value(f, at: r.location, FieldContext(page: 1, pages: 1, info: info, storage: text)) : f.result
            out.replaceCharacters(in: r, with: NSAttributedString(string: v, attributes: a))
        }
        return out
    }

    /// A header or footer with its fields replaced for one page.
    static func resolve(_ text: NSAttributedString, _ c: FieldContext) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        var found: [(NSRange, DocField)] = []
        text.enumerateAttribute(.docField, in: NSRange(location: 0, length: text.length)) { v, r, _ in if let f = v as? DocField { found.append((r, f)) } }
        for (r, f) in found.reversed() {
            var a = out.attributes(at: r.location, effectiveRange: nil)
            a[.attachment] = nil
            a[.docField] = nil
            out.replaceCharacters(in: r, with: NSAttributedString(string: String(repeating: value(f, at: -1, c), count: r.length), attributes: a))
        }
        return out
    }
}

/// Draws a field's current value; the layout manager knows the page and the document.
final class FieldCell: NSTextAttachmentCell {
    private func label(_ lm: NSLayoutManager?, _ index: Int) -> NSAttributedString {
        guard let storage = lm?.textStorage, index < storage.length, let f = storage.attribute(.docField, at: index, effectiveRange: nil) as? DocField else {
            return NSAttributedString(string: "?")
        }
        let v = (lm as? DocLayoutManager)?.fieldValue?(f, index) ?? Fields.value(f, at: index, FieldContext(page: 1, pages: 1, info: DocInfo(), storage: storage))
        if !f.fixed { f.result = v }
        var a = storage.attributes(at: index, effectiveRange: nil).filter { [.font, .foregroundColor, .underlineStyle, .kern].contains($0.key) }
        if a[.foregroundColor] == nil { a[.foregroundColor] = NSColor.black }
        return NSAttributedString(string: v.isEmpty ? " " : v, attributes: a)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let lm = textContainer.layoutManager
        let s = label(lm, charIndex)
        let font = (lm?.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? Styles.normal.font
        return NSRect(x: 0, y: font.descender, width: ceil(s.size().width), height: ceil(font.ascender - font.descender))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let s = label(layoutManager, charIndex)
        let font = (layoutManager.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont) ?? Styles.normal.font
        // Fields are shaded on screen (as in Writer), not on paper.
        if NSGraphicsContext.currentContextDrawingToScreen(), (layoutManager as? DocLayoutManager)?.shadesFields == true {
            NSColor(white: 0.85, alpha: 1).setFill()
            cellFrame.fill()
        }
        // Flipped text view: the cell's top is at minY; draw the string with its baseline where the line's is.
        s.draw(at: NSPoint(x: cellFrame.minX, y: cellFrame.minY + (cellFrame.height - (font.ascender - font.descender))))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func wantsToTrackMouse() -> Bool { false }
}

// MARK: - Editor commands

extension DocWindowController {
    static let fieldMenuKinds: [DocField.Kind] = [.page, .pageCount, .date, .time, .title, .author, .fileName, .chapter]

    @objc func insertFieldAction(_ sender: Any?) {
        let kinds = Self.fieldMenuKinds
        let i = commandTag(of: sender)
        guard kinds.indices.contains(i) else { return }
        var f = DocField(kinds[i])
        if f.kind == .date { f = DocField(.date, format: "dd.MM.yyyy") }
        if f.kind == .time { f = DocField(.time, format: "HH:mm") }
        insertField(f)
    }

    func insertField(_ f: DocField) {
        let attrs = textView.typingAttributes
        if f.fixed, f.result.isEmpty { f.result = Fields.value(f, at: 0, fieldContext(page: 1)) }
        insert(Fields.reference(f, attributes: attrs))
        textView.undoManager?.setActionName(L("Insert Field"))
    }

    func fieldContext(page: Int) -> FieldContext {
        FieldContext(page: page, pages: paged.cards.count, info: doc?.docInfo ?? DocInfo(), storage: textView.textStorage)
    }

    /// Insert › Field › More Fields…: type, date/time format, fixed.
    @objc func moreFieldsAction(_ sender: Any?) {
        let type = NSPopUpButton(frame: .zero, pullsDown: false)
        let kinds: [DocField.Kind] = [.page, .pageCount, .date, .time, .title, .author, .fileName, .chapter, .sequence]
        type.addItems(withTitles: kinds.map { DocField($0, argument: $0 == .sequence ? "Figure" : "").displayName })
        let format = NSComboBox()
        format.addItems(withObjectValues: Fields.datePresets + Fields.timePresets)
        format.stringValue = "dd.MM.yyyy"
        let fixed = NSButton(checkboxWithTitle: L("Fixed (does not update)"), target: nil, action: nil)
        let level = NSPopUpButton(frame: .zero, pullsDown: false)
        level.addItems(withTitles: (1...6).map { L("Heading %d", $0) })
        let alert = NSAlert.form(L("Field"), info: L("Date and time formats: d, dd, M, MM, MMM, MMMM, yy, yyyy, HH, mm, ss."), ok: L("Insert"),
                                 rows: [(L("Type:"), type), (L("Format:"), format), (L("Chapter level:"), level), ("", fixed)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let kind = kinds[max(0, type.indexOfSelectedItem)]
        let f = DocField(kind, format: kind == .chapter ? "\(level.indexOfSelectedItem + 1)" : (kind == .date || kind == .time ? format.stringValue : ""),
                         argument: kind == .sequence ? "Figure" : "", fixed: fixed.state == .on)
        insertField(f)
    }

    /// Recomputes every field (page numbers, dates, formulas).
    @objc func updateFieldsAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        paged.refreshFields(force: true)
        for card in paged.cards { card.needsDisplay = true }
        _ = storage
    }

    var fieldAtCursor: DocField? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let r = textView.selectedRange()
        for i in [r.location, r.location - 1] where i >= 0 && i < storage.length {
            if let f = storage.attribute(.docField, at: i, effectiveRange: nil) as? DocField { return f }
        }
        return nil
    }
}

// MARK: - Reading fields from .docx

extension DocxStyles {
    /// Simple and complex fields we show (PAGE, NUMPAGES, DATE, …) → markers "f" with code, lock and result.
    static func markFields(_ body: XMLElement) {
        for f in descendants(body, named: "fldSimple") {
            guard let instr = f.attr("instr"), let parent = f.parent as? XMLElement else { continue }
            let result = descendants(f, named: "t").compactMap(\.stringValue).joined()
            let locked = ["1", "true", "on"].contains(f.attr("fldLock") ?? "")
            guard DocField.parse(instr, result: result, locked: locked) != nil else { continue }
            let run = fieldMark(instr, locked: locked, result: result, rPr: descendants(f, named: "rPr").first)
            parent.replaceChild(at: f.index, with: run)
        }
        // Complex fields: begin, instrText, separate, result runs, end — within one paragraph.
        for p in descendants(body, named: "p") {
            var kids = (p.children ?? []).compactMap { $0 as? XMLElement }
            var i = 0
            while i < kids.count {
                guard kids[i].localName == "r", let begin = kids[i].child("fldChar"), begin.attr("fldCharType") == "begin" else { i += 1; continue }
                var j = i + 1
                var instr = "", result = "", separated = false, nested = false
                var resultRPr: XMLElement?
                var end: Int?
                while j < kids.count {
                    let k = kids[j]
                    if k.localName == "r" {
                        if let fc = k.child("fldChar") {
                            let t = fc.attr("fldCharType")
                            if t == "begin" { nested = true; break }
                            if t == "separate" { separated = true }
                            if t == "end" { end = j; break }
                        }
                        for e in k.children("instrText") { instr += e.stringValue ?? "" }
                        if separated {
                            let t = k.children("t").compactMap(\.stringValue).joined()
                            if !t.isEmpty { result += t; resultRPr = resultRPr ?? k.child("rPr") }
                        }
                    } else if k.localName != "proofErr" && k.localName != "bookmarkStart" && k.localName != "bookmarkEnd" {
                        break   // hyperlinks, other content: leave the field alone
                    }
                    j += 1
                }
                guard let e = end, !nested, DocField.parse(instr, result: result) != nil else { i = (end ?? j) + 1; continue }
                let lock = begin.attr("fldLock").map { ["1", "true", "on"].contains($0) } ?? false
                let run = fieldMark(instr, locked: lock, result: result, rPr: resultRPr ?? kids[i].child("rPr"))
                let index = kids[i].index
                for k in kids[i...e] { k.detach() }
                p.insertChild(run, at: index)
                kids = (p.children ?? []).compactMap { $0 as? XMLElement }
                i = kids.firstIndex { $0 === run }.map { $0 + 1 } ?? kids.count
            }
        }
    }

    static func fieldMark(_ instr: String, locked: Bool, result: String, rPr: XMLElement?) -> XMLElement {
        let run = mark("f", instr.trimmingCharacters(in: .whitespaces) + "\u{E00C}" + (locked ? "1" : "0") + "\u{E00C}" + result)
        if let rPr = rPr?.copy() as? XMLElement { run.insertChild(rPr, at: 0) }
        return run
    }

    /// Title and author from docProps/core.xml.
    static func coreProperties(_ zip: ZipArchive) -> DocInfo {
        var info = DocInfo()
        guard let d = zip["docProps/core.xml"], let root = (try? XMLDocument(data: d))?.rootElement() else { return info }
        for case let e as XMLElement in root.children ?? [] {
            switch e.localName {
            case "title": info.title = e.stringValue ?? ""
            case "creator": info.author = e.stringValue ?? ""
            default: break
            }
        }
        return info
    }
}
