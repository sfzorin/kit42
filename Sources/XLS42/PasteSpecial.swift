import AppKit
import Kit42

/// Edit › Paste Special… (⌥⌘V): what to paste, arithmetic with the destination, skip blanks, transpose.
extension SheetWindowController {
    enum PasteWhat: Int, CaseIterable { case all, values, formulas, formats }
    enum PasteOperation: Int, CaseIterable { case none, add, subtract, multiply, divide }

    @objc func pasteSpecialAction(_ sender: Any?) {
        guard grid.commitEdit(move: nil) else { return }
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

    /// Read TSV without materializing a huge dense rectangle. Quoted cells may contain
    /// tabs/newlines; a trailing line terminator does not create another spreadsheet row.
    func clipboardCells() -> Clip? {
        let pb = SheetWindowController.pasteboard
        if let clip = Self.clip, clip.changeCount == pb.changeCount { return clip }
        guard let text = pb.string(forType: .string) else { return nil }
        var cells: [CellRef: Cell] = [:]
        var row = 0, col = 0, width = 0, field = "", quoted = false, endedRow = false
        var scalars = text.unicodeScalars.makeIterator()
        var pending: UnicodeScalar?
        func commit() -> Bool {
            width = max(width, col + 1)
            guard width <= RefPart.maxCol + 1, row <= RefPart.maxRow,
                  row + 1 <= Self.maximumCellOperationCount / width else {
                report(L("This operation supports up to %d cells. Select a smaller range.", Self.maximumCellOperationCount))
                return false
            }
            if !field.isEmpty {
                var cell = Cell()
                cell.input = field
                if cell.isFormula, let expression = try? Formula.parse(field) { cell.input = "=" + Formula.serialize(expression) }
                cell.value = cell.isFormula ? .empty : XLSX.constant(cell.input, date1904: doc?.workbook.date1904 ?? false)
                cells[CellRef(row: row, col: col)] = cell
            }
            field = ""
            return true
        }
        while let ch = pending ?? scalars.next() {
            pending = nil
            endedRow = false
            if quoted {
                if ch == "\"" {
                    let next = scalars.next()
                    if next == "\"" { field.append("\"") }
                    else { quoted = false; pending = next }
                } else { field.unicodeScalars.append(ch) }
            } else if ch == "\"", field.isEmpty {
                quoted = true
            } else if ch == "\t" {
                guard commit() else { return nil }
                col += 1
            } else if ch == "\n" || ch == "\r" {
                if ch == "\r" {
                    let next = scalars.next()
                    if next != "\n" { pending = next }
                }
                guard commit() else { return nil }
                row += 1; col = 0; endedRow = true
            } else { field.unicodeScalars.append(ch) }
        }
        if !endedRow { guard commit() else { return nil } }
        return Clip(origin: grid.active, rows: max(1, row + (endedRow ? 0 : 1)), cols: max(1, width),
                    cells: cells, changeCount: pb.changeCount, external: true)
    }

    func pasteTarget(rows: Int, cols: Int, at dest: CellRef) -> CellRange? {
        guard rows > 0, cols > 0, dest.row >= 0, dest.col >= 0,
              dest.row <= RefPart.maxRow, dest.col <= RefPart.maxCol,
              rows <= RefPart.maxRow - dest.row + 1, cols <= RefPart.maxCol - dest.col + 1 else {
            report(L("This operation supports up to %d cells. Select a smaller range.", Self.maximumCellOperationCount))
            return nil
        }
        let target = CellRange(dest, CellRef(row: dest.row + rows - 1, col: dest.col + cols - 1))
        return guardCellOperation(target) ? target : nil
    }

    /// Pastes through the same preflight as ordinary Paste, as one undo step.
    func pasteSpecial(_ what: PasteWhat, operation: PasteOperation, skipBlanks: Bool, transpose: Bool) {
        performPaste(what, operation: operation, skipBlanks: skipBlanks, transpose: transpose, ordinary: false)
    }

    func performPaste(_ what: PasteWhat, operation: PasteOperation = .none, skipBlanks: Bool = false,
                      transpose: Bool = false, ordinary: Bool) {
        guard grid.commitEdit(move: nil), let doc, let clip = clipboardCells() else { return }
        let dest = grid.active
        guard let target = pasteTarget(rows: transpose ? clip.cols : clip.rows, cols: transpose ? clip.rows : clip.cols, at: dest) else { return }
        let preservesArrays = (what == .all || what == .formulas) && operation == .none
        func destination(_ offset: CellRef) -> CellRef {
            CellRef(row: dest.row + (transpose ? offset.col : offset.row), col: dest.col + (transpose ? offset.row : offset.col))
        }
        let offsets = (0..<clip.rows).flatMap { r in (0..<clip.cols).map { CellRef(row: r, col: $0) } }.filter { offset in
            let cell = clip.cells[offset] ?? Cell()
            return !skipBlanks || !cell.input.isEmpty || !cell.value.isEmpty ||
                (preservesArrays && clip.arrays.values.contains { $0.contains(offset) })
        }
        let writes = Set(offsets.map(destination))
        guard !writes.isEmpty else { return }
        // Skip blanks really leaves those cells untouched, including locked cells and arrays.
        guard writes.allSatisfy({ !sheet.isProtected || !sheet[$0].style.locked }) else { refuseProtected(); return }
        if what != .formats, !guardArrayEdits(writes) { return }
        doc.change(ordinary ? L("Paste") : L("Paste Special"), recalc: what != .formats) { wb in
            if what != .formats { dropArrays(replacedBy: writes, of: &wb) }
            for offset in offsets {
                let src = clip.cells[offset] ?? Cell(), to = destination(offset)
                var cell = wb.sheets[sheetIndex][to]
                let locked = cell.style.locked, hiddenFormula = cell.style.hiddenFormula
                let from = CellRef(row: clip.origin.row + offset.row, col: clip.origin.col + offset.col)
                var input = src.input, value = src.value
                if src.isFormula { input = Formula.shifted(src.input, rows: to.row - from.row, cols: to.col - from.col) }
                if what == .values || (!src.isFormula && src.input.isEmpty && !src.value.isEmpty && !preservesArrays) {
                    input = XLSX.inputText(for: src.value, style: src.style, date1904: wb.date1904)
                }
                switch what {
                case .formats:
                    cell.style = src.style
                case .all, .values, .formulas:
                    if operation != .none, let combined = Self.combine(cell, input: input, value: value, operation) { (input, value) = combined }
                    cell.input = input
                    cell.value = input.hasPrefix("=") && input.count > 1 ? .empty : value
                    cell.array = false
                    if what == .all && !(ordinary && clip.external) { cell.style = src.style }
                }
                // Pasting formatting into an unlocked cell must not silently lock it
                // or change formula protection while the sheet is protected.
                if wb.sheets[sheetIndex].isProtected {
                    cell.style.locked = locked
                    cell.style.hiddenFormula = hiddenFormula
                }
                wb.sheets[sheetIndex][to] = cell
            }
            if preservesArrays {
                for (anchor, range) in clip.arrays {
                    let to = destination(anchor)
                    let moved = CellRange(destination(range.start), destination(range.end))
                    wb.sheets[sheetIndex].arrays[to] = moved
                    wb.sheets[sheetIndex].cells[to]?.array = true
                    if transpose, let input = wb.sheets[sheetIndex].cells[to]?.input, input.hasPrefix("=") {
                        wb.sheets[sheetIndex].cells[to]?.input = "=TRANSPOSE(" + input.dropFirst() + ")"
                    }
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
