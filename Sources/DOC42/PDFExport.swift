import AppKit
import Kit42

/// PDF export options (Writer's PDF Options dialog, the essentials).
struct PDFOptions {
    /// Pages to export ("1-3, 5"), empty: all.
    var pages = ""
    /// Picture quality 0…1 (1: pictures as they are).
    var quality: CGFloat = 1
    var bookmarks = true
    var comments = false

    /// Page indices (from 0) to keep, nil: all.
    func pageSet(count: Int) -> Set<Int>? {
        let spec = pages.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return nil }
        var out = Set<Int>()
        for part in spec.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1, let a = bounds[0] { out.insert(a - 1) } else if bounds.count == 2 {
                let a = bounds[0] ?? 1, b = bounds[1] ?? count
                if a <= b { for k in a...b { out.insert(k - 1) } }
            }
        }
        let valid = out.filter { $0 >= 0 && $0 < count }
        return valid.isEmpty ? nil : valid
    }
}

extension TextDocument {
    /// Paginated PDF like Writer's export: headings as bookmarks, clickable links (web and inside the document),
    /// comments as notes, title and author in the PDF's properties, a page range and picture quality.
    func pdfData(_ o: PDFOptions) -> Data {
        let view = offscreenPages(accepted: true)
        defer { view.detach() }
        ImageCell.exportQuality = o.quality
        defer { ImageCell.exportQuality = 1; ImageCell.clearReduced() }
        let raw = view.hasMixedPageSizes ? view.pdfData() : PaginatedPDF.render(view, info: pageInfo())
        guard let storage = view.layoutManager.textStorage else { return raw }
        let ns = storage.string as NSString
        let lm = view.layoutManager

        /// Rectangles of a character range by page (from the page's top-left).
        func rects(_ range: NSRange) -> [(page: Int, rect: CGRect)] {
            var out: [(Int, CGRect)] = []
            for (pi, card) in view.cards.enumerated() {
                for tv in card.textViews {
                    guard let c = tv.textContainer else { continue }
                    let g = lm.glyphRange(for: c)
                    let mine = NSIntersectionRange(g, lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
                    guard mine.length > 0 else { continue }
                    lm.enumerateEnclosingRects(forGlyphRange: mine, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: c) { r, _ in
                        out.append((pi, r.offsetBy(dx: tv.frame.minX, dy: tv.frame.minY)))
                    }
                }
            }
            return out
        }
        func place(_ index: Int) -> (page: Int, y: CGFloat)? { rects(NSRange(location: index, length: 1)).first.map { ($0.page, $0.rect.minY) } }

        var outline: [PaginatedPDF.OutlineItem] = []
        if o.bookmarks {
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
                guard r.length > 0, let id = storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String, !TOC.isTOCStyle(id) else { return }
                let level: Int
                if id == "Title" { level = 0 } else if let l = self.styles.resolved(id).outlineLevel { level = l + 1 } else { return }
                let title = ns.substring(with: r).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty, let p = place(r.location) else { return }
                outline.append(PaginatedPDF.OutlineItem(title: title, level: level, page: p.page, y: p.y))
            }
        }
        var bookmarks: [String: Int] = [:]
        storage.enumerateAttribute(.docBookmark, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if let s = v as? String, bookmarks[s] == nil { bookmarks[s] = r.location }
        }
        var links: [PaginatedPDF.Link] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let v else { return }
            let s = (v as? URL)?.absoluteString ?? (v as? String) ?? ""
            var target: (page: Int, y: CGFloat)?
            var url: URL?
            if s.hasPrefix("#") {
                guard let at = bookmarks[String(s.dropFirst())], let p = place(at) else { return }
                target = p
            } else { url = (v as? URL) ?? URL(string: s) }
            for (page, rect) in rects(r) { links.append(PaginatedPDF.Link(page: page, rect: rect, url: url, target: target)) }
        }
        var notes: [PaginatedPDF.Note] = []
        if o.comments {
            for (r, c) in CLI.commentsOf(storage) {
                guard let first = rects(r).first else { continue }
                notes.append(PaginatedPDF.Note(page: first.page, rect: first.rect, text: c.text, author: c.author))
            }
        }
        return PaginatedPDF.finish(raw, title: docInfo.title, author: docInfo.author, creator: "DOC42", outline: outline, links: links, notes: notes,
                                   pages: o.pageSet(count: view.cards.count))
    }
}

extension DocWindowController {
    static var lastPDFOptions = PDFOptions()

