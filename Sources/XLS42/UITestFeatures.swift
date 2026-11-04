import AppKit
import Kit42

/// UI tests of the function wizard, validation, protection, grouping, find & replace,
/// paste special and pivot tables, driven through the window controller.
extension UITest {
    static func features(_ w: SheetWindowController, _ doc: SheetDocument) -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func ref(_ a1: String) -> CellRef { CellRef(a1)! }
        func cell(_ a1: String) -> Cell { w.sheet[ref(a1)] }
        func select(_ a1: String, to b1: String? = nil) {
            w.grid.select(ref(a1))
            if let b1 { w.grid.select(ref(b1), extend: true) }
        }
        w.suppressAlerts = true
        w.addSheet(nil)
        let featureSheet = w.sheetIndex

        // Function wizard
        w.setInput("2.345", at: ref("A1"))
        let wizard = FunctionWizard(initial: nil)
        wizard.evaluate = { w.previewFormula($0) }
        wizard.filter("round")
        check("wizard search", wizard.shown.first?.name == "ROUND" && wizard.shown.contains { $0.name == "ROUNDUP" }, "\(wizard.shown.map(\.name))")
        wizard.filter("")
        check("wizard lists every function", wizard.shown.count == FunctionCatalog.all.count)
        wizard.filter("ОКРУГЛ")
        check("wizard finds Russian names", wizard.shown.first?.name == "ROUND", "\(wizard.shown.map(\.name))")
        wizard.select(FunctionCatalog.byName["ROUND"]!)
        wizard.setArguments(["A1", "2"])
        check("wizard builds formula", wizard.formula == "=ROUND(A1;2)", wizard.formula)
        check("wizard live preview", w.previewFormula(wizard.formula) == NumberFormat.format(.number(2.35), "General").text, w.previewFormula(wizard.formula))
        select("B1")
        w.insertFunction(wizard.formula, editing: nil)
        check("wizard inserts into cell", cell("B1").input == "=ROUND(A1,2)" && cell("B1").value == .number(2.35), "\(cell("B1"))")
        select("C1")
        w.grid.beginEdit(initial: "=1+")
        w.insertFunction("=ABS(-2)", editing: "=1+")
        check("wizard inserts at the caret while editing", w.grid.editorText == "=1+ABS(-2)", w.grid.editorText)
        w.grid.commitEdit(move: nil)
        check("inserted formula evaluates", cell("C1").value == .number(3), "\(cell("C1"))")
        select("C2")
        w.grid.beginEdit(initial: "=+5")
        w.grid.savedCaret = NSRange(location: 1, length: 0)
        w.insertFunction("=PI()", editing: "=+5")
        check("wizard inserts at a saved caret", w.grid.editorText == "=PI()+5", w.grid.editorText)
        w.grid.cancelEdit()
        let prefilled = FunctionWizard(initial: "=ROUND(A1,2)")
        check("wizard prefills from the cell", prefilled.selected?.name == "ROUND" && prefilled.formula == "=ROUND(A1;2)", prefilled.formula)

        // Data validation
        var whole = DataValidation(ranges: [CellRange("D1:D5")!], kind: .whole)
        whole.formula1 = "1"; whole.formula2 = "10"
        w.setValidation(whole, for: CellRange("D1:D5")!)
        w.setInput("5", at: ref("D1"))
        w.lastAlertMessage = nil
        w.setInput("50", at: ref("D2"))
        check("validation accepts a valid number", cell("D1").value == .number(5))
        check("validation stop rejects", cell("D2").input.isEmpty && w.lastAlertMessage != nil, "\(cell("D2"))")
        var list = DataValidation(ranges: [CellRange("E1:E3")!], kind: .list)
        list.formula1 = "\"a,b\""
        list.errorStyle = "warning"
        w.setValidation(list, for: CellRange("E1:E3")!)
        w.setInput("c", at: ref("E1"))
        check("validation warning lets the value through", cell("E1").input == "c")
        select("E2")
        check("list dropdown arrow on the active cell", w.grid.hasListDropdown(ref("E2")) && !w.grid.hasListDropdown(ref("D1")))
        select("E1", to: "E3")
        w.clearValidationAction(nil)
        check("clear validation", w.sheet.validation(at: ref("E2")) == nil && w.sheet.validation(at: ref("D2")) != nil)
        doc.undoManager?.undo()
        check("undo clear validation", w.sheet.validation(at: ref("E2")) != nil)

