import AppKit
import Kit42

extension UITest {
    /// Native editing regressions; the outer UI harness preserves the clipboard.
    static func deepEditing(_ w: SheetWindowController, _ doc: SheetDocument) -> Int {
        var failures = 0, checks = 0
        let alerts = w.suppressAlerts
        w.suppressAlerts = true
        defer { w.grid.cancelEdit(); w.suppressAlerts = alerts }
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures += 1 }
            print(condition ? "ok  " : "FAIL", "deep editing:", name)
        }
        func ref(_ name: String) -> CellRef { CellRef(name)! }
        func cell(_ name: String) -> Cell { w.sheet[ref(name)] }
        func select(_ name: String, _ end: String? = nil) {
            w.grid.select(ref(name))
            if let end { w.grid.select(ref(end), extend: true) }
        }
        func input(_ value: String, _ name: String) { w.setInput(value, at: ref(name)) }
        func clipboard(_ text: String) {
            SheetWindowController.pasteboard.clearContents()
            SheetWindowController.pasteboard.setString(text, forType: .string)
        }
        func clean() {
            w.grid.cancelEdit()
            doc.workbook.date1904 = false
            doc.workbook.sheets[w.sheetIndex] = Sheet(name: "Deep Editing")
            w.workbookDidChange()
            select("A1")
            doc.undoManager?.removeAllActions()
            doc.updateChangeCount(.changeCleared)
            w.lastAlertMessage = nil
        }
        func array(_ range: String) { _ = w.enterArrayFormula("=ROW(A1:A2)*10", range: CellRange(range)!) }
        func key(_ text: String, _ modifiers: NSEvent.ModifierFlags = []) {
            w.window?.makeFirstResponder(w.grid)
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: w.window?.windowNumber ?? 0, context: nil,
                                           characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) {
                w.grid.keyDown(with: event)
            }
        }
        w.addSheet(nil)
        clean()

        // Native reverse traversal must cross to the previous column/row, not jump to the range end.
        select("A1", "B2"); w.grid.active = ref("B1")
        key("\r", .shift)
        check("Shift-Enter wraps to previous column", w.grid.active == ref("A2") && w.grid.selection == CellRange("A1:B2"))
        w.grid.active = ref("A2"); key("\t", .shift)
        check("Shift-Tab wraps to previous row", w.grid.active == ref("B1") && w.grid.selection == CellRange("A1:B2"))
        w.grid.active = ref("A1"); key("\t", .shift)
        check("reverse traversal wraps at first selected cell", w.grid.active == ref("B2"))
        w.grid.active = ref("B2"); key("\r")
        check("forward traversal wraps at last selected cell", w.grid.active == ref("A1"))

        clean()
        input("existing", "A1"); select("A1"); w.toggleBold(nil)
        clipboard("\"line1\nline2\"\t\"tab\tvalue\"\rnext\t\"a\"\"b\"\r")
        w.paste(nil)
        check("quoted external TSV keeps embedded tabs, newlines and escaped quotes", cell("A1").input == "line1\nline2" && cell("B1").input == "tab\tvalue" && cell("A2").input == "next" && cell("B2").input == "a\"b")
        check("ordinary external paste retains destination formatting and exact dimensions", cell("A1").style.bold && w.grid.selection == CellRange("A1:B2") && cell("A3").input.isEmpty)
        doc.undoManager?.undo()
        check("external multi-cell paste is one Undo", cell("A1").input == "existing" && cell("B1").input.isEmpty && cell("A2").input.isEmpty)
        doc.undoManager?.redo()
        check("external multi-cell paste Redo restores contents", cell("A1").input == "line1\nline2" && cell("B2").input == "a\"b")
        select("A1", "B2"); w.copy(nil)
        check("copy escapes multiline and tab-containing cells for other apps", SheetWindowController.pasteboard.string(forType: .string) == "\"line1\nline2\"\t\"tab\tvalue\"\nnext\t\"a\"\"b\"")

        clean(); array("C1:C2")
        select("C1", "C2"); w.copy(nil); select("E1"); w.paste(nil)
        check("full legacy array copy preserves its fixed range and formula", w.sheet.arrays[ref("E1")] == CellRange("E1:E2") && cell("E1").array && cell("E1").input == "=ROW(C1:C2)*10" && cell("E2").value == .number(20))
        doc.undoManager?.undo()
        check("Undo legacy array paste removes both formula and metadata", w.sheet.arrays[ref("E1")] == nil && cell("E1").input.isEmpty)
        doc.undoManager?.redo()
        check("Redo legacy array paste restores its range", w.sheet.arrays[ref("E1")] == CellRange("E1:E2") && cell("E2").value == .number(20))
        select("C2"); w.copy(nil); select("G1"); w.paste(nil)
        check("copying part of a legacy array pastes its value", cell("G1").input == "20" && cell("G1").value == .number(20) && !cell("G1").array && w.sheet.arrays[ref("G1")] == nil)
        select("C1", "C2"); w.copy(nil); select("H1"); w.pasteSpecial(.values, operation: .none, skipBlanks: false, transpose: false)
        check("Paste Values retains every cached array result", cell("H1").value == .number(10) && cell("H2").value == .number(20) && cell("H2").input == "20" && w.sheet.arrays[ref("H1")] == nil)
        select("I1"); w.pasteSpecial(.all, operation: .none, skipBlanks: false, transpose: true)
        check("transpose preserves a legacy array's results and transposed extent", w.sheet.arrays[ref("I1")] == CellRange("I1:J1") && cell("I1").array && cell("I1").value == .number(10) && cell("J1").value == .number(20))

        clean(); array("A1:A2"); doc.undoManager?.removeAllActions()
        let savedArrayCells = w.sheet.cells, savedArrays = w.sheet.arrays
        select("A2"); clipboard("99"); let clipboardVersion = SheetWindowController.pasteboard.changeCount
        w.paste(nil)
        check("ordinary external paste rejects partial legacy array without Undo", w.sheet.cells == savedArrayCells && w.sheet.arrays == savedArrays && !doc.undoManager!.canUndo && w.lastAlertMessage == SheetWindowController.partOfArrayMessage)
        w.pasteSpecial(.values, operation: .none, skipBlanks: false, transpose: false)
        check("Paste Special rejects partial legacy array", w.sheet.cells == savedArrayCells && w.sheet.arrays == savedArrays && SheetWindowController.pasteboard.changeCount == clipboardVersion)
        w.cut(nil)
        check("rejected partial-array Cut preserves clipboard and cells", SheetWindowController.pasteboard.changeCount == clipboardVersion && w.sheet.cells == savedArrayCells && w.sheet.arrays == savedArrays)
        select("A1"); clipboard("\n99"); w.pasteSpecial(.all, operation: .none, skipBlanks: true, transpose: false)
        check("Skip blanks cannot disguise a partial array write", w.sheet.cells == savedArrayCells && w.sheet.arrays == savedArrays)
        clipboard("7\n8"); w.paste(nil)
        check("full overwrite removes stale array metadata", w.sheet.arrays.isEmpty && !cell("A1").array && cell("A1").value == .number(7) && cell("A2").value == .number(8))
        doc.undoManager?.undo()
        check("full array overwrite Undo restores values and metadata", w.sheet.cells == savedArrayCells && w.sheet.arrays == savedArrays)
        doc.undoManager?.redo()
        check("full array overwrite Redo restores ordinary cells", w.sheet.arrays.isEmpty && cell("A2").value == .number(8))

        clean(); array("A1:A2"); input("9", "D1"); select("D1"); w.toggleBold(nil); w.copy(nil); select("A2")
        w.pasteSpecial(.formats, operation: .none, skipBlanks: false, transpose: false)
        check("Paste Formats may format part of an array without changing formula", w.sheet.arrays[ref("A1")] == CellRange("A1:A2") && cell("A2").style.bold && cell("A2").value == .number(20))

        clean(); input("keep", "A1"); input("old", "B1")
        doc.change("Unlocked destination", recalc: false) { $0.sheets[w.sheetIndex].cells[ref("B1")]?.style.locked = false }
        w.protectSheet(password: "")
        select("A1"); clipboard("\t77"); w.pasteSpecial(.all, operation: .none, skipBlanks: true, transpose: false)
        check("Skip blanks leaves protected locked cells untouched", cell("A1").input == "keep" && cell("B1").value == .number(77) && !cell("B1").style.locked)
        select("A1"); clipboard("changed\t88"); let protectedCells = w.sheet.cells
        w.paste(nil)
        check("mixed locked/unlocked paste refuses atomically", w.sheet.cells == protectedCells)
        select("B1"); clipboard("88"); w.paste(nil)
        check("ordinary external paste permits unlocked cells on protected sheet", cell("B1").value == .number(88))
        doc.change("Hidden protected headings", recalc: false) { $0.sheets[w.sheetIndex].rowHeights[0] = 0; $0.sheets[w.sheetIndex].columnWidths[0] = 0 }
        select("A1"); w.unhideRowsAction(nil); w.unhideColumnsAction(nil)
        check("Unhide respects sheet protection", w.sheet.rowHeights[0] == 0 && w.sheet.columnWidths[0] == 0)

        clean(); input("unchanged", "A1"); doc.undoManager?.removeAllActions()
        let boundedCells = w.sheet.cells
        clipboard(String(repeating: "x\n", count: SheetWindowController.maximumCellOperationCount + 1))
        w.paste(nil)
        check("oversized external paste is refused before mutation", w.sheet.cells == boundedCells && !doc.undoManager!.canUndo)
        w.pasteSpecial(.all, operation: .none, skipBlanks: false, transpose: false)
        if w.sheet.cells != boundedCells || doc.undoManager!.canUndo { print("paste diagnostic", "cells", w.sheet.cells.count, "first", cell("A1").input.prefix(40), "undo", doc.undoManager!.canUndo, "clipboard", SheetWindowController.pasteboard.string(forType: .string)?.count ?? -1, "error", w.lastAlertMessage ?? "-") }
        check("oversized Paste Special is refused before mutation", w.sheet.cells == boundedCells && !doc.undoManager!.canUndo)
        clipboard("1\t2")
        w.grid.active = CellRef(row: RefPart.maxRow, col: RefPart.maxCol)
        w.paste(nil)
        check("paste across worksheet edge is refused without out-of-grid cells", w.sheet.cells == boundedCells && !doc.undoManager!.canUndo)
        select("A1")

        clean(); input("9", "A1"); array("A2:A3"); doc.undoManager?.removeAllActions()
        let fillCells = w.sheet.cells, fillArrays = w.sheet.arrays
        select("A1", "A2"); w.fillDown(nil)
        check("Fill Down refuses partial array destination", w.sheet.cells == fillCells && w.sheet.arrays == fillArrays && !doc.undoManager!.canUndo)
        select("A1", "A3"); w.fillDown(nil)
        check("Fill Down may replace complete destination array", w.sheet.arrays.isEmpty && cell("A2").value == .number(9) && cell("A3").value == .number(9))
        doc.undoManager?.undo()
        check("Fill overwrite Undo restores array metadata", w.sheet.cells == fillCells && w.sheet.arrays == fillArrays)
        w.autoFill(from: CellRange("A1")!, to: CellRange("A1:A2")!)
        check("drag AutoFill refuses partial array destination", w.sheet.cells == fillCells && w.sheet.arrays == fillArrays)
        w.autoFill(from: CellRange("A1")!, to: CellRange("A1")!)
        check("zero-distance fill is a harmless no-op", w.sheet.cells == fillCells && w.sheet.arrays == fillArrays)
        input("4", "A4"); select("A3", "A4"); w.fillUpAction(nil)
        check("Fill Up refuses partial array destination", cell("A3").value == .number(20) && w.sheet.arrays == fillArrays)
        let beforeStoppedSeries = w.sheet.cells
        w.applySeries(CellRange("A1:A4")!, direction: .down, type: .linear, unit: .day, step: 1, stop: 10)
        check("series stop checks actual writes before changing part of array", w.sheet.cells == beforeStoppedSeries && w.sheet.arrays == fillArrays)

        clean(); input("9", "A1")
        _ = w.enterArrayFormula("=COLUMN(A1:B1)*10", range: CellRange("B1:C1")!)
        let horizontalCells = w.sheet.cells
        select("A1", "B1"); w.fillRight(nil)
        check("Fill Right refuses partial array destination", w.sheet.cells == horizontalCells)
        input("4", "D1"); select("C1", "D1"); w.fillLeftAction(nil)
        check("Fill Left refuses partial array destination", w.sheet.arrays[ref("B1")] == CellRange("B1:C1") && cell("C1").value == .number(20))

        clean(); array("A1:A2"); input("=ROW(A1)", "C1")
        let find = FindOptions(text: "ROW", replacement: "COLUMN", workbook: false)
        select("A1"); w.replaceCurrent(find)
        check("Replace Current cannot change part of a legacy array", cell("A1").input == "=ROW(A1:A2)*10" && cell("A2").value == .number(20))
        let replaced = w.replaceAll(find)
        check("Replace All skips legacy arrays and updates ordinary formulas", replaced == 1 && cell("C1").input == "=COLUMN(A1)" && cell("A1").input == "=ROW(A1:A2)*10")
        doc.undoManager?.undo()
        check("Replace All Undo restores exactly its ordinary formula", cell("C1").input == "=ROW(A1)" && cell("A2").value == .number(20))

        clean(); input("100", "A1"); input("keep", "A5")
        w.applySeries(CellRange("A1:A5")!, direction: .down, type: .growth, unit: .day, step: 0.5, stop: 12.5)
        check("decreasing growth series honors its end value", cell("A2").value == .number(50) && cell("A3").value == .number(25) && cell("A4").value == .number(12.5) && cell("A5").input == "keep")
        clean(); let monday = DateMath.parse("2024-01-08")!
        input(Value.formatGeneral(monday), "A1")
        w.applySeries(CellRange("A1:A2")!, direction: .down, type: .date, unit: .weekday, step: 10_000, stop: nil)
        check("large weekday series advances in bounded time", cell("A2").value == .number(monday + 14_000))
        let beforeInvalid = w.sheet.cells
        w.applySeries(CellRange("A1:A2")!, direction: .down, type: .date, unit: .weekday, step: 1e300, stop: nil)
        check("unrepresentable date increment cannot trap or mutate", w.sheet.cells == beforeInvalid)
        clean(); doc.workbook.date1904 = true; input("0", "A1")
        w.applySeries(CellRange("A1:A2")!, direction: .down, type: .date, unit: .weekday, step: 1, stop: nil)
        check("weekday series uses the workbook's 1904 date system", cell("A2").value == .number(3))
        w.applySeries(CellRange("A1:A2")!, direction: .down, type: .date, unit: .month, step: 1, stop: nil)
        check("month series uses the workbook's 1904 date system", cell("A2").value == .number(31))
        select("C1"); clipboard("1904-01-02"); w.paste(nil)
        check("external pasted date uses the workbook's 1904 date system", cell("C1").value == .number(1))
        doc.change("Display date", recalc: false) { $0.sheets[w.sheetIndex].cells[ref("C1")]?.style.numberFormat = "yyyy-mm-dd" }
        let dateFind = FindOptions(text: "1904-01-02", replacement: "1904-01-03", inFormulas: false, entireCell: true)
        check("Find Values searches the displayed 1904 date", w.findMatches(dateFind).contains { $0.ref == ref("C1") })
        w.replaceCurrent(dateFind)
        check("Replace Values preserves the workbook's date system", cell("C1").value == .number(2))

        clean(); doc.workbook.date1904 = true
        input("'1904-01-02,1904-01-03", "A1")
        let datedText = cell("A1")
        var splitDates = DataTools.SplitOptions(); splitDates.types = [.dateYMD, .general]
        w.applyTextToColumns(CellRange("A1")!, options: splitDates)
        check("Text to Columns parses explicit and general dates in 1904 workbooks", cell("A1").value == .number(1) && cell("B1").value == .number(2))
        doc.undoManager?.undo()
        check("Text to Columns Undo restores the unsplit text", cell("A1") == datedText && cell("B1").input.isEmpty)
        clean(); doc.workbook.date1904 = true
        input("Date", "A1"); input("=1", "A2"); input("=2", "A3")
        doc.change("Date column", recalc: false) { wb in
            wb.sheets[w.sheetIndex].cells[ref("A2")]?.style.numberFormat = "yyyy-mm-dd"
            wb.sheets[w.sheetIndex].cells[ref("A3")]?.style.numberFormat = "yyyy-mm-dd"
        }
        let dateCriteria = [DataTools.Criterion(field: 0, condition: FilterCondition(op: .equal, value: "1904-01-02"))]
        w.applyStandardFilter(CellRange("A1:A3")!, criteria: dateCriteria, caseSensitive: false, unique: false, header: true, copyTo: nil)
        check("Standard Filter compares typed dates with the 1904 epoch", w.sheet.filterHidden == [2])
        w.applyStandardFilter(CellRange("A1:A3")!, criteria: dateCriteria, caseSensitive: false, unique: false, header: true, copyTo: (w.sheetIndex, ref("C1")))
        check("copying filter results retains displayed dates and numeric values", cell("C2").value == .number(1) && cell("C2").input == "02.01.1904" && cell("C3").value.isEmpty)
        var refiltered = w.sheet
        refiltered.customFilters = [:]; refiltered.filterValues = [0: ["1904-01-03"]]
        DataTools.refilter(&refiltered, workbook: doc.workbook)
        check("recalculated value-list filter uses displayed 1904 dates", refiltered.filterHidden == [1])

        clean(); input("'1,2", "A1"); array("B1:B2")
        let splitCells = w.sheet.cells, splitArrays = w.sheet.arrays
        w.applyTextToColumns(CellRange("A1")!, options: DataTools.SplitOptions())
        check("Text to Columns cannot overwrite part of a legacy array", w.sheet.cells == splitCells && w.sheet.arrays == splitArrays)
        clean(); input("1,2,3", "A1"); array("B1:C1")
        w.applyTextToColumns(CellRange("A1")!, options: DataTools.SplitOptions())
        check("Text to Columns replaces a complete legacy array without stale metadata", w.sheet.arrays.isEmpty && cell("B1").value == .number(2) && cell("C1").value == .number(3) && !cell("B1").array)
        doc.undoManager?.undo()
        check("Text to Columns Undo restores legacy metadata and source text", cell("A1").input == "1,2,3" && w.sheet.arrays[ref("B1")] == CellRange("B1:C1"))
        clean(); input("Header", "A1"); input("7", "A2"); array("C2:C3")
        let filterCells = w.sheet.cells, filterArrays = w.sheet.arrays
        w.applyStandardFilter(CellRange("A1:A2")!, criteria: [], caseSensitive: false, unique: false, header: true, copyTo: (w.sheetIndex, ref("C1")))
        check("Filter Copy refuses a destination crossing part of an array", w.sheet.cells == filterCells && w.sheet.arrays == filterArrays)
        w.protectSheet(password: "")
        w.applyStandardFilter(CellRange("A1:A2")!, criteria: [], caseSensitive: false, unique: false, header: true, copyTo: (w.sheetIndex, ref("E1")))
        check("Filter Copy respects destination protection", cell("E1").input.isEmpty && cell("E2").input.isEmpty)
        clean(); array("A1:A2")
        let sortCells = w.sheet.cells, sortArrays = w.sheet.arrays
        select("A1", "A2"); w.sortDescending(nil)
        check("toolbar Sort refuses legacy array relocation", w.sheet.cells == sortCells && w.sheet.arrays == sortArrays)
        w.applySort(CellRange("A1:A2")!, keys: [.init(index: 0, ascending: false)], options: .init())
        check("Sort dialog refuses legacy array relocation", w.sheet.cells == sortCells && w.sheet.arrays == sortArrays)
        check("Remove Duplicates refuses legacy array relocation", w.applyRemoveDuplicates(CellRange("A1:A2")!, columns: [0], header: false) == 0 && w.sheet.cells == sortCells && w.sheet.arrays == sortArrays)
        let oversizedFilter = DataTools.matches(.number(20), FilterCondition(op: .top, value: "1e300"), caseSensitive: false, column: [.number(10), .number(20)], calc: Calculator(doc.workbook))
        check("large Top filter count is bounded without integer conversion overflow", oversizedFilter)

        clean()
        var validation = DataValidation(ranges: [CellRange("A1")!], kind: .whole)
        validation.formula1 = "1"; validation.formula2 = "10"
        w.setValidation(validation, for: CellRange("A1")!)
        doc.undoManager?.removeAllActions()
        select("A1"); w.grid.beginEdit(initial: "99")
        let accepted = w.grid.commitEdit(move: (1, 0))
        check("rejected cell validation preserves pending input and selection", !accepted && w.grid.isEditing && w.grid.pendingEdit?.text == "99" && w.grid.active == ref("A1") && cell("A1").input.isEmpty && !doc.undoManager!.canUndo)
        w.grid.setEditorText("5")
        check("valid correction commits and advances", w.grid.commitEdit(move: (1, 0)) && !w.grid.isEditing && cell("A1").value == .number(5) && w.grid.active == ref("A2"))
        doc.undoManager?.undo()
        check("corrected edit Undo restores previous value", cell("A1").input.isEmpty)
        doc.undoManager?.redo()
        check("corrected edit Redo restores value", cell("A1").value == .number(5))

        print("XLS deep editing regressions: \(checks - failures)/\(checks) passed")
        return failures
    }
}
