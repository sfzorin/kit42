import AppKit
import Kit42

enum HeaderFooter {
    static var font: NSFont { NSFont(name: "Helvetica Neue", size: 9) ?? .systemFont(ofSize: 9) }

    /// Attributes of a new header or footer paragraph: centred and with tab stops at the centre and the right edge.
    static func attributes(width: CGFloat, alignment: NSTextAlignment = .center) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.tabStops = [NSTextTab(textAlignment: .center, location: width / 2), NSTextTab(textAlignment: .right, location: width)]
        return [.font: font, .paragraphStyle: p, .foregroundColor: NSColor(white: 0.25, alpha: 1)]
    }

    /// The plain header/footer/page-number options of older documents as rich text.
    static func legacy(_ s: PageSetup) -> DocHeaderFooter {
        let hf = DocHeaderFooter()
        let attrs = attributes(width: s.textSize.width)
        if !s.header.isEmpty { hf.header = NSAttributedString(string: s.header, attributes: attrs) }
        if !s.footer.isEmpty || s.pageNumbers {
            let f = NSMutableAttributedString(string: s.footer + (s.pageNumbers && !s.footer.isEmpty ? "   " : ""), attributes: attrs)
            if s.pageNumbers { f.append(Fields.reference(DocField(.page), attributes: attrs)) }
            hf.footer = f
        }
        return hf
    }

    /// Plain text of a header or footer and whether it has a page number (formats without rich headers).
    static func plain(_ s: NSAttributedString?) -> (String, Bool) {
        guard let s, s.length > 0 else { return ("", false) }
        var page = false
        s.enumerateAttribute(.docField, in: NSRange(location: 0, length: s.length)) { v, _, _ in if (v as? DocField)?.kind == .page { page = true } }
        let text = Fields.resolve(s, FieldContext(page: 1, pages: 1, info: DocInfo(), storage: nil))
        var str = text.string
        if page { str = str.replacingOccurrences(of: "\\s*1\\s*$", with: "", options: .regularExpression) }
        return (str.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces), page)
    }

    enum Part: Int { case normal, first, even }

    static func part(_ hf: DocHeaderFooter, page: Int, first: Bool) -> Part {
        if hf.differentFirst && first { return .first }
        if hf.differentOddEven && page % 2 == 0 { return .even }
        return .normal
    }

    static func get(_ hf: DocHeaderFooter, _ part: Part, header: Bool) -> NSAttributedString? {
        switch part {
        case .normal: return header ? hf.header : hf.footer
        case .first: return header ? hf.firstHeader : hf.firstFooter
        case .even: return header ? hf.evenHeader : hf.evenFooter
        }
    }

    static func set(_ hf: DocHeaderFooter, _ part: Part, header: Bool, _ text: NSAttributedString?) {
        let t = (text?.length ?? 0) > 0 ? text : nil
        switch (part, header) {
        case (.normal, true): hf.header = t
        case (.normal, false): hf.footer = t
        case (.first, true): hf.firstHeader = t
        case (.first, false): hf.firstFooter = t
        case (.even, true): hf.evenHeader = t
        case (.even, false): hf.evenFooter = t
        }
    }

    /// Where a header (or footer) is drawn on a page.
    static func rect(_ s: PageSetup, header: Bool, height: CGFloat) -> NSRect {
        let x = s.margins.left, w = s.textSize.width
        if header {
            let top = max(10, min(35.4, s.margins.top * 0.45))
            return NSRect(x: x, y: top, width: w, height: max(14, height))
        }
        let bottom = s.size.height - max(10, min(35.4, s.margins.bottom * 0.45))
        return NSRect(x: x, y: bottom - max(14, height), width: w, height: max(14, height))
    }

    static func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(s.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
}

extension PageSetup {
    /// Headers and footers shown on this section's pages.
    var effectiveHeaderFooter: DocHeaderFooter { sectionHF ?? hf ?? HeaderFooter.legacy(self) }
}

// MARK: - Editing on the page

/// A text view over a page's header or footer (double-click there): rich text with fields, its own undo.
final class HeaderEditor: NSObject, NSTextViewDelegate {
    let textView: NSTextView
    let card: PageCard
    let isHeader: Bool
    let part: HeaderFooter.Part
    let undo = UndoManager()
    var onCommit: ((HeaderEditor) -> Void)?
    private var committed = false
    private let storage = NSTextStorage()

