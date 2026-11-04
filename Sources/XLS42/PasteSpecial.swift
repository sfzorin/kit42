import AppKit
import Kit42

/// Edit › Paste Special… (⌥⌘V): what to paste, arithmetic with the destination, skip blanks, transpose.
extension SheetWindowController {
    enum PasteWhat: Int, CaseIterable { case all, values, formulas, formats }
    enum PasteOperation: Int, CaseIterable { case none, add, subtract, multiply, divide }

    @objc func pasteSpecialAction(_ sender: Any?) {
        grid.commitEdit(move: nil)
        let what = NSPopUpButton(frame: .zero, pullsDown: false)
        what.addItems(withTitles: [L("All"), L("Values only"), L("Formulas only"), L("Formats only")])
        let op = NSPopUpButton(frame: .zero, pullsDown: false)
        op.addItems(withTitles: [L("None"), L("Add"), L("Subtract"), L("Multiply"), L("Divide")])
        let skip = NSButton(checkboxWithTitle: L("Skip blanks"), target: nil, action: nil)
        let transpose = NSButton(checkboxWithTitle: L("Transpose"), target: nil, action: nil)
        let alert = NSAlert.form(L("Paste Special"), ok: L("Paste"), rows: [(L("Paste:"), what), (L("Operation:"), op), ("", skip), ("", transpose)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pasteSpecial(PasteWhat(rawValue: what.indexOfSelectedItem) ?? .all, operation: PasteOperation(rawValue: op.indexOfSelectedItem) ?? .none,
                     skipBlanks: skip.state == .on, transpose: transpose.state == .on)
    }

    /// The copied cells (from this app, or tab-separated text from another one) as offsets → cells.
    private func clipboardCells() -> (origin: CellRef, rows: Int, cols: Int, cells: [CellRef: Cell])? {
        let pb = NSPasteboard.general
        if let clip = Self.clip, clip.changeCount == pb.changeCount { return (clip.origin, clip.rows, clip.cols, clip.cells) }
        guard let text = pb.string(forType: .string) else { return nil }
        var cells: [CellRef: Cell] = [:]
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false)
        var cols = 0
        for (r, line) in lines.enumerated() where !(r == lines.count - 1 && line.isEmpty) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            cols = max(cols, fields.count)
            for (c, f) in fields.enumerated() where !f.isEmpty {
                var cell = Cell()
                cell.input = String(f)
                cell.value = cell.isFormula ? .empty : XLSX.constant(cell.input)
                cells[CellRef(row: r, col: c)] = cell
            }
        }
        let rows = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
        return (grid.active, max(1, rows), max(1, cols), cells)
    }

    /// Pastes the clipboard at the active cell. One undo step.
    func pasteSpecial(_ what: PasteWhat, operation: PasteOperation, skipBlanks: Bool, transpose: Bool) {
        guard let doc, let clip = clipboardCells() else { NSSound.beep(); return }
        let dest = grid.active
        let rows = transpose ? clip.cols : clip.rows, cols = transpose ? clip.rows : clip.cols
        let target = CellRange(dest, CellRef(row: dest.row + rows - 1, col: dest.col + cols - 1))
        guard guardEditable(target) else { return }
        doc.change(L("Paste Special")) { wb in
            for r in 0..<clip.rows {
                for c in 0..<clip.cols {
                    let offset = CellRef(row: r, col: c)
                    let src = clip.cells[offset] ?? Cell()
                    if skipBlanks && src.input.isEmpty && src.value.isEmpty { continue }
                    let to = transpose ? CellRef(row: dest.row + c, col: dest.col + r) : CellRef(row: dest.row + r, col: dest.col + c)
                    var cell = wb.sheets[sheetIndex][to]
                    let from = CellRef(row: clip.origin.row + r, col: clip.origin.col + c)
                    var input = src.input, value = src.value
                    if src.isFormula { input = Formula.shifted(src.input, rows: to.row - from.row, cols: to.col - from.col) }
                    if what == .values { input = src.isFormula ? XLSX.inputText(for: src.value, style: src.style) : src.input; value = src.value }
                    switch what {
                    case .formats:
                        cell.style = src.style
                    case .all, .values, .formulas:
                        if operation != .none, let combined = Self.combine(cell, input: input, value: value, operation) {
                            (input, value) = combined
                        }
                        cell.input = input
                        cell.value = input.hasPrefix("=") && input.count > 1 ? .empty : value
                        if what == .all { cell.style = src.style }
                    }
                    wb.sheets[sheetIndex][to] = cell
                }
            }
        }
        grid.selection = target
        grid.needsDisplay = true
        selectionDidChange()
    }

    /// Destination ⊕ source for the arithmetic operations (numbers; formulas become "=(old)+x").
    private static func combine(_ dest: Cell, input: String, value: Value, _ op: PasteOperation) -> (String, Value)? {
        let sym = ["", "+", "-", "*", "/"][op.rawValue]
        let srcText: String
        if input.hasPrefix("=") && input.count > 1 { srcText = "(" + input.dropFirst() + ")" }
        else if case .number(let d) = value { srcText = Value.formatGeneral(d) }
        else if value.isEmpty { srcText = "0" }
        else { return nil }   // text is pasted as is
        if dest.isFormula { return ("=(" + dest.input.dropFirst() + ")" + sym + srcText, .empty) }
        let a: Double
        switch dest.value {
        case .number(let d): a = d
        case .empty: a = 0
        default: return nil
        }
        if srcText.hasPrefix("(") { return ("=" + Value.formatGeneral(a) + sym + srcText, .empty) }
        guard let b = Double(srcText) else { return nil }
        let r: Double
        switch op {
        case .add: r = a + b
        case .subtract: r = a - b
        case .multiply: r = a * b
        case .divide: if b == 0 { return ("=" + Value.formatGeneral(a) + "/0", .empty) }; r = a / b
        case .none: return nil
        }
        return (Value.formatGeneral(r), .number(r))
    }
}
