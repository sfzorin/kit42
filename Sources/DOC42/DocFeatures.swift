import AppKit
import Kit42

extension DocWindowController {
    // MARK: - Page setup, header & footer

    /// Changes the setup of the document (the last section, and header/footer of all pages), undoably.
    func changeDocumentSetup(_ name: String, _ body: (inout PageSetup) -> Void) {
        guard let doc else { return }
        let old = doc.setup
        var new = old
        body(&new)
        guard new != old else { return }
        doc.setup = new
        doc.undoManager?.registerUndo(withTarget: doc) { d in
            let current = d.setup
            d.setup = old
            d.undoManager?.registerUndo(withTarget: d) { $0.setup = current }
        }
        doc.undoManager?.setActionName(name)
    }

    /// Section break that ends the section of the cursor (nil in the last section).
    var sectionBreakAtCursor: (index: Int, section: DocSection)? {
        let at = textView.selectedRange().location
        return paged.sections.first { $0.index >= at }
    }

    /// Setup of the cursor's section.
    var currentSetup: PageSetup { paged.setup(at: textView.selectedRange().location) }

    /// Changes the page setup of the cursor's section (or of every section), undoably.
    func changeSetup(_ name: String, wholeDocument: Bool = false, _ body: (inout PageSetup) -> Void) {
        guard let storage = textView.textStorage else { return }
        let breaks = wholeDocument ? paged.sections : sectionBreakAtCursor.map { [$0] } ?? []
        var changes: [(NSRange, DocSection)] = []
        for b in breaks {
            var s = paged.setup.with(b.section)
            let old = s
            body(&s)
            if !s.sameGeometry(old) { changes.append((NSRange(location: b.index, length: 1), s.section)) }
        }
        let undo = doc?.undoManager
        undo?.beginUndoGrouping()
        if !changes.isEmpty, textView.shouldChangeText(inRanges: changes.map { NSValue(range: $0.0) }, replacementStrings: nil) {
            storage.beginEditing()
            for (r, sec) in changes { storage.addAttribute(.docSection, value: sec, range: r) }
            storage.endEditing()
            textView.didChangeText()
        }
        if wholeDocument || sectionBreakAtCursor == nil { changeDocumentSetup(name, body) }
        undo?.setActionName(name)
        undo?.endUndoGrouping()
        syncRulerSetup()
    }

    static let papers: [(String, NSSize)] = [("A4", NSSize(width: 595, height: 842)), ("A5", NSSize(width: 420, height: 595)),
                                             ("Letter", NSSize(width: 612, height: 792)), ("Legal", NSSize(width: 612, height: 1008))]

    @objc func documentSetupAction(_ sender: Any?) {
        let s = currentSetup
        let paper = NSPopUpButton(frame: .zero, pullsDown: false)
        paper.addItems(withTitles: Self.papers.map(\.0))
        let portraitSize = NSSize(width: min(s.size.width, s.size.height), height: max(s.size.width, s.size.height))
        paper.selectItem(at: Self.papers.firstIndex { abs($0.1.width - portraitSize.width) < 2 && abs($0.1.height - portraitSize.height) < 2 } ?? 0)
        let orientation = NSPopUpButton(frame: .zero, pullsDown: false)
        orientation.addItems(withTitles: [L("Portrait"), L("Landscape")])
        orientation.selectItem(at: s.size.width > s.size.height ? 1 : 0)
        func cm(_ v: CGFloat) -> NSTextField { NSTextField(string: String(format: "%.1f", v / 28.3465)) }
        let top = cm(s.margins.top), bottom = cm(s.margins.bottom), left = cm(s.margins.left), right = cm(s.margins.right)
        let columns = NSPopUpButton(frame: .zero, pullsDown: false)
        columns.addItems(withTitles: ["1", "2", "3"])
        columns.selectItem(at: min(2, s.columns - 1))
        let spacing = cm(s.columnSpacing)
        let scope = NSPopUpButton(frame: .zero, pullsDown: false)
        scope.addItems(withTitles: [L("This section"), L("Whole document")])
        var rows: [(String, NSView)] = [(L("Paper:"), paper), (L("Orientation:"), orientation), (L("Top:"), top), (L("Bottom:"), bottom),
                                        (L("Left:"), left), (L("Right:"), right), (L("Columns:"), columns), (L("Column spacing:"), spacing)]
        if !paged.sections.isEmpty { rows.append((L("Apply to:"), scope)) }
        let alert = NSAlert.form(L("Document Setup"), info: L("Margins in centimetres."), ok: L("Apply"), rows: rows)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func pt(_ f: NSTextField, _ d: CGFloat) -> CGFloat {
            Double(f.stringValue.replacingOccurrences(of: ",", with: ".")).map { max(0, CGFloat($0) * 28.3465) } ?? d
        }
        var size = Self.papers[max(0, paper.indexOfSelectedItem)].1
        if orientation.indexOfSelectedItem == 1 { size = NSSize(width: size.height, height: size.width) }
        let margins = NSEdgeInsets(top: pt(top, s.margins.top), left: pt(left, s.margins.left), bottom: pt(bottom, s.margins.bottom), right: pt(right, s.margins.right))
        let n = max(1, columns.indexOfSelectedItem + 1), gap = pt(spacing, s.columnSpacing)
        changeSetup(L("Document Setup"), wholeDocument: !paged.sections.isEmpty && scope.indexOfSelectedItem == 1) {
            $0.size = size
            $0.margins = margins
            $0.columns = n
            $0.columnSpacing = gap
        }
    }