    init(card: PageCard, header: Bool, part: HeaderFooter.Part, text: NSAttributedString, fieldValue: @escaping (DocField) -> String) {
        self.card = card
        isHeader = header
        self.part = part
        let lm = DocLayoutManager()
        lm.shadesFields = true
        lm.fieldValue = { f, _ in fieldValue(f) }
        storage.addLayoutManager(lm)
        let width = card.setup.textSize.width
        let container = NSTextContainer(size: NSSize(width: width, height: 10_000))
        container.lineFragmentPadding = 0
        lm.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init()
        storage.setAttributedString(text.length > 0 ? text : NSAttributedString(string: "", attributes: HeaderFooter.attributes(width: width)))
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.96, blue: 1, alpha: 1)
        textView.insertionPointColor = .black
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.typingAttributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil).filter { $0.key != .attachment && $0.key != .docField } : HeaderFooter.attributes(width: width)
        textView.delegate = self
        layout()
        card.addSubview(textView)
    }

    var text: NSAttributedString { NSAttributedString(attributedString: storage) }

    func layout() {
        let h = max(18, HeaderFooter.height(storage, width: card.setup.textSize.width) + 4)
        textView.frame = HeaderFooter.rect(card.setup, header: isHeader, height: h)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) { layout() }

    func textDidEndEditing(_ notification: Notification) { commit() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { commit(); return true }
        return false
    }

    func commit() {
        guard !committed else { return }
        committed = true
        textView.removeFromSuperview()
        onCommit?(self)
    }
}

extension DocWindowController {
    /// Double-click on a page's top or bottom margin.
    func beginHeaderEdit(_ card: PageCard, header: Bool) {
        guard paged.viewMode != .web else { return }
        headerEditor?.commit()
        let hf = card.setup.effectiveHeaderFooter
        let part = HeaderFooter.part(hf, page: card.number, first: card.firstOfSection)
        let text = HeaderFooter.get(hf, part, header: header) ?? NSAttributedString()
        let number = card.number
        let editor = HeaderEditor(card: card, header: header, part: part, text: text) { [weak self] f in
            guard let self else { return "" }
            var c = self.paged.fieldContext(page: number)
            if let tc = card.textViews.first?.textContainer {
                c.pageStart = self.paged.layoutManager.characterRange(forGlyphRange: self.paged.layoutManager.glyphRange(for: tc), actualGlyphRange: nil).location
            }
            return Fields.value(f, at: -1, c)
        }
        editor.onCommit = { [weak self] e in self?.finishHeaderEdit(e) }
        headerEditor = editor
        card.editing = header ? .header : .footer
        window?.makeFirstResponder(editor.textView)
        syncControls()
    }

