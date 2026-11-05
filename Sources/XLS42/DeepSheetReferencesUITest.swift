import AppKit
import Kit42

extension UITest {
    static func deepSheetReferences(_ w: SheetWindowController, _ doc: SheetDocument) -> Int {
        var failed = 0, checked = 0
        func check(_ title: String, _ ok: Bool) {
            checked += 1
            if !ok { failed += 1 }
            print(ok ? "ok  " : "FAIL", "deep sheet references:", title)
        }
        w.grid.cancelEdit()
        doc.workbook = Workbook()
        let source = String(repeating: "😀", count: 15) + "x"
        doc.workbook.sheets = [Sheet(name: source), Sheet(name: "Other")]
        w.sheetIndex = 0; w.workbookDidChange()
        w.setInput("7", at: CellRef("A1")!)
        w.setInput("='\(source)'!A1+1", at: CellRef("B1")!)
        doc.undoManager?.removeAllActions()
        w.moveSheet(0, before: 1, copy: true)
        let firstCopy = w.sheet.name
        check("copy selects a unique bounded tab", w.sheetIndex == 1 && firstCopy != source && SheetWindowController.validSheetName(firstCopy))
        w.setInput("9", at: CellRef("A1")!)
        check("copied formula follows copied cell", w.sheet[CellRef("B1")!].value == .number(10) && doc.workbook.sheets[0][CellRef("B1")!].value == .number(8))
        w.moveSheet(0, before: 2, copy: true)
        let secondCopy = w.sheet.name
        check("second copy avoids truncated-name collision", secondCopy != firstCopy && secondCopy != source && SheetWindowController.validSheetName(secondCopy))
        doc.undoManager?.undo()
        check("undo removes only last copy", doc.workbook.sheets.count == 3 && doc.workbook.sheetIndex(named: firstCopy) != nil && doc.workbook.sheetIndex(named: secondCopy) == nil)
        doc.undoManager?.redo()
        check("redo restores copy and references", doc.workbook.sheets.count == 4 && doc.workbook.sheetIndex(named: secondCopy) != nil)
        if let index = doc.workbook.sheetIndex(named: secondCopy) {
            w.moveSheet(index, before: doc.workbook.sheets.count, copy: false, name: "Renamed")
            check("move+rename selects renamed tab", w.sheet.name == "Renamed" && w.sheet[CellRef("B1")!].input == "=Renamed!A1+1")
            w.moveSheet(w.sheetIndex, before: doc.workbook.sheets.count, copy: false, name: "RENAMED")
            check("case-only rename updates self-reference", w.sheet.name == "RENAMED" && w.sheet[CellRef("B1")!].input == "=RENAMED!A1+1")
        } else { check("redo copy available", false) }
        print("XLS deep sheet reference UI: \(checked - failed)/\(checked) passed")
        return failed
    }
}
