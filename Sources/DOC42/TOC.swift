import AppKit
import Kit42

/// Table of contents built from Title and Heading 1–3 paragraphs: entries with dot leaders and page numbers,
/// each a link to its heading's bookmark. Its paragraphs carry the Word styles TOCHeading and TOC1–3,
/// which is how "Update Table of Contents" finds it (also in .docx files from Word).
enum TOC {
    struct Heading {
        let range: NSRange
        let level: Int
        let title: String
    }

    static func isTOCStyle(_ s: String?) -> Bool { s?.hasPrefix("TOC") == true }

    static func headings(_ text: NSAttributedString) -> [Heading] {
        var out: [Heading] = []
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            guard r.length > 0, text.attribute(.paragraphStyle, at: r.location, effectiveRange: nil).map({ ($0 as? NSParagraphStyle)?.textBlocks.isEmpty ?? true }) ?? true,
                  let style = Styles.wordStyle(text, r), !isTOCStyle(style) else { return }
            let level: Int
            switch style {
            case "Title", "Heading1": level = 1
            case "Heading2": level = 2
            case "Heading3": level = 3
            default: return
            }
            let title = ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{000C}", with: "")
                .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { out.append(Heading(range: r, level: level, title: title)) }
        }
        return out
    }

    /// The existing table of contents: consecutive paragraphs in TOC styles.
    static func range(in text: NSAttributedString) -> NSRange? {
        var found: NSRange?
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, stop in
            let s = text.attribute(Styles.styleKey, at: enclosing.location, effectiveRange: nil) as? String
            if isTOCStyle(s) {
                found = found.map { NSUnionRange($0, enclosing) } ?? enclosing
            } else if found != nil {
                stop.pointee = true
            }
        }
        return found
    }

    /// Gives headings without a bookmark a new one ("_Toc…", as Word names them). Returns the changed ranges.
    static func addBookmarks(_ text: NSMutableAttributedString, _ headings: [Heading]) -> [NSRange] {
        var changed: [NSRange] = []
        var used = Set<String>()
        text.enumerateAttribute(.docBookmark, in: NSRange(location: 0, length: text.length)) { v, _, _ in if let s = v as? String { used.insert(s) } }
        for h in headings where text.attribute(.docBookmark, at: h.range.location, effectiveRange: nil) == nil {
            var name: String
            repeat { name = "_Toc" + String(Int.random(in: 100_000_000...999_999_999)) } while used.contains(name)
            used.insert(name)
            text.addAttribute(.docBookmark, value: name, range: h.range)
            changed.append(h.range)
        }
        return changed
    }

    /// The table: a "Contents" heading and one entry per heading (title, dot leader, page number), linked to the heading.
    static func build(_ text: NSAttributedString, _ headings: [Heading], pages: [Int], width: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var title = Styles.all[1].attributes
        title[Styles.styleKey] = "TOCHeading"
        out.append(NSAttributedString(string: L("Contents") + "\n", attributes: title))
        for (h, page) in zip(headings, pages) {
            let p = NSMutableParagraphStyle()
            let indent = CGFloat(h.level - 1) * 18
            p.headIndent = indent
            p.firstLineHeadIndent = indent
            p.tabStops = [NSTextTab(textAlignment: .right, location: width - 1)]
            p.paragraphSpacing = h.level == 1 ? 4 : 2
            p.paragraphSpacingBefore = h.level == 1 ? 4 : 0
            p.lineHeightMultiple = 1.15
            var font = Styles.normal.font
            if h.level == 1 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: p, .foregroundColor: NSColor.black, Styles.styleKey: "TOC\(h.level)"]
            if let name = text.attribute(.docBookmark, at: h.range.location, effectiveRange: nil) as? String { attrs[.link] = "#" + name }
            let entry = NSMutableAttributedString(string: "\(h.title)\t\(page)", attributes: attrs)
            entry.addAttribute(.docTabLeader, value: "dot", range: NSRange(location: (h.title as NSString).length, length: 1))
            out.append(entry)
            attrs[.link] = nil
            out.append(NSAttributedString(string: "\n", attributes: attrs))
        }
        return out
    }

    /// Inserts a table of contents at `location` (or replaces the existing one), with page numbers from a full layout.
    /// `edit` performs the changes (through the text view for undo, or directly).
    static func make(_ storage: NSTextStorage, paged: PagedView, at location: Int,
                     edit: (NSRange, NSAttributedString?, [NSRange]) -> Void) {
        let marks = NSMutableAttributedString(attributedString: storage)
        let headings = headings(storage)
        let changed = addBookmarks(marks, headings)
        if !changed.isEmpty { edit(NSRange(location: 0, length: 0), marks, changed) }
        var target = range(in: storage) ?? NSRange(location: location, length: 0)
        // Twice: the table itself moves the headings.
        for _ in 0..<2 {
            paged.layoutAll()
            let hs = Self.headings(storage)
            let pages = hs.map { paged.pageNumber(at: $0.range.location) }
            let width = paged.setup(at: target.location).columnWidth
            let toc = build(storage, hs, pages: pages, width: width)
            if storage.attributedSubstring(from: target).isEqual(to: toc) { break }
            edit(target, toc, [])
            target = NSRange(location: target.location, length: toc.length)
        }
    }
}