        // Sheet protection
        select("F1")
        w.toggleLockedAction(nil)
        check("unlock cell", !cell("F1").style.locked && cell("A1").style.locked)
        w.protectSheet(password: "pw")
        w.lastAlertMessage = nil
        w.setInput("x", at: ref("A2"))
        check("protected: locked cell refused", cell("A2").input.isEmpty && w.lastAlertMessage != nil)
        w.setInput("ok", at: ref("F1"))
        check("protected: unlocked cell editable", cell("F1").input == "ok")
        select("A1"); w.clearContents(nil)
        check("protected: clear refused", cell("A1").value == .number(2.345))
        w.grid.beginEdit(initial: "z")
        check("protected: editor does not open", !w.grid.isEditing)
        w.insertRowsAction(nil)
        check("protected: insert rows refused", cell("A1").value == .number(2.345))
        check("unprotect with wrong password fails", !w.unprotectSheet(password: "bad") && w.sheet.isProtected)
        check("unprotect", w.unprotectSheet(password: "pw") && !w.sheet.isProtected)

        // Grouping (outline)
        select("A3", to: "A5")
        w.groupAction(nil)
        check("group rows", w.sheet.rowLevels == [2: 1, 3: 1, 4: 1], "\(w.sheet.rowLevels)")
        w.toggleOutline(2...4, rows: true)
        check("collapse group hides rows", (2...4).allSatisfy { w.sheet.isRowHidden($0) } && !w.sheet.isRowHidden(5))
        doc.undoManager?.undo()
        check("undo collapse", !w.sheet.isRowHidden(3))
        w.group(2...4, rows: true, by: -1)
        check("ungroup", w.sheet.rowLevels.isEmpty)
        w.group(1...2, rows: false, by: 1)
        w.toggleOutline(1...2, rows: false)
        check("group and collapse columns", w.sheet.isColumnHidden(1) && w.sheet.isColumnHidden(2) && !w.sheet.isColumnHidden(3))
        w.expandAllAction(nil)
        check("expand all", !w.sheet.isColumnHidden(1))

        // Find & replace
        w.setInput("apple pie", at: ref("G1"))
        w.setInput("Apple", at: ref("G2"))
        doc.change("seed") { var c = Cell(); c.input = "apple"; c.value = .string("apple"); $0.sheets[0][CellRef("Z50")!] = c }
        var o = FindOptions(text: "apple", replacement: "pear", workbook: true)
        select("A1")
        w.findNext(o)
        check("find next", w.grid.active == ref("G1") && w.sheetIndex == featureSheet, w.grid.active.a1)
        let replaced = w.replaceAll(o)
        check("replace all in workbook", replaced == 3 && cell("G1").input == "pear pie" && cell("G2").input == "pear"
              && doc.workbook.sheets[0][ref("Z50")].input == "pear", "\(replaced)")
        doc.undoManager?.undo()
        check("replace all is one undo step", cell("G1").input == "apple pie" && cell("G2").input == "Apple" && doc.workbook.sheets[0][ref("Z50")].input == "apple")
        o.workbook = false
        o.matchCase = true
        select("A1")
        w.replaceCurrent(o)   // A1 doesn't match: just moves to G1
        w.replaceCurrent(o)   // replaces G1, moves on
        check("replace current", cell("G1").input == "pear pie" && cell("G2").input == "Apple", "\(cell("G1").input)")