    private func finishHeaderEdit(_ e: HeaderEditor) {
        if headerEditor === e { headerEditor = nil }
        e.card.editing = nil
        let hf = e.card.setup.effectiveHeaderFooter.duplicate()
        HeaderFooter.set(hf, e.part, header: e.isHeader, e.text)
        setHeaderFooter(hf, forSectionOf: e.card, name: e.isHeader ? L("Edit Header") : L("Edit Footer"))
        if window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(textView) }
        syncControls()
    }

    /// Stores headers and footers for the section of a page (its own ones) or the document.
    func setHeaderFooter(_ hf: DocHeaderFooter, forSectionOf card: PageCard?, wholeDocument: Bool = false, name: String) {
        let start = card.flatMap { c in paged.layoutManager.characterRange(forGlyphRange: paged.layoutManager.glyphRange(for: c.textViews[0].textContainer!), actualGlyphRange: nil).location } ?? textView.selectedRange().location
        let own = !wholeDocument && paged.setup(at: start).sectionHF != nil
        if own, let brk = paged.sections.first(where: { $0.index >= start }) {
            setSectionHeaderFooter(hf, breakAt: brk.index, name: name)
        } else {
            changeDocumentSetup(name) {
                $0.hf = hf
                $0.header = ""
                $0.footer = ""
                $0.pageNumbers = false
            }
        }
        for c in paged.cards { c.needsDisplay = true }
    }

    /// Gives the section that ends at the break `index` its own headers and footers (nil: the document's again).
    func setSectionHeaderFooter(_ hf: DocHeaderFooter?, breakAt index: Int, name: String) {
        guard let storage = textView.textStorage, index < storage.length, let old = storage.attribute(.docSection, at: index, effectiveRange: nil) as? DocSection else { return }
        let new = DocSection(pageSize: old.pageSize, margins: old.margins, columns: old.columns, columnSpacing: old.columnSpacing, headerFooter: hf)
        let r = NSRange(location: index, length: 1)
        guard textView.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.addAttribute(.docSection, value: new, range: r)
        textView.didChangeText()
        textView.undoManager?.setActionName(name)
    }

    @objc func editHeaderAction(_ sender: Any?) { editHeaderOrFooter(header: true) }
    @objc func editFooterAction(_ sender: Any?) { editHeaderOrFooter(header: false) }

    private func editHeaderOrFooter(header: Bool) {
        guard let card = paged.card(at: textView.selectedRange().location) else { return }
        paged.scrollToVisible(card.frame)
        beginHeaderEdit(card, header: header)
    }

    // MARK: Dialog

    @objc func headerFooterAction(_ sender: Any?) {
        let at = textView.selectedRange().location
        let setup = paged.setup(at: at)
        let hf = setup.effectiveHeaderFooter
        let header = NSButton(checkboxWithTitle: L("Header"), target: nil, action: nil)
        let footer = NSButton(checkboxWithTitle: L("Footer"), target: nil, action: nil)
        header.state = hf.header != nil || hf.firstHeader != nil || hf.evenHeader != nil ? .on : .off
        footer.state = hf.footer != nil || hf.firstFooter != nil || hf.evenFooter != nil ? .on : .off
        let headerText = NSTextField(string: HeaderFooter.plain(hf.header).0)
        let footerText = NSTextField(string: HeaderFooter.plain(hf.footer).0)
        headerText.placeholderString = L("Text at the top of every page")
        footerText.placeholderString = L("Text at the bottom of every page")
        let first = NSButton(checkboxWithTitle: L("Different first page"), target: nil, action: nil)
        first.state = hf.differentFirst ? .on : .off
        let evenOdd = NSButton(checkboxWithTitle: L("Different odd and even pages"), target: nil, action: nil)
        evenOdd.state = hf.differentOddEven ? .on : .off
        let numbers = NSPopUpButton(frame: .zero, pullsDown: false)
        numbers.addItems(withTitles: [L("Keep as is"), L("None"), L("Footer, left"), L("Footer, centre"), L("Footer, right"), L("Header, right")])
        let scope = NSPopUpButton(frame: .zero, pullsDown: false)
        scope.addItems(withTitles: [L("Whole document"), L("This section only")])
        scope.selectItem(at: setup.sectionHF != nil ? 1 : 0)
        var rows: [(String, NSView)] = [("", header), (L("Header text:"), headerText), ("", footer), (L("Footer text:"), footerText),
                                        ("", first), ("", evenOdd), (L("Page numbers:"), numbers)]
        if !paged.sections.isEmpty { rows.append((L("Apply to:"), scope)) }
        let alert = NSAlert.form(L("Header and Footer"), info: L("Double-click the top or bottom of a page to edit the header or footer there, with fields and formatting."),
                                 ok: L("Apply"), rows: rows)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var o = HeaderFooterOptions()
        o.header = header.state == .on
        o.footer = footer.state == .on
        o.headerText = headerText.stringValue != HeaderFooter.plain(hf.header).0 ? headerText.stringValue : nil
        o.footerText = footerText.stringValue != HeaderFooter.plain(hf.footer).0 ? footerText.stringValue : nil
        o.differentFirst = first.state == .on
        o.differentOddEven = evenOdd.state == .on
        o.pageNumbers = numbers.indexOfSelectedItem - 1
        o.sectionOnly = !paged.sections.isEmpty && scope.indexOfSelectedItem == 1
        applyHeaderFooterOptions(o)
    }

    struct HeaderFooterOptions {
        var header = true, footer = true
        var headerText: String?, footerText: String?
        var differentFirst = false, differentOddEven = false
        /// -1 keep, 0 none, 1 footer left, 2 footer centre, 3 footer right, 4 header right.
        var pageNumbers = -1
        var sectionOnly = false
    }

    func applyHeaderFooterOptions(_ o: HeaderFooterOptions) {
        let at = textView.selectedRange().location
        let setup = paged.setup(at: at)
        let hf = setup.effectiveHeaderFooter.duplicate()
        let width = setup.textSize.width
        func text(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: HeaderFooter.attributes(width: width)) }
        if let t = o.headerText { hf.header = t.isEmpty ? nil : text(t) }
        if let t = o.footerText {
            let hadPage = hf.footer.map { HeaderFooter.plain($0).1 } ?? false
            let f = NSMutableAttributedString(attributedString: text(t))
            if hadPage, o.pageNumbers < 0 { f.append(text(t.isEmpty ? "" : "   ")); f.append(Fields.reference(DocField(.page), attributes: HeaderFooter.attributes(width: width))) }
            hf.footer = f.length > 0 ? f : nil
        }
        hf.differentFirst = o.differentFirst
        hf.differentOddEven = o.differentOddEven
        if o.differentOddEven, hf.evenHeader == nil, hf.evenFooter == nil { hf.evenHeader = hf.header; hf.evenFooter = hf.footer }
        if o.pageNumbers >= 0 {
            // Page number fields are removed everywhere, then one paragraph is added where asked.
            for part in [HeaderFooter.Part.normal, .first, .even] {
                for h in [true, false] {
                    guard let s = HeaderFooter.get(hf, part, header: h) else { continue }
                    let m = NSMutableAttributedString(attributedString: s)
                    var ranges: [NSRange] = []
                    m.enumerateAttribute(.docField, in: NSRange(location: 0, length: m.length)) { v, r, _ in if (v as? DocField)?.kind == .page { ranges.append(r) } }
                    for r in ranges.reversed() { m.deleteCharacters(in: r) }
                    let empty = m.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    HeaderFooter.set(hf, part, header: h, empty ? nil : m)
                }
            }
            if o.pageNumbers > 0 {
                let alignment: NSTextAlignment = [.left, .center, .right, .right][o.pageNumbers - 1]
                let inHeader = o.pageNumbers == 4
                for part in [HeaderFooter.Part.normal, .first, .even] where part == .normal || (part == .first && hf.differentFirst) || (part == .even && hf.differentOddEven) {
                    let base = NSMutableAttributedString(attributedString: HeaderFooter.get(hf, part, header: inHeader) ?? NSAttributedString())
                    if base.length > 0, !base.string.hasSuffix("\n") { base.append(NSAttributedString(string: "\n", attributes: HeaderFooter.attributes(width: width, alignment: alignment))) }
                    base.append(Fields.reference(DocField(.page), attributes: HeaderFooter.attributes(width: width, alignment: alignment)))
                    HeaderFooter.set(hf, part, header: inHeader, base)
                }
            }
        }
        if !o.header { hf.header = nil; hf.firstHeader = nil; hf.evenHeader = nil }
        if !o.footer { hf.footer = nil; hf.firstFooter = nil; hf.evenFooter = nil }
        if o.sectionOnly, let brk = paged.sections.first(where: { $0.index >= at }) {
            setSectionHeaderFooter(hf, breakAt: brk.index, name: L("Header and Footer"))
        } else if o.sectionOnly {
            // The last section: the document's setup holds it.
            setHeaderFooter(hf, forSectionOf: nil, wholeDocument: true, name: L("Header and Footer"))
        } else {
            doc?.undoManager?.beginUndoGrouping()
            // Sections with their own headers follow the document again.
            for b in paged.sections where b.section.headerFooter != nil { setSectionHeaderFooter(nil, breakAt: b.index, name: L("Header and Footer")) }
            setHeaderFooter(hf, forSectionOf: nil, wholeDocument: true, name: L("Header and Footer"))
            doc?.undoManager?.endUndoGrouping()
        }
        for c in paged.cards { c.needsDisplay = true }
    }

    @objc func togglePageNumbersAction(_ sender: Any?) {
        let hf = currentSetup.effectiveHeaderFooter
        var has = false
        for part in [hf.header, hf.footer, hf.firstHeader, hf.firstFooter, hf.evenHeader, hf.evenFooter] {
            part?.enumerateAttribute(.docField, in: NSRange(location: 0, length: part?.length ?? 0)) { v, _, _ in if (v as? DocField)?.kind == .page { has = true } }
        }
        var o = HeaderFooterOptions()
        o.header = hf.header != nil || !has
        o.footer = true
        o.header = hf.header != nil
        o.differentFirst = hf.differentFirst
        o.differentOddEven = hf.differentOddEven
        o.pageNumbers = has ? 0 : 2
        applyHeaderFooterOptions(o)
    }

    var hasPageNumbers: Bool {
        let hf = currentSetup.effectiveHeaderFooter
        var has = false
        for part in [hf.header, hf.footer] {
            part?.enumerateAttribute(.docField, in: NSRange(location: 0, length: part?.length ?? 0)) { v, _, _ in if (v as? DocField)?.kind == .page { has = true } }
        }
        return has
    }
}

