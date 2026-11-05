import AppKit
import Kit42

/// Legacy array formulas (Excel Ctrl+Shift+Enter, Calc's matrix formulas): ⌘⇧Return enters the formula over the
/// selected range, the formula bar shows it as {=…}, and only the whole range can be changed or cleared.
extension SheetWindowController {
    static let partOfArrayMessage = L("You can't change part of an array.")

    /// Formula bar text of a cell: array formulas in braces for every cell of their range.
    func formulaBarText(at ref: CellRef) -> String {
        if let a = sheet.array(containing: ref), sheet[a.anchor].array { return "{" + sheet[a.anchor].input + "}" }
        return sheet[ref].input
    }

    /// Text the cell editor starts with: the array's formula in any cell of its range.
    func editText(at ref: CellRef) -> String {
        if let a = sheet.array(containing: ref) { return sheet[a.anchor].input }
        return sheet[ref].input
    }

    /// Refuses (with Excel's message) a change to `range` that covers only part of an array formula.
    func guardArrays(_ range: CellRange) -> Bool {
        let partial = sheet.arrays.contains { anchor, r in r.count > 1 && r.intersects(range) && !(range.contains(r.start) && range.contains(r.end)) }
        guard partial else { return true }
        report(Self.partOfArrayMessage)
        return false
    }

    /// ⌘⇧Return: enters the edited (or the active cell's) formula as an array formula over the selection.
    @objc func enterArrayAction(_ sender: Any?) {
        var text: String
        if let fieldEditor = formulaFieldEditor, window?.firstResponder === fieldEditor { text = fieldEditor.string }
        else if grid.isEditing { text = grid.editorText }
        else { text = editText(at: grid.active) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{="), text.hasSuffix("}") { text = String(text.dropFirst().dropLast()) }
        guard text.hasPrefix("="), text.count > 1 else {
            if grid.isEditing { grid.commitEdit(move: (1, 0)) } else { NSSound.beep() }
            return
        }
        var range = grid.selection
        // Editing a cell of an existing array re-enters the whole array.
        if let existing = sheet.array(containing: grid.active), range.count == 1 || (existing.range.contains(range.start) && existing.range.contains(range.end)) {
            range = existing.range
        }
        if grid.isEditing { grid.cancelEdit() }
        window?.makeFirstResponder(grid)
        enterArrayFormula(text, range: range)
    }

    /// Puts `formula` over `range` as one array formula (replacing arrays the range covers entirely).
    @discardableResult
    func enterArrayFormula(_ formula: String, range: CellRange) -> Bool {
        guard let doc else { return false }
        guard range.count <= 100_000, let e = try? Formula.parse(formula) else { NSSound.beep(); return false }
        let input = "=" + Formula.serialize(e)
        guard guardEditable(range), guardArrays(range) else { return false }
        doc.change(L("Array Formula")) { wb in
            var s = wb.sheets[sheetIndex]
            for (anchor, r) in s.arrays where range.contains(r.start) && range.contains(r.end) {
                s.arrays[anchor] = nil
                s.cells[anchor]?.array = false
            }
            for ref in range.cells {
                var c = s[ref]
                c.input = ""
                c.value = .empty
                c.array = false
                s[ref] = c
            }
            var anchor = s[range.start]
            anchor.input = input
            anchor.array = true
            s[range.start] = anchor
            s.arrays[range.start] = range
            wb.sheets[sheetIndex] = s
        }
        selectionDidChange()
        return true
    }

    /// Clears the arrays a cleared range covers entirely (their cells' contents are cleared by the caller).
    func dropArrays(in range: CellRange, of wb: inout Workbook) {
        for (anchor, r) in wb.sheets[sheetIndex].arrays where range.contains(r.start) && range.contains(r.end) {
            wb.sheets[sheetIndex].arrays[anchor] = nil
            wb.sheets[sheetIndex].cells[anchor]?.array = false
        }
    }
}