        // Paste special
        w.setInput("1", at: ref("H1")); w.setInput("2", at: ref("H2")); w.setInput("=H1*10", at: ref("I1"))
        select("H1", to: "I2"); w.copy(nil)
        select("K1"); w.pasteSpecial(.values, operation: .none, skipBlanks: false, transpose: true)
        check("paste values transposed", cell("K1").value == .number(1) && cell("L1").value == .number(2) && cell("K2").value == .number(10)
              && !cell("K2").isFormula, "\(cell("K2"))")
        w.setInput("5", at: ref("N1")); w.setInput("5", at: ref("N2"))
        select("H1", to: "H2"); w.copy(nil)
        select("N1"); w.pasteSpecial(.values, operation: .add, skipBlanks: false, transpose: false)
        check("paste special add", cell("N1").value == .number(6) && cell("N2").value == .number(7), "\(cell("N1").value) \(cell("N2").value)")
        doc.undoManager?.undo()
        check("paste special undo", cell("N1").value == .number(5) && cell("N2").value == .number(5))
        w.setInput("9", at: ref("P1")); w.setInput("9", at: ref("P2")); w.setInput("9", at: ref("P3"))
        w.setInput("4", at: ref("J1")); w.setInput("4", at: ref("J3"))
        select("J1", to: "J3"); w.copy(nil)
        select("P1"); w.pasteSpecial(.values, operation: .none, skipBlanks: true, transpose: false)
        check("paste skip blanks", cell("P1").value == .number(4) && cell("P2").value == .number(9) && cell("P3").value == .number(4))
        select("I1"); w.copy(nil)
        select("R5"); w.pasteSpecial(.formulas, operation: .multiply, skipBlanks: false, transpose: false)
        check("paste formulas with operation", cell("R5").input == "=(0)*(R5*10)" || cell("R5").isFormula, cell("R5").input)
        select("H1"); w.toggleBold(nil); w.copy(nil)
        w.setInput("x", at: ref("Q1"))
        select("Q1"); w.pasteSpecial(.formats, operation: .none, skipBlanks: false, transpose: false)
        check("paste formats only", cell("Q1").style.bold && cell("Q1").input == "x")

        // Pivot table
        w.addSheet(nil)
        let rows = [["Region", "Product", "Amount"], ["North", "A", "10"], ["South", "A", "5"], ["North", "B", "7"]]
        for (r, row) in rows.enumerated() { for (c, v) in row.enumerated() { w.setInput(v, at: CellRef(row: r, col: c)) } }
        let count = doc.workbook.sheets.count
        let source = w.sheet.name
        w.createPivot(PivotSpec(sourceSheet: source, source: CellRange("A1:C4")!, rowField: 0, colField: nil, valueField: 2, aggregate: .sum))
        check("pivot on a new sheet", doc.workbook.sheets.count == count + 1 && w.sheet.pivot != nil
              && cell("A2").value == .string("North") && cell("B2").value == .number(17) && cell("B4").value == .number(22) && cell("A1").style.bold,
              "\(w.sheet.cells.sorted { $0.key < $1.key }.map { "\($0.key.a1)=\($0.value.value.plain)" })")
        doc.change("edit source") { wb in
            let si = wb.sheetIndex(named: source)!
            var c = Cell(); c.input = "100"; c.value = .number(100)
            wb.sheets[si][CellRef("C3")!] = c
        }
        w.refreshPivotAction(nil)
        check("refresh pivot", cell("B3").value == .number(100) && cell("B4").value == .number(117), "\(cell("B3").value)")

        // The new features survive saving through the document.
        if let data = try? doc.data(ofType: "org.openxmlformats.spreadsheetml.sheet"), let back = try? XLSX.read(data) {
            let s = back.sheets[featureSheet]
            check("document saves validation and locks", s.validations.count == 2 && s[CellRef("F1")!].style.locked == false, "\(s.validations.count)")
        } else { check("document saves", false) }
        w.suppressAlerts = false
        return failed
    }
}