// MARK: - .docx headers and footers

extension DocxStyles {
    /// A header or footer part read like a document of its own (styles, fields, pictures); its watermark text.
    static func readPart(_ zip: ZipArchive, target: String) -> (NSAttributedString, String?)? {
        guard let d = zip["word/" + target], let xml = try? XMLDocument(data: d, options: [.nodePreserveWhitespace]), let root = xml.rootElement() else { return nil }
        var watermark: String?
        for t in descendants(root, named: "textpath") {
            if let s = t.attr("string"), !s.isEmpty { watermark = s }
        }
        for pict in descendants(root, named: "pict") where !descendants(pict, named: "textpath").isEmpty { (pict.parent as? XMLElement)?.localName == "r" ? pict.parent?.detach() : pict.detach() }
        let namespaces = (root.namespaces ?? []).compactMap { n -> String? in
            guard let name = n.name, let uri = n.stringValue else { return nil }
            return name.isEmpty ? "xmlns=\"\(uri)\"" : "xmlns:\(name)=\"\(uri)\""
        }.joined(separator: " ")
        let inner = (root.children ?? []).map { $0.xmlString }.joined()
        var z = zip
        z["word/document.xml"] = Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document \(namespaces)><w:body>\(inner)</w:body></w:document>".utf8)
        let relsPath = "word/_rels/" + (target as NSString).lastPathComponent + ".rels"
        z["word/_rels/document.xml.rels"] = zip[relsPath] ?? Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"></Relationships>".utf8)
        guard let (text, _) = try? read(z.data(), isPart: true) else { return nil }
        // A trailing empty paragraph mark is not content.
        while text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return (text, watermark)
    }

    /// Headers and footers of every section (Word: a section without a reference inherits the previous one's).
    static func readHeaders(_ body: XMLElement, zip: ZipArchive, rels: [String: String], extras: inout Extras) {
        var sects: [XMLElement] = descendants(body, named: "p").compactMap { $0.child("pPr")?.child("sectPr") }
        if let last = body.child("sectPr") { sects.append(last) }
        guard !sects.isEmpty else { return }
        var evenOdd = false
        if let settings = zip["word/settings.xml"], let root = (try? XMLDocument(data: settings))?.rootElement(), let e = root.child("evenAndOddHeaders") { evenOdd = onOff(e) }
        var cache: [String: NSAttributedString?] = [:]
        var current: [String: String] = [:]   // "header-default" → target
        var resolved: [(refs: [String: String], titlePg: Bool)] = []
        for s in sects {
            for kind in ["header", "footer"] {
                for ref in s.children(kind + "Reference") {
                    if let id = ref.attr("id"), let target = rels[id] { current["\(kind)-\(ref.attr("type") ?? "default")"] = target }
                }
            }
            let titlePg = s.child("titlePg").map(onOff) ?? false
            resolved.append((current, titlePg))
        }
        func load(_ target: String?) -> NSAttributedString? {
            guard let target else { return nil }
            if let c = cache[target] { return c }
            let r = readPart(zip, target: target)
            if let w = r?.1 { extras.watermark = w }
            let t = r.map(\.0).flatMap { $0.length > 0 ? $0 : nil }
            cache[target] = t
            return t
        }
        func hf(_ r: (refs: [String: String], titlePg: Bool)) -> DocHeaderFooter {
            let h = DocHeaderFooter()
            h.header = load(r.refs["header-default"])
            h.footer = load(r.refs["footer-default"])
            h.differentFirst = r.titlePg
            h.firstHeader = r.titlePg ? load(r.refs["header-first"]) : nil
            h.firstFooter = r.titlePg ? load(r.refs["footer-first"]) : nil
            h.differentOddEven = evenOdd
            h.evenHeader = evenOdd ? load(r.refs["header-even"]) : nil
            h.evenFooter = evenOdd ? load(r.refs["footer-even"]) : nil
            return h
        }
        let last = resolved.last!
        extras.setup.hf = hf(last)
        extras.setup.header = ""
        extras.setup.footer = ""
        extras.setup.pageNumbers = false
        for (k, r) in resolved.dropLast().enumerated() where r.refs != last.refs || r.titlePg != last.titlePg {
            extras.sections[k + 1]?.sectionHF = hf(r)
        }
    }
}