    // MARK: - Margins & orientation

    /// Presets as in Word and Writer, plus the Russian GOST layout (top, left, bottom, right in cm).
    static let marginPresets: [(name: String, cm: (CGFloat, CGFloat, CGFloat, CGFloat))] = [
        (L("Normal"), (2, 2, 2, 2)),
        (L("Word Normal"), (2.54, 2.54, 2.54, 2.54)),
        (L("Narrow"), (1.27, 1.27, 1.27, 1.27)),
        (L("Moderate"), (2.54, 1.91, 2.54, 1.91)),
        (L("Wide"), (2.54, 5.08, 2.54, 5.08)),
        (L("GOST (left 3, right 1.5 cm)"), (2, 3, 2, 1.5)),
    ]

    @objc func marginPresetAction(_ sender: Any?) {
        let i = commandTag(of: sender)
        guard Self.marginPresets.indices.contains(i) else { return }
        let c = Self.marginPresets[i].cm, k = DocRuler.cm
        changeSetup(L("Margins")) { $0.margins = NSEdgeInsets(top: c.0 * k, left: c.1 * k, bottom: c.2 * k, right: c.3 * k) }
    }

    func currentMarginPreset() -> Int? {
        let m = currentSetup.margins
        let k = DocRuler.cm
        return Self.marginPresets.firstIndex { p in
            abs(p.cm.0 * k - m.top) < 1 && abs(p.cm.1 * k - m.left) < 1 && abs(p.cm.2 * k - m.bottom) < 1 && abs(p.cm.3 * k - m.right) < 1
        }
    }

    func setMargins(left: CGFloat, right: CGFloat) {
        changeSetup(L("Margins")) {
            $0.margins.left = left
            $0.margins.right = right
        }
    }

    @objc func orientationAction(_ sender: Any?) {
        let landscape = commandTag(of: sender) == 1
        changeSetup(L("Orientation")) {
            let s = $0.size
            let long = max(s.width, s.height), short = min(s.width, s.height)
            $0.size = landscape ? NSSize(width: long, height: short) : NSSize(width: short, height: long)
        }
    }

    var isLandscape: Bool { currentSetup.isLandscape }

    /// Ruler indents → the selected paragraphs (undoable).
    func setIndents(firstLine: CGFloat, head: CGFloat, tail: CGFloat) {
        guard let s = textView.textStorage else { return }
        let ns = s.string as NSString
        let range = s.length == 0 ? NSRange(location: 0, length: 0) : ns.paragraphRange(for: textView.selectedRange())
        guard range.length > 0 else {
            let p = ((textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            p.firstLineHeadIndent = firstLine; p.headIndent = head; p.tailIndent = tail
            textView.typingAttributes[.paragraphStyle] = p
            syncRuler()
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        s.beginEditing()
        s.enumerateAttribute(.paragraphStyle, in: range) { v, r, _ in
            let p = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            p.firstLineHeadIndent = firstLine
            p.headIndent = head
            p.tailIndent = tail
            s.addAttribute(.paragraphStyle, value: p, range: r)
        }
        s.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Indents"))
        syncRuler()
    }


}
