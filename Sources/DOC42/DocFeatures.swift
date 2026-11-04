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

    @objc func headerFooterAction(_ sender: Any?) {
        guard let doc else { return }
        let header = NSTextField(string: doc.setup.header)
        let footer = NSTextField(string: doc.setup.footer)
        header.placeholderString = L("Text at the top of every page")
        footer.placeholderString = L("Text at the bottom of every page")
        let numbers = NSButton(checkboxWithTitle: L("Page numbers"), target: nil, action: nil)
        numbers.state = doc.setup.pageNumbers ? .on : .off
        let alert = NSAlert.form(L("Header and Footer"), ok: L("Apply"), rows: [(L("Header:"), header), (L("Footer:"), footer), ("", numbers)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeDocumentSetup(L("Header and Footer")) {
            $0.header = header.stringValue
            $0.footer = footer.stringValue
            $0.pageNumbers = numbers.state == .on
        }
    }

    @objc func togglePageNumbersAction(_ sender: Any?) {
        changeDocumentSetup(L("Page Numbers")) { $0.pageNumbers.toggle() }
    }

    // MARK: - Tables

    private struct TableAtCursor {
        let table: NSTextTable
        let range: NSRange
        var cells: [[NSAttributedString]]   // row → column → content (paragraphs with newlines)
        var template: NSTextTableBlock
        let row: Int
        let col: Int
    }

    private func block(at location: Int) -> NSTextTableBlock? {
        guard let s = textView.textStorage, s.length > 0 else { return nil }
        let p = s.attribute(.paragraphStyle, at: min(max(0, location), s.length - 1), effectiveRange: nil) as? NSParagraphStyle
        return p?.textBlocks.last as? NSTextTableBlock
    }

    private func tableAtCursor() -> TableAtCursor? {
        guard let s = textView.textStorage else { return nil }
        let ns = s.string as NSString
        let loc = min(textView.selectedRange().location, max(0, s.length - 1))
        guard let current = block(at: loc) else { return nil }
        let table = current.table
        var start = ns.paragraphRange(for: NSRange(location: loc, length: 0)).location
        while start > 0, block(at: start - 1)?.table === table {
            start = ns.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        var end = NSMaxRange(ns.paragraphRange(for: NSRange(location: loc, length: 0)))
        while end < s.length, block(at: end)?.table === table {
            end = NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0)))
        }
        let range = NSRange(location: start, length: end - start)
        var cells: [[NSMutableAttributedString]] = []
        var paragraphStart = start
        while paragraphStart < end {
            let pr = ns.paragraphRange(for: NSRange(location: paragraphStart, length: 0))
            if let b = block(at: pr.location) {
                while cells.count <= b.startingRow { cells.append([]) }
                while cells[b.startingRow].count < table.numberOfColumns { cells[b.startingRow].append(NSMutableAttributedString()) }
                if b.startingColumn < cells[b.startingRow].count { cells[b.startingRow][b.startingColumn].append(s.attributedSubstring(from: pr)) }
            }
            paragraphStart = NSMaxRange(pr)
        }
        return TableAtCursor(table: table, range: range, cells: cells, template: current, row: current.startingRow, col: current.startingColumn)
    }

    private func emptyCell(like t: TableAtCursor) -> NSAttributedString {
        let font = (textView.typingAttributes[.font] as? NSFont) ?? Styles.normal.font
        return NSAttributedString(string: "\n", attributes: [.font: font])
    }

    private func rebuild(_ t: TableAtCursor, cells: [[NSAttributedString]], caret: (Int, Int)) {
        guard let s = textView.textStorage else { return }
        guard !cells.isEmpty, let cols = cells.map(\.count).max(), cols > 0 else {
            replace(t.range, with: NSAttributedString(string: ""))
            return
        }
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.collapsesBorders = t.table.collapsesBorders
        table.layoutAlgorithm = t.table.layoutAlgorithm
        let out = NSMutableAttributedString()
        var caretLocation = t.range.location
        for (r, row) in cells.enumerated() {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(t.template.width(for: .border, edge: .minX), type: .absoluteValueType, for: .border)
                block.setBorderColor(t.template.borderColor(for: .minX) ?? NSColor(white: 0.6, alpha: 1))
                block.setWidth(max(4, t.template.width(for: .padding, edge: .minX)), type: .absoluteValueType, for: .padding)
                block.setValue(100 / CGFloat(cols), type: .percentageValueType, for: .width)
                let content = NSMutableAttributedString(attributedString: c < row.count ? row[c] : emptyCell(like: t))
                if content.length == 0 || !content.string.hasSuffix("\n") { content.append(emptyCell(like: t)) }
                content.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: content.length)) { v, range, _ in
                    let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    p.textBlocks = [block]
                    content.addAttribute(.paragraphStyle, value: p, range: range)
                }
                if (r, c) == caret { caretLocation = t.range.location + out.length }
                out.append(content)
            }
        }
        replace(t.range, with: out)
        textView.setSelectedRange(NSRange(location: min(caretLocation, s.length), length: 0))
    }

    private func replace(_ range: NSRange, with text: NSAttributedString) {
        guard textView.shouldChangeText(in: range, replacementString: text.string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }

    @objc func tableRowAction(_ sender: Any?) {
        guard let t = tableAtCursor() else { NSSound.beep(); return }
        var cells = t.cells
        let cols = t.table.numberOfColumns
        let empty = Array(repeating: emptyCell(like: t), count: cols)
        switch commandTag(of: sender) {
        case 0: cells.insert(empty, at: t.row); rebuild(t, cells: cells, caret: (t.row, t.col))            // above
        case 1: cells.insert(empty, at: t.row + 1); rebuild(t, cells: cells, caret: (t.row + 1, t.col))    // below
        default: cells.remove(at: t.row); rebuild(t, cells: cells, caret: (max(0, t.row - 1), t.col))       // delete
        }
    }

    @objc func tableColumnAction(_ sender: Any?) {
        guard let t = tableAtCursor() else { NSSound.beep(); return }
        var cells = t.cells
        switch commandTag(of: sender) {
        case 0: for r in cells.indices { cells[r].insert(emptyCell(like: t), at: min(t.col, cells[r].count)) }; rebuild(t, cells: cells, caret: (t.row, t.col))
        case 1: for r in cells.indices { cells[r].insert(emptyCell(like: t), at: min(t.col + 1, cells[r].count)) }; rebuild(t, cells: cells, caret: (t.row, t.col + 1))
        default:
            for r in cells.indices where t.col < cells[r].count { cells[r].remove(at: t.col) }
            if cells.allSatisfy(\.isEmpty) { cells = [] }
            rebuild(t, cells: cells, caret: (t.row, max(0, t.col - 1)))
        }
    }

    @objc func deleteTableAction(_ sender: Any?) {
        guard let t = tableAtCursor() else { NSSound.beep(); return }
        replace(t.range, with: NSAttributedString(string: ""))
    }

    var isInTable: Bool { block(at: textView.selectedRange().location) != nil }
}