    /// File › Export as PDF…: options first, then where to save.
    @objc func exportPDFAction(_ sender: Any?) {
        guard let doc, let window else { return }
        var o = Self.lastPDFOptions
        let range = NSPopUpButton(frame: .zero, pullsDown: false)
        range.addItems(withTitles: [L("All pages"), L("Pages:")])
        let pages = NSTextField(string: o.pages)
        pages.placeholderString = L("For example: 1-3, 5")
        range.selectItem(at: o.pages.isEmpty ? 0 : 1)
        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        let qualities: [CGFloat] = [1, 0.9, 0.75, 0.5, 0.3]
        quality.addItems(withTitles: [L("Original pictures"), "90%", "75%", "50%", "30%"])
        quality.selectItem(at: qualities.firstIndex(of: o.quality) ?? 0)
        let bookmarks = NSButton(checkboxWithTitle: L("Export headings as bookmarks"), target: nil, action: nil)
        bookmarks.state = o.bookmarks ? .on : .off
        let comments = NSButton(checkboxWithTitle: L("Export comments as notes"), target: nil, action: nil)
        comments.state = o.comments ? .on : .off
        let alert = NSAlert.form(L("PDF Options"), info: L("Links and the table of contents stay clickable; title and author go into the PDF's properties."),
                                 ok: L("Export…"), rows: [(L("Range:"), range), ("", pages), (L("Image quality:"), quality), ("", bookmarks), ("", comments)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        o.pages = range.indexOfSelectedItem == 1 ? pages.stringValue : ""
        o.quality = qualities[max(0, quality.indexOfSelectedItem)]
        o.bookmarks = bookmarks.state == .on
        o.comments = comments.state == .on
        Self.lastPDFOptions = o
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.fileURL?.deletingPathExtension().lastPathComponent ?? doc.displayName ?? L("Document")) + ".pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try doc.pdfData(o).write(to: url) } catch { NSApp.presentError(error) }
        }
    }

    // MARK: - Document properties, bookmarks, cross-references

    @objc func documentPropertiesAction(_ sender: Any?) {
        guard let doc else { return }
        let title = NSTextField(string: doc.docInfo.title), author = NSTextField(string: doc.docInfo.author)
        author.placeholderString = NSFullUserName()
        let alert = NSAlert.form(L("Document Properties"), info: L("Used by the Title and Author fields, and in exported PDF files."), ok: L("OK"),
                                 rows: [(L("Title:"), title), (L("Author:"), author)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setDocInfo(DocInfo(title: title.stringValue, author: author.stringValue))
    }

    func setDocInfo(_ info: DocInfo) {
        guard let doc, doc.docInfo != info else { return }
        let old = doc.docInfo
        doc.docInfo = info
        doc.undoManager?.registerUndo(withTarget: self) { $0.setDocInfo(old) }
        doc.undoManager?.setActionName(L("Document Properties"))
        paged.refreshFields(force: true)
        paged.cards.forEach { $0.needsDisplay = true }
    }

    @objc func insertBookmarkAction(_ sender: Any?) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let name = NSTextField(string: "")
        name.placeholderString = L("Bookmark name")
        let alert = NSAlert.form(L("Insert Bookmark"), info: L("A bookmark marks the paragraph as a link target (#name)."), ok: L("Insert"), rows: [(L("Name:"), name)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addBookmark(name.stringValue)
    }

    func addBookmark(_ raw: String) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let name = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty else { NSSound.beep(); return }
        let p = (storage.string as NSString).paragraphRange(for: NSRange(location: min(textView.selectedRange().location, storage.length - 1), length: 0))
        guard textView.shouldChangeText(in: p, replacementString: nil) else { return }
        storage.addAttribute(.docBookmark, value: name, range: p)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Insert Bookmark"))
        sidebar.navigator.scheduleReload()
    }

    /// A link to a heading or bookmark, showing its text (or its page number).
    @objc func insertCrossReferenceAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        var targets: [(String, String)] = []   // (shown, bookmark)
        let ns = storage.string as NSString
        storage.enumerateAttribute(.docBookmark, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let name = v as? String else { return }
            let text = ns.substring(with: r).replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            targets.append((text.isEmpty ? name : text, name))
        }
        let headings = TOC.headings(storage).filter { storage.attribute(.docBookmark, at: $0.range.location, effectiveRange: nil) == nil }
        let target = NSPopUpButton(frame: .zero, pullsDown: false)
        target.addItems(withTitles: targets.map(\.0) + headings.map(\.title))
        guard target.numberOfItems > 0 else { NSSound.beep(); return }
        let show = NSPopUpButton(frame: .zero, pullsDown: false)
        show.addItems(withTitles: [L("Text"), L("Page number")])
        let alert = NSAlert.form(L("Cross-reference"), ok: L("Insert"), rows: [(L("Refer to:"), target), (L("Show:"), show)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var i = target.indexOfSelectedItem
        var name: String
        var text: String
        if i < targets.count { (text, name) = targets[i] } else {
            i -= targets.count
            name = "_Ref" + String(Int.random(in: 100_000_000...999_999_999))
            text = headings[i].title
            let r = headings[i].range
            if textView.shouldChangeText(in: r, replacementString: nil) { storage.addAttribute(.docBookmark, value: name, range: r); textView.didChangeText() }
        }
        if show.indexOfSelectedItem == 1, let at = storage.enumerateFirst(.docBookmark, equalTo: name) { text = "\(paged.pageNumber(at: at))" }
        var attrs = textView.typingAttributes
        attrs[.link] = "#" + name
        attrs[.foregroundColor] = Self.linkColor
        insert(NSAttributedString(string: text, attributes: attrs))
        textView.undoManager?.setActionName(L("Cross-reference"))
    }
}

extension NSAttributedString {
    func enumerateFirst(_ key: NSAttributedString.Key, equalTo value: String) -> Int? {
        var found: Int?
        enumerateAttribute(key, in: NSRange(location: 0, length: length)) { v, r, stop in
            if v as? String == value { found = r.location; stop.pointee = true }
        }
        return found
    }
}
