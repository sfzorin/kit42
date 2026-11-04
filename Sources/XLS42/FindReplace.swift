import AppKit
import Kit42

/// What and where Find & Replace searches.
struct FindOptions {
    var text = ""
    var replacement = ""
    var workbook = false      // scope: all sheets
    var inFormulas = true     // look in formulas (cell input) or displayed values
    var matchCase = false
    var entireCell = false

    private var compare: String.CompareOptions { matchCase ? [] : [.caseInsensitive] }

    func matches(_ s: String) -> Bool {
        guard !text.isEmpty else { return false }
        return entireCell ? s.compare(text, options: compare) == .orderedSame : s.range(of: text, options: compare) != nil
    }

    func matches(_ cell: Cell) -> Bool { matches(searchedText(cell)) }

    func searchedText(_ cell: Cell) -> String {
        inFormulas ? cell.input : NumberFormat.format(cell.value, cell.style.numberFormat).text
    }

    /// New input of a matching cell; nil when the cell can't be replaced (a formula when looking in values).
    func replaced(_ cell: Cell) -> String? {
        guard matches(cell) else { return nil }
        if !inFormulas && cell.isFormula { return nil }
        if entireCell { return replacement }
        return (inFormulas ? cell.input : searchedText(cell)).replacingOccurrences(of: text, with: replacement, options: compare)
    }
}

extension SheetWindowController {
    /// Edit › Find › Find and Replace… (non-modal panel).
    @objc func findReplaceAction(_ sender: Any?) {
        grid.commitEdit(move: nil)
        if findPanel == nil { findPanel = FindReplacePanel(controller: self) }
        findPanel?.show(relativeTo: window)
    }

    /// Matching cells in search order: current sheet first (from the active cell), then the following sheets.
    func findMatches(_ o: FindOptions) -> [(sheet: Int, ref: CellRef)] {
        guard let doc else { return [] }
        let sheets = o.workbook ? Array(doc.workbook.sheets.indices) : [sheetIndex]
        return sheets.flatMap { si in doc.workbook.sheets[si].cells.filter { o.matches($0.value) }.keys.sorted().map { (si, $0) } }
    }

    /// Selects the next match after the active cell (wrapping). Returns false when nothing matches.
    @discardableResult
    func findNext(_ o: FindOptions) -> Bool {
        let all = findMatches(o)
        guard !all.isEmpty else { NSSound.beep(); return false }
        let here = (sheetIndex, grid.active)
        let next = all.first { $0.sheet > here.0 || ($0.sheet == here.0 && $0.ref > here.1) } ?? all[0]
        if next.sheet != sheetIndex { selectSheet(next.sheet) }
        grid.select(next.ref)
        return true
    }

    /// Replaces the active cell if it matches, then moves to the next match.
    func replaceCurrent(_ o: FindOptions) {
        guard let doc else { return }
        let ref = grid.active
        if let input = o.replaced(sheet[ref]) {
            guard guardEditable(CellRange(ref, ref)) else { return }
            doc.change(L("Replace")) { wb in
                var c = wb.sheets[sheetIndex][ref]
                c.input = input
                c.value = c.isFormula ? .empty : XLSX.constant(input)
                wb.sheets[sheetIndex][ref] = c
            }
        }
        findNext(o)
    }

    /// Replaces every match in the scope as one undo step; returns the number of cells changed.
    @discardableResult
    func replaceAll(_ o: FindOptions) -> Int {
        guard let doc else { return 0 }
        let sheets = o.workbook ? Array(doc.workbook.sheets.indices) : [sheetIndex]
        var edits: [(Int, CellRef, String)] = []
        for si in sheets {
            let s = doc.workbook.sheets[si]
            for (ref, cell) in s.cells {
                guard let input = o.replaced(cell) else { continue }
                if s.isProtected && cell.style.locked { continue }
                edits.append((si, ref, input))
            }
        }
        guard !edits.isEmpty else { return 0 }
        doc.change(L("Replace All")) { wb in
            for (si, ref, input) in edits {
                var c = wb.sheets[si][ref]
                c.input = input
                c.value = c.isFormula ? .empty : XLSX.constant(input)
                wb.sheets[si][ref] = c
            }
        }
        return edits.count
    }
}

/// Floating Find & Replace panel: Find Next / Replace / Replace All with scope and options.
final class FindReplacePanel: NSWindowController, NSWindowDelegate {
    private weak var controller: SheetWindowController?
    private let find = NSTextField(string: UserDefaults.standard.string(forKey: "xls.find") ?? "")
    private let replace = NSTextField(string: UserDefaults.standard.string(forKey: "xls.replace") ?? "")
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private let lookIn = NSPopUpButton(frame: .zero, pullsDown: false)
    private let matchCase = NSButton(checkboxWithTitle: L("Match case"), target: nil, action: nil)
    private let entireCell = NSButton(checkboxWithTitle: L("Entire cell"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    init(controller: SheetWindowController) {
        self.controller = controller
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L("Find and Replace")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        panel.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var options: FindOptions {
        FindOptions(text: find.stringValue, replacement: replace.stringValue, workbook: scope.indexOfSelectedItem == 1,
                    inFormulas: lookIn.indexOfSelectedItem == 0, matchCase: matchCase.state == .on, entireCell: entireCell.state == .on)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        scope.addItems(withTitles: [L("Sheet"), L("Workbook")])
        lookIn.addItems(withTitles: [L("Formulas"), L("Values")])
        for f in [find, replace] { f.translatesAutoresizingMaskIntoConstraints = false; f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Find:")), find],
            [NSTextField(labelWithString: L("Replace with:")), replace],
            [NSTextField(labelWithString: L("Within:")), scope],
            [NSTextField(labelWithString: L("Look in:")), lookIn],
            [NSGridCell.emptyContentView, NSStackView(views: [matchCase, entireCell])],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        let replaceAll = NSButton(title: L("Replace All"), target: self, action: #selector(replaceAllClicked))
        let replaceOne = NSButton(title: L("Replace"), target: self, action: #selector(replaceClicked))
        let next = NSButton(title: L("Find Next"), target: self, action: #selector(findNextClicked))
        next.keyEquivalent = "\r"
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let buttons = NSStackView(views: [status, NSView(), replaceAll, replaceOne, next])
        let root = NSStackView(views: [grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
        window?.initialFirstResponder = find
    }

    func show(relativeTo parent: NSWindow?) {
        if let parent, let w = window, !w.isVisible {
            w.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - w.frame.width - 30, y: parent.frame.maxY - 110))
        }
        showWindow(nil)
        window?.makeFirstResponder(find)
    }

    private func remember() {
        UserDefaults.standard.set(find.stringValue, forKey: "xls.find")
        UserDefaults.standard.set(replace.stringValue, forKey: "xls.replace")
        status.stringValue = ""
    }

    @objc private func findNextClicked() {
        remember()
        if controller?.findNext(options) == false { status.stringValue = L("Not found") }
    }

    @objc private func replaceClicked() {
        remember()
        controller?.replaceCurrent(options)
    }

    @objc private func replaceAllClicked() {
        remember()
        status.stringValue = L("Replaced: %d", controller?.replaceAll(options) ?? 0)
    }
}