extension DocWindowController {
    // MARK: - Table of contents

    @objc func insertTOCAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let at = ns.paragraphRange(for: NSRange(location: min(textView.selectedRange().location, ns.length), length: 0)).location
        guard !TOC.headings(storage).isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("No headings")
            alert.informativeText = L("Use the Title and Heading 1–3 styles for the table of contents.")
            alert.runModal()
            return
        }
        applyTOC(at: at, name: TOC.range(in: storage) == nil ? L("Insert Table of Contents") : L("Update Table of Contents"))
    }

    @objc func updateTOCAction(_ sender: Any?) {
        guard let storage = textView.textStorage, let r = TOC.range(in: storage) else { NSSound.beep(); return }
        applyTOC(at: r.location, name: L("Update Table of Contents"))
    }

    private func applyTOC(at location: Int, name: String) {
        guard let storage = textView.textStorage, let undo = textView.undoManager else { return }
        let selection = textView.selectedRange()
        textView.breakUndoCoalescing()
        undo.beginUndoGrouping()
        TOC.make(storage, paged: paged, at: location) { range, text, attributeRanges in
            if !attributeRanges.isEmpty, let text {
                // Bookmarks on headings.
                guard textView.shouldChangeText(inRanges: attributeRanges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
                storage.beginEditing()
                for r in attributeRanges { storage.addAttribute(.docBookmark, value: text.attribute(.docBookmark, at: r.location, effectiveRange: nil)!, range: r) }
                storage.endEditing()
                textView.didChangeText()
            } else if let text, textView.shouldChangeText(in: range, replacementString: text.string) {
                storage.replaceCharacters(in: range, with: text)
                textView.didChangeText()
            }
        }
        undo.setActionName(name)
        undo.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
    }

    // MARK: - Links

    /// Link at the cursor with its whole range.
    var linkAtCursor: (Any, NSRange)? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let sel = textView.selectedRange()
        for i in [sel.location, sel.location - 1] where i >= 0 && i < storage.length {
            var r = NSRange()
            if let v = storage.attribute(.link, at: i, longestEffectiveRange: &r, in: NSRange(location: 0, length: storage.length)) { return (v, r) }
        }
        return nil
    }

    static let linkColor = NSColor(srgbRed: 0.02, green: 0.39, blue: 0.76, alpha: 1)

    @objc func insertLinkAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        let existing = linkAtCursor
        var range = existing?.1 ?? textView.selectedRange()
        let shown = NSTextField(string: (storage.string as NSString).substring(with: range))
        let url = NSTextField(string: existing.map { ($0.0 as? URL)?.absoluteString ?? ($0.0 as? String) ?? "" } ?? "")
        url.placeholderString = "https://"
        shown.placeholderString = L("Text to display")
        let alert = NSAlert.form(existing == nil ? L("Insert Link") : L("Edit Link"), ok: existing == nil ? L("Insert") : L("Apply"),
                                 rows: [(L("Text:"), shown), (L("Address:"), url)])
        if existing != nil { alert.addButton(withTitle: L("Remove Link")) }
        alert.window.initialFirstResponder = url
        let answer = alert.runModal()
        if answer == .alertThirdButtonReturn { removeLinkAction(nil); return }
        guard answer == .alertFirstButtonReturn else { return }
        var address = url.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if !address.hasPrefix("#"), !address.contains(":") { address = (address.contains("@") ? "mailto:" : "https://") + address }
        let value = linkValue(address)
        let text = shown.stringValue.isEmpty ? address : shown.stringValue
        var attrs = range.length > 0 ? storage.attributes(at: range.location, effectiveRange: nil) : textView.typingAttributes
        attrs[.link] = value
        attrs[.foregroundColor] = Self.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        if text == (storage.string as NSString).substring(with: range), range.length > 0 {
            // Same text: keep its formatting, add the link.
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.addAttributes([.link: value, .foregroundColor: Self.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        } else {
            guard textView.shouldChangeText(in: range, replacementString: text) else { return }
            storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attrs))
            range.length = (text as NSString).length
        }
        textView.didChangeText()
        textView.undoManager?.setActionName(existing == nil ? L("Insert Link") : L("Edit Link"))
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    @objc func removeLinkAction(_ sender: Any?) {
        guard let (_, r) = linkAtCursor, let storage = textView.textStorage, textView.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        storage.removeAttribute(.link, range: r)
        storage.removeAttribute(.underlineStyle, range: r)
        storage.addAttribute(.foregroundColor, value: NSColor.black, range: r)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Remove Link"))
    }

    /// Internal links ("#bookmark", tables of contents) jump to their paragraph; others open in the browser.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let s = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if s.hasPrefix("#"), let storage = textView.textStorage {
            let name = String(s.dropFirst())
            var target: Int?
            storage.enumerateAttribute(.docBookmark, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
                if v as? String == name { target = r.location; stop.pointee = true }
            }
            guard let target else { NSSound.beep(); return true }
            let ns = storage.string as NSString
            let p = ns.paragraphRange(for: NSRange(location: target, length: 0))
            self.textView.setSelectedRange(NSRange(location: p.location, length: 0))
            paged.scrollRangeToVisible(NSRange(location: p.location, length: max(0, p.length - 1)))
            return true
        }
        if let url = (link as? URL) ?? URL(string: s) { NSWorkspace.shared.open(url) }
        return true
    }

    /// Typing next to a footnote, section break, link or comment does not continue it.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        var a = newTypingAttributes
        a[.docNote] = nil
        a[.docSection] = nil
        a[.docTabLeader] = nil
        a[.attachment] = nil
        a[.docRevision] = typingRevision   // typed text is an insertion only while tracking changes
        guard let storage = textView.textStorage else { return a }
        let at = textView.selectedRange().location
        for key in [NSAttributedString.Key.link, .docComment] where a[key] != nil {
            // Kept only strictly inside (the next character has the same value).
            let next = at < storage.length ? storage.attribute(key, at: at, effectiveRange: nil) as AnyObject? : nil
            if next == nil || !(next!.isEqual(a[key])) { a[key] = nil }
        }
        if a[.link] == nil, let c = a[.foregroundColor] as? NSColor, c == Self.linkColor {
            a[.foregroundColor] = NSColor.black
            a[.underlineStyle] = nil
        }
        return a
    }

    /// Clicking a footnote reference opens its text.
    func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        if let n = textView.textStorage?.attribute(.docNote, at: charIndex, effectiveRange: nil) as? DocNote { editNote(n) }
    }

    func textView(_ textView: NSTextView, doubleClickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        if let n = textView.textStorage?.attribute(.docNote, at: charIndex, effectiveRange: nil) as? DocNote { editNote(n) }
    }
}
