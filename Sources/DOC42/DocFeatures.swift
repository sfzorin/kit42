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
        doc.undoManager?.registerUndo(withTarget: self) { $0.changeDocumentSetup(name) { $0 = old } }
        doc.undoManager?.setActionName(name)
    }

    /// Section break that ends the section of the cursor (nil in the last section).
    var pageSetupLocation: Int {
        if let header = headerEditor, let container = header.card.textViews.first?.textContainer {
            return paged.layoutManager.characterRange(forGlyphRange: paged.layoutManager.glyphRange(for: container), actualGlyphRange: nil).location
        }
        return textView.selectedRange().location
    }

    var sectionBreakAtCursor: (index: Int, section: DocSection)? {
        let at = pageSetupLocation
        return paged.sections.first { $0.index >= at }
    }

    /// Setup of the cursor's section.
    var currentSetup: PageSetup { paged.setup.with(sectionBreakAtCursor?.section) }

    /// Changes the page setup of the cursor's section (or of every section), undoably.
    @discardableResult
    func changeSetup(_ name: String, wholeDocument: Bool = false, at location: Int? = nil, _ body: (inout PageSetup) -> Void) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let section = paged.sections.first { $0.index >= (location ?? pageSetupLocation) }
        let breaks = wholeDocument ? paged.sections : section.map { [$0] } ?? []
        var changes: [(NSRange, DocSection)] = []
        for b in breaks {
            var s = paged.setup.with(b.section)
            let old = s
            body(&s)
            guard s.hasValidGeometry else { return false }
            if !s.sameGeometry(old) { changes.append((NSRange(location: b.index, length: 1), s.section)) }
        }
        if wholeDocument || section == nil {
            var candidate = doc?.setup ?? paged.setup
            body(&candidate)
            guard candidate.hasValidGeometry else { return false }
        }
        let undo = doc?.undoManager
        undo?.beginUndoGrouping()
        if !changes.isEmpty, textView.shouldChangeText(inRanges: changes.map { NSValue(range: $0.0) }, replacementStrings: nil) {
            storage.beginEditing()
            for (r, sec) in changes { storage.addAttribute(.docSection, value: sec, range: r) }
            storage.endEditing()
            textView.didChangeText()
        }
        if wholeDocument || section == nil { changeDocumentSetup(name, body) }
        undo?.setActionName(name)
        undo?.endUndoGrouping()
        syncRulerSetup()
        return true
    }

    static let papers: [(String, NSSize)] = [("A4", NSSize(width: 595, height: 842)), ("A5", NSSize(width: 420, height: 595)),
                                             ("Letter", NSSize(width: 612, height: 792)), ("Legal", NSSize(width: 612, height: 1008))]

    static func pageMeasurementText(_ points: CGFloat) -> String { String(format: "%.1f", points / DocRuler.cm) }

    static func pageMeasurement(_ text: String, original: CGFloat) -> CGFloat? {
        // Display rounding must not modify exact imported measurements on an unchanged Apply.
        if text == pageMeasurementText(original) { return original.isFinite && original >= 0 ? original : nil }
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else { return nil }
        let points = CGFloat(value) * DocRuler.cm
        return points.isFinite ? points : nil
    }

    @objc func documentSetupAction(_ sender: Any?) {
        let s = currentSetup
        let paper = NSPopUpButton(frame: .zero, pullsDown: false)
        paper.addItems(withTitles: Self.papers.map(\.0))
        let portraitSize = NSSize(width: min(s.size.width, s.size.height), height: max(s.size.width, s.size.height))
        let standard = Self.papers.firstIndex { abs($0.1.width - portraitSize.width) < 2 && abs($0.1.height - portraitSize.height) < 2 }
        if let standard { paper.selectItem(at: standard) }
        else { paper.addItem(withTitle: L("Custom")); paper.selectItem(at: Self.papers.count) }
        let orientation = NSPopUpButton(frame: .zero, pullsDown: false)
        orientation.addItems(withTitles: [L("Portrait"), L("Landscape")])
        orientation.selectItem(at: s.size.width > s.size.height ? 1 : 0)
        func cm(_ v: CGFloat) -> NSTextField { NSTextField(string: Self.pageMeasurementText(v)) }
        let top = cm(s.margins.top), bottom = cm(s.margins.bottom), left = cm(s.margins.left), right = cm(s.margins.right)
        let columns = NSPopUpButton(frame: .zero, pullsDown: false)
        columns.addItems(withTitles: (1...max(3, min(64, s.columns))).map(String.init))
        columns.selectItem(at: max(0, min(columns.numberOfItems - 1, s.columns - 1)))
        let spacing = cm(s.columnSpacing)
        let scope = NSPopUpButton(frame: .zero, pullsDown: false)
        scope.addItems(withTitles: [L("This section"), L("Whole document")])
        var rows: [(String, NSView)] = [(L("Paper:"), paper), (L("Orientation:"), orientation), (L("Top:"), top), (L("Bottom:"), bottom),
                                        (L("Left:"), left), (L("Right:"), right), (L("Columns:"), columns), (L("Column spacing:"), spacing)]
        if !paged.sections.isEmpty { rows.append((L("Apply to:"), scope)) }
        let alert = NSAlert.form(L("Document Setup"), info: L("Margins in centimetres."), ok: L("Apply"), rows: rows)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func pt(_ f: NSTextField, _ original: CGFloat) -> CGFloat? {
            Self.pageMeasurement(f.stringValue, original: original)
        }
        guard let mt = pt(top, s.margins.top), let mb = pt(bottom, s.margins.bottom), let ml = pt(left, s.margins.left),
              let mr = pt(right, s.margins.right), let gap = pt(spacing, s.columnSpacing) else {
            showInvalidPageSetup(); return
        }
        var size = paper.indexOfSelectedItem < Self.papers.count ? Self.papers[max(0, paper.indexOfSelectedItem)].1 : portraitSize
        if orientation.indexOfSelectedItem == 1 { size = NSSize(width: size.height, height: size.width) }
        let margins = NSEdgeInsets(top: mt, left: ml, bottom: mb, right: mr)
        let n = max(1, columns.indexOfSelectedItem + 1)
        let applied = changeSetup(L("Document Setup"), wholeDocument: !paged.sections.isEmpty && scope.indexOfSelectedItem == 1) {
            $0.size = size
            $0.margins = margins
            $0.columns = n
            $0.columnSpacing = gap
        }
        if !applied { showInvalidPageSetup() }
    }

    private func showInvalidPageSetup() {
        let alert = NSAlert()
        alert.messageText = L("Invalid page setup")
        alert.informativeText = L("Use non-negative finite measurements and leave at least 36 points of height and width for each text column.")
        alert.runModal()
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

    func setMargins(left: CGFloat, right: CGFloat, at location: Int? = nil) {
        changeSetup(L("Margins"), at: location) {
            $0.margins.left = left
            $0.margins.right = right
        }
    }

    func setVerticalMargins(top: CGFloat, bottom: CGFloat, at location: Int) {
        changeSetup(L("Margins"), at: location) {
            $0.margins.top = top
            $0.margins.bottom = bottom
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
        let textView = activeTextView
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
