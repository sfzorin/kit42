import AppKit
import Kit42

/// `XLS42 --uitest`: drives a real window through the controller and checks the results.
enum UITest {
    static func run() {
        let doc = SheetDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        guard let w = doc.editor else { print("FAIL no window"); exit(1) }
        doc.undoManager?.groupsByEvent = false   // one undo step per change, as with separate user actions
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func cell(_ a1: String) -> Cell { w.sheet[CellRef(a1)!] }
        func select(_ a1: String, to b1: String? = nil) {
            w.grid.select(CellRef(a1)!)
            if let b1 { w.grid.select(CellRef(b1)!, extend: true) }
        }

        w.setInput("10", at: CellRef("A1")!)
        w.setInput("20", at: CellRef("A2")!)
        w.setInput("=сумм(A1:A2)", at: CellRef("A3")!)
        check("formula with Russian name", cell("A3").value == .number(30) && cell("A3").input == "=SUM(A1:A2)", "\(cell("A3"))")
        w.setInput("15%", at: CellRef("C1")!)
        check("percent input", cell("C1").value == .number(0.15) && cell("C1").style.numberFormat == "0%")
        w.setInput("31.12.2024", at: CellRef("C2")!)
        check("date input", cell("C2").style.numberFormat == "dd.mm.yyyy" && NumberFormat.format(cell("C2").value, "dd.mm.yyyy").text == "31.12.2024")

        select("A3"); w.copy(nil); select("B3"); w.paste(nil)
        check("paste shifts formula", cell("B3").input == "=SUM(B1:B2)", cell("B3").input)

        select("A1"); w.insertRowsAction(nil)
        check("insert row adjusts refs", cell("A4").input == "=SUM(A2:A3)" && cell("A4").value == .number(30), cell("A4").input)
        doc.undoManager?.undo()
        check("undo insert", cell("A3").input == "=SUM(A1:A2)", cell("A3").input)

        select("A1"); w.toggleBold(nil)
        check("bold", cell("A1").style.bold)
        doc.undoManager?.undo()
        check("undo bold", !cell("A1").style.bold)

        w.freezeTopRowAction(nil)
        check("freeze top row", w.sheet.frozenRows == 1 && w.sheet.frozenCols == 0)
        select("B2"); w.freezeAction(nil)   // toggles off
        check("unfreeze", w.sheet.frozenRows == 0)
        w.freezeAction(nil)
        check("freeze at B2", w.sheet.frozenRows == 1 && w.sheet.frozenCols == 1)

        w.setInput("3", at: CellRef("D1")!); w.setInput("1", at: CellRef("D2")!); w.setInput("2", at: CellRef("D3")!)
        select("D1", to: "D3"); w.sortAscending(nil)
        check("sort", [cell("D1").value, cell("D2").value, cell("D3").value] == [.number(1), .number(2), .number(3)])

        w.setInput("=D1*2", at: CellRef("E1")!)
        select("E1", to: "E3"); w.fillDown(nil)
        check("fill down", cell("E3").input == "=D3*2" && cell("E3").value == .number(6), cell("E3").input)

        select("A5", to: "C5"); w.mergeAction(nil)
        check("merge", w.sheet.merges.contains(CellRange(CellRef("A5")!, CellRef("C5")!)))

        w.addSheet(nil)
        w.setInput("=Лист1!A3*2", at: CellRef("A1")!)
        check("cross-sheet ref (new sheet)", cell("A1").value == .number(60) || cell("A1").value == .error("#REF!"), "\(cell("A1").value)")

        let pdf = SheetExport.pdf(doc.workbook, activeSheet: 0, selection: nil, options: .init(), base: NSPrintInfo.shared)
        check("PDF export", pdf.count > 1000 && String(decoding: pdf.prefix(5), as: UTF8.self) == "%PDF-")
        let xlsx = XLSX.write(doc.workbook)
        let back = try? XLSX.read(xlsx)
        check("xlsx round trip", back?.sheets.count == 2 && back?.sheets[0].frozenRows == 1 && back?.sheets[0].merges.count == 1)

        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }
}
