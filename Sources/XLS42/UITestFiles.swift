import AppKit
import Kit42

/// UI tests of ⌘⇧Return array formulas, the Solver model and split window kept in the document, and document cell styles.
extension UITest {
    static func filesAndArrays(_ w: SheetWindowController, _ doc: SheetDocument) -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func ref(_ a1: String) -> CellRef { CellRef(a1)! }
        func cell(_ a1: String) -> Cell { w.sheet[ref(a1)] }
        func value(_ a1: String) -> String { SelfTest.display(cell(a1).value) }
        func select(_ a1: String, to b1: String? = nil) {
            w.grid.select(ref(a1))
            if let b1 { w.grid.select(ref(b1), extend: true) }
        }
        w.suppressAlerts = true
        w.addSheet(nil)
        for (i, v) in ["1", "2", "3"].enumerated() { w.setInput(v, at: CellRef(row: i, col: 0)) }

        // ⌘⇧Return in the cell editor: the formula goes over the selected range as one array formula.
        select("C1", to: "C3")
        w.grid.beginEdit(initial: "=A1:A3*10")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: w.window?.windowNumber ?? 0,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        let menu = MenuBar.build(Cmd.menuBar)
        var arrayItem: NSMenuItem?
        func find(_ m: NSMenu) { for i in m.items { if i.action == #selector(w.enterArrayAction(_:)) { arrayItem = i }; if let s = i.submenu { find(s) } } }
        find(menu)
        check("Edit menu: Enter Array Formula on ⌘⇧Return", arrayItem?.keyEquivalent == "\r" && arrayItem?.keyEquivalentModifierMask == [.command, .shift])
        // The key goes through the menu bar like a real key press when the window is key; otherwise the command itself.
        var viaKey = false
        if let event, w.window?.isKeyWindow == true, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { viaKey = true } else { w.enterArrayAction(nil) }
        check("⌘⇧Return enters an array formula over the selection" + (viaKey ? " (key press through the menu bar)" : ""), w.sheet.arrays[ref("C1")] == CellRange("C1:C3") && cell("C1").array && !w.grid.isEditing
              && [value("C1"), value("C2"), value("C3")] == ["10", "20", "30"], "\(w.sheet.arrays) \(value("C3"))")
        select("C2")
        check("formula bar shows {=…} in every cell of the array", w.formulaBarString == "{=A1:A3*10}", w.formulaBarString)
        w.setInput("5", at: ref("C2"))
        check("changing part of an array is refused", w.lastAlertMessage == SheetWindowController.partOfArrayMessage && value("C2") == "20")
        w.lastAlertMessage = nil
        select("C3"); w.clearContents(nil)
        check("clearing part of an array is refused", w.lastAlertMessage == SheetWindowController.partOfArrayMessage && value("C3") == "30")
        // Editing any cell of the array and ⌘⇧Return changes the whole array.
        select("C2")
        w.grid.beginEdit(initial: nil)
        check("editing a cell of the array starts with its formula", w.grid.editorText == "=A1:A3*10", w.grid.editorText)
        w.grid.setEditorText("=A1:A3+100")
        w.enterArrayAction(nil)
        check("⌘⇧Return re-enters the whole array", w.sheet.arrays[ref("C1")] == CellRange("C1:C3") && value("C3") == "103" && cell("C1").input == "=A1:A3+100", value("C3"))
        doc.undoManager?.undo()
        check("undo array edit", value("C3") == "30" && cell("C1").input == "=A1:A3*10")
        // Shorter results: #N/A; a scalar repeats.
        select("D1", to: "D4")
        w.grid.beginEdit(initial: "=A1:A3")
        w.enterArrayAction(nil)
        select("E1", to: "F2")
        w.grid.beginEdit(initial: "=7")
        w.enterArrayAction(nil)
        check("array result fitted to the range", value("D4") == "#N/A" && value("D3") == "3" && value("F2") == "7", "\(value("D4")) \(value("F2"))")
        let back = (try? XLSX.read(XLSX.write(doc.workbook))).map(Calculator.recalculate)
        check("array formulas saved as legacy arrays", back?.sheets[w.sheetIndex].arrays[ref("D1")] == CellRange("D1:D4") && back?.sheets[w.sheetIndex].arrays[ref("E1")] == CellRange("E1:F2"))
        select("C1", to: "C3"); w.clearContents(nil)
        check("clearing the whole array removes it", w.sheet.arrays[ref("C1")] == nil && value("C2").isEmpty && !cell("C1").array)

        // Solver: the model stays with the sheet and in the saved file.
        for (a, v) in [("H1", "0"), ("I1", "0"), ("J1", "=3*H1+5*I1"), ("K1", "=H1"), ("L1", "=2*I1"), ("M1", "=3*H1+2*I1")] { w.setInput(v, at: ref(a)) }
        var model = SolverModel(objective: ref("J1"), goal: .max, variables: [ref("H1"), ref("I1")])
        model.constraints = [.init(lhs: CellRange("K1")!, op: .le, rhs: "4"), .init(lhs: CellRange("L1")!, op: .le, rhs: "12"),
                             .init(lhs: CellRange("M1")!, op: .le, rhs: "18"), .init(lhs: CellRange("H1:I1")!, op: .int)]
        _ = w.solve(model)
        check("solver keeps the model with the sheet", w.sheet.solver == model && value("I1") == "6")
        doc.undoManager?.undo()
        check("undo solver restores values and model", w.sheet.solver == nil && value("I1") == "0")
        doc.undoManager?.redo()
        let saved = try? doc.data(ofType: "org.openxmlformats.spreadsheetml.sheet")
        var reread = saved.flatMap { try? XLSX.read($0) }?.sheets[w.sheetIndex].solver
        reread?.extra = [:]
        check("saved .xlsx keeps the solver model", reread == model, "\(String(describing: reread))")
        let odsSaved = try? doc.data(ofType: "org.oasis-open.opendocument.spreadsheet")
        reread = odsSaved.flatMap { try? ODS.read($0) }?.sheets[w.sheetIndex].solver
        reread?.extra = [:]
        check("saved .ods keeps the solver model", reread == model, "\(String(describing: reread))")

        // Split window: saved with the document, per sheet, restored.
        let splitSheet = w.sheetIndex
        if w.sheet.frozenRows > 0 || w.sheet.frozenCols > 0 { w.freezeAction(nil) }
        select("D10")
        w.toggleSplitAction(nil)
        let position = w.grid.split
        check("split stored in the sheet", w.sheet.split != nil && doc.isDocumentEdited, "\(String(describing: w.sheet.split))")
        let splitData = try? doc.data(ofType: "org.openxmlformats.spreadsheetml.sheet")
        let fileSplit = splitData.flatMap { try? XLSX.read($0) }?.sheets[splitSheet].split
        check("saved .xlsx keeps the split", fileSplit != nil && fileSplit == w.sheet.split, "\(String(describing: fileSplit)) vs \(String(describing: w.sheet.split))")
        let odsSplit = (try? doc.data(ofType: "org.oasis-open.opendocument.spreadsheet")).flatMap { try? ODS.read($0) }?.sheets[splitSheet].split
        check("saved .ods keeps the split", odsSplit == w.sheet.split, "\(String(describing: odsSplit))")
        w.selectSheet(0)
        check("other sheets have their own (no) split", w.grid.split == nil)
        w.selectSheet(splitSheet)
        check("split comes back with its sheet", w.grid.split == position, "\(String(describing: w.grid.split)) \(String(describing: position))")
        // As when a file opens: the saved split shows up in the window.
        doc.workbook.sheets[splitSheet].split = SheetSplit(x: 120, y: 45, topLeft: ref("A1"), bottomRight: ref("E30"))
        w.restoreSplit()
        check("split from the file restored", w.grid.split == NSPoint(x: 120 * w.grid.zoom, y: 45 * w.grid.zoom) && w.grid.cell(at: w.grid.fromViewport(NSPoint(x: 125 * w.grid.zoom, y: 50 * w.grid.zoom))).row >= 29,
              "\(String(describing: w.grid.split)) \(w.grid.cell(at: w.grid.fromViewport(NSPoint(x: 125, y: 50))))")
        w.toggleSplitAction(nil)
        check("remove split clears it in the sheet", w.grid.split == nil && w.sheet.split == nil)

        // Document cell styles (from LibreOffice files) in Format › Cell Styles.
        var heading = CellStyle.default
        heading.bold = true; heading.fontSize = 24; heading.styleName = "Heading"
        doc.workbook.cellStyles["Heading"] = heading
        check("document styles listed after the presets", w.documentStyleNames.contains("Heading") && !w.documentStyleNames.contains("Good"), "\(w.documentStyleNames)")
        if let sub = MenuBar.build(Cmd.menuBar).items.lazy.compactMap({ $0.submenu }).flatMap({ $0.items }).compactMap({ $0.submenu })
            .first(where: { $0.items.contains { $0.action == #selector(w.applyCellStyleAction(_:)) } }) {
            CellStyleMenu.install(in: sub.supermenu)
            check("Cell Styles menu has a delegate for document styles", sub.delegate === CellStyleMenu.shared)
        }
        select("N1", to: "N2")
        w.applyCellStyle(named: "Heading")
        check("document style applied by name", cell("N2").style.styleName == "Heading" && cell("N2").style.fontSize == 24 && cell("N1").style.bold)
        let item = NSMenuItem(title: "Heading", action: #selector(w.applyCellStyleAction(_:)), keyEquivalent: "")
        item.representedObject = "Heading"
        select("N1")
        check("its menu item is checked for the cell", w.validateMenuItem(item) && item.state == .on)
        w.lastAlertMessage = nil
        w.suppressAlerts = false
        return failed
    }
}
