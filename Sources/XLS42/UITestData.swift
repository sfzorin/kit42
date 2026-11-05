import AppKit
import Kit42

/// UI tests of the Calc-parity features: dynamic arrays in cells, sort/filter/subtotal commands, data tools,
/// goal seek and solver, sheet commands, hyperlinks, cell styles, Format Cells, split window, status bar and menus.
extension UITest {
    static func data(_ w: SheetWindowController, _ doc: SheetDocument) -> Int {
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
        func fill(_ rows: [[String]], at origin: CellRef = CellRef(row: 0, col: 0)) {
            doc.change("data") { wb in
                for (r, row) in rows.enumerated() {
                    for (c, v) in row.enumerated() where !v.isEmpty {
                        var cell = Cell()
                        cell.input = v
                        cell.value = v.hasPrefix("=") ? .empty : XLSX.constant(v)
                        wb.sheets[w.sheetIndex][CellRef(row: origin.row + r, col: origin.col + c)] = cell
                    }
                }
            }
        }
        w.suppressAlerts = true
        w.addSheet(nil)

        // Dynamic arrays spill in the grid; typing in the way gives #SPILL!; undo restores.
        w.setInput("=SEQUENCE(3,2,10)", at: ref("A1"))
        check("dynamic array spills into the grid", value("A1") == "10" && value("B3") == "15" && cell("B3").input.isEmpty, "\(value("B3"))")
        w.setInput("x", at: ref("A3"))
        check("blocked spill shows #SPILL!", value("A1") == "#SPILL!" && cell("B3").value.isEmpty, value("A1"))
        doc.undoManager?.undo()
        check("undo clears the block", value("A1") == "10" && value("A3") == "14")
        w.setInput("=SUM(A1:B3)", at: ref("D1"))
        check("formulas use spilled values", value("D1") == "75", value("D1"))
        select("A1", to: "B3"); w.copy(nil); select("F1"); w.paste(nil)
        check("copying a whole spill pastes the formula, which spills again", cell("F1").isFormula && cell("F2").input.isEmpty && value("G3") == "15", cell("F2").input)
        select("B2", to: "B3"); w.copy(nil); select("K1"); w.paste(nil)
        check("copying part of a spill pastes values", cell("K1").input == "13" && value("K2") == "15", cell("K1").input)
        w.setInput("=SORT({3;1;2})", at: ref("H1"))
        check("SORT of an array constant spills", value("H1") == "1" && value("H3") == "3")
        w.setInput("=FILTER(A1:A3,A1:A3>10)", at: ref("I1"))
        check("FILTER spills the matching rows", value("I1") == "12" && value("I2") == "14", value("I1"))

        // Sort dialog core: two keys, header, formulas follow their rows; undo.
        w.addSheet(nil)
        fill([["Name", "Dept", "Pay", "Twice"], ["Bob", "B", "30", "=C2*2"], ["Amy", "A", "50", "=C3*2"], ["Cid", "A", "20", "=C4*2"]])
        select("A1")
        check("current region around the active cell", w.currentRegion() == CellRange("A1:D4"), "\(w.currentRegion())")
        w.applySort(CellRange("A1:D4")!, keys: [.init(index: 1), .init(index: 2, ascending: false)], options: .init())
        check("sort by department then pay", [value("A2"), value("A3"), value("A4")] == ["Amy", "Cid", "Bob"] && value("D2") == "100",
              "\([value("A2"), value("A3"), value("A4")])")
        doc.undoManager?.undo()
        check("undo sort", value("A2") == "Bob")

        // Standard filter (in place, then copy), reset.
        w.applyStandardFilter(CellRange("A1:D4")!, criteria: [.init(field: 2, condition: .init(op: .greaterThan, value: "25"))],
                              caseSensitive: false, unique: false, header: true, copyTo: nil)
        check("standard filter hides rows", w.sheet.filterHidden == [3] && w.sheet.isRowHidden(3) && w.sheet.autoFilter == CellRange("A1:D4"))
        w.resetFilterAction(nil)
        check("reset filter", w.sheet.filterHidden.isEmpty && w.sheet.customFilters.isEmpty)
        w.applyStandardFilter(CellRange("A1:D4")!, criteria: [.init(field: 1, condition: .init(op: .equal, value: "A"))],
                              caseSensitive: false, unique: false, header: true, copyTo: (w.sheetIndex, ref("F1")))
        check("standard filter copies results", value("F1") == "Name" && value("F2") == "Amy" && value("F3") == "Cid" && value("F4").isEmpty)
        fill([["Dept"], ["B"]], at: ref("K1"))
        w.applyAdvancedFilter(CellRange("A1:D4")!, criteria: (w.sheetIndex, CellRange("K1:K2")!), unique: false, copyTo: nil)
        check("advanced filter from a criteria range", w.sheet.filterHidden == [2, 3], "\(w.sheet.filterHidden.sorted())")
        w.resetFilterAction(nil)

        // Subtotals with outline; remove all.
        w.addSheet(nil)
        fill([["Region", "Sales"], ["East", "10"], ["East", "20"], ["West", "5"], ["West", "7"]])
        w.applySubtotals(CellRange("A1:B5")!, groupBy: 0, function: 9, columns: [1], replace: true, pageBreaks: false)
        check("subtotals rows and grand total", value("B4") == "30" && value("B7") == "12" && value("B8") == "42" && w.sheet.maxRowLevel == 2,
              "\((1...8).map { value("B\($0)") })")
        w.showOutlineLevel(2, rows: true)
        check("subtotal outline collapses to the totals", w.sheet.isRowHidden(1) && !w.sheet.isRowHidden(3) && !w.sheet.isRowHidden(7))
        w.showOutlineLevel(3, rows: true)
        w.removeSubtotals(CellRange("A1:B8")!)
        check("remove all subtotals", value("B5") == "7" && value("A6").isEmpty && w.sheet.maxRowLevel == 0, "\((1...6).map { value("B\($0)") })")

        // Remove duplicates, text to columns, fill up/left, series.
        w.addSheet(nil)
        fill([["k", "v"], ["a", "1"], ["b", "2"], ["a", "3"]])
        check("remove duplicates by a column", w.applyRemoveDuplicates(CellRange("A1:B4")!, columns: [0], header: true) == 1 && value("B3") == "2" && value("A4").isEmpty)
        w.setInput("x,1,2024-03-15", at: ref("D1"))
        w.applyTextToColumns(CellRange("D1")!, options: .init(delimiters: [","], types: [.general, .general, .dateYMD]))
        check("text to columns", value("E1") == "1" && NumberFormat.format(cell("F1").value, "dd.mm.yyyy").text == "15.03.2024")
        w.setInput("=B4+1", at: ref("H4"))
        w.applyFill(CellRange("H1:H4")!, .up)
        check("fill up", cell("H1").input == "=B1+1")
        w.setInput("7", at: ref("J5"))
        w.applyFill(CellRange("H5:J5")!, .left)
        check("fill left", value("H5") == "7")
        w.setInput("2", at: ref("A10"))
        w.applySeries(CellRange("A10:E10")!, direction: .right, type: .growth, unit: .day, step: 3, stop: 100)
        check("fill series growth with stop", value("D10") == "54" && value("E10").isEmpty, value("E10"))

        // Goal seek and solver write the variables (undoable).
        w.setInput("1", at: ref("A12")); w.setInput("=A12^3-10", at: ref("B12"))
        let root = w.goalSeek(formula: ref("B12"), target: 17, variable: ref("A12"))
        check("goal seek sets the variable", root.map { abs($0 - 3) < 1e-7 } ?? false && value("A12") == "3", value("A12"))
        doc.undoManager?.undo()
        check("undo goal seek", value("A12") == "1")
        fill([["0", "0", "=3*A14+5*B14", "=A14", "=2*B14", "=3*A14+2*B14"]], at: ref("A14"))
        var model = SolverModel(objective: ref("C14"), goal: .max, variables: [ref("A14"), ref("B14")])
        model.constraints = [.init(lhs: CellRange("D14")!, op: .le, rhs: "4"), .init(lhs: CellRange("E14")!, op: .le, rhs: "12"),
                             .init(lhs: CellRange("F14")!, op: .le, rhs: "18")]
        let solved = w.solve(model)
        check("solver writes the optimum", solved?.status == .optimal && value("A14") == "2" && value("B14") == "6" && value("C14") == "36",
              "\(value("A14")) \(value("B14"))")

        // Statistics on a new sheet.
        let statsFrom = w.sheetIndex, statsName = w.sheet.name
        func statsSheet() -> Int { doc.workbook.sheetIndex(named: statsName) ?? 0 }
        fill([["x", "y"], ["1", "2"], ["2", "4.1"], ["3", "5.9"]], at: ref("A20"))
        w.applyStatistics((statsFrom, CellRange("A20:B23")!), byRows: false, labels: true, correlation: false)
        check("descriptive statistics sheet", w.sheetIndex == statsFrom + 1 && value("B2") == "2" && value("A2") == L("Mean") && value("C14") == "3",
              "\(value("B2")) \(value("C14"))")
        w.selectSheet(statsFrom)
        w.applyStatistics((statsFrom, CellRange("A20:B23")!), byRows: false, labels: true, correlation: true)
        check("correlation matrix", value("B2") == "1" && (Double(value("B3")) ?? 0) > 0.99, value("B3"))

        // Sheets: tab colour, move/copy, hide/show, structure protection.
        let names = doc.workbook.sheets.map(\.name)
        w.setTabColor(.systemRed, sheet: 0)
        check("tab colour", doc.workbook.sheets[0].tabColor != nil)
        w.moveSheet(0, before: doc.workbook.sheets.count, copy: false)
        check("move sheet to the end", doc.workbook.sheets.last?.name == names[0] && w.sheet.name == names[0])
        doc.undoManager?.undo()
        check("undo move sheet", doc.workbook.sheets.map(\.name) == names)
        w.moveSheet(1, before: 0, copy: true, name: "Copied")
        check("copy sheet with a new name", doc.workbook.sheets[0].name == "Copied" && doc.workbook.sheets.count == names.count + 1)
        let copiedIndex = 0
        w.selectSheet(copiedIndex)
        w.hideSheet(copiedIndex)
        check("hide sheet switches to a visible one", doc.workbook.sheets[copiedIndex].hidden && w.sheetIndex != copiedIndex && !w.visibleSheets.contains(copiedIndex))
        w.showSheet(copiedIndex)
        check("show sheet", !doc.workbook.sheets[copiedIndex].hidden && w.sheetIndex == copiedIndex)
        w.protectWorkbookAction(nil)
        let before = doc.workbook.sheets.count
        w.addSheet(nil)
        check("protected workbook structure blocks new sheets", doc.workbook.sheets.count == before && w.lastAlertMessage == L("The workbook structure is protected"))
        w.protectWorkbookAction(nil)

        // Hyperlinks: set, style, open a place in the workbook, HYPERLINK().
        w.selectSheet(statsSheet())
        w.setHyperlink("example.com", text: "Site", at: ref("M1"))
        check("hyperlink with text and style", w.sheet.hyperlinks[ref("M1")] == "https://example.com" && value("M1") == "Site" && cell("M1").style.styleName == "Hyperlink")
        let target = Formula.sheetPrefix(doc.workbook.sheets[copiedIndex].name)
        w.setHyperlink("#\(target)B2", text: "Go", at: ref("M2"))
        w.openHyperlink(w.hyperlinkTarget(at: ref("M2"))!)
        check("internal hyperlink selects the place", w.sheetIndex == copiedIndex && w.grid.active == ref("B2"))
        w.selectSheet(statsSheet())
        w.setInput("=HYPERLINK(\"https://\"&\"apple.com\",\"Apple\")", at: ref("M3"))
        check("HYPERLINK() shows its text and is clickable", value("M3") == "Apple" && w.hyperlinkTarget(at: ref("M3")) == "https://apple.com")
        w.setHyperlink(nil, text: nil, at: ref("M1"))
        check("remove hyperlink", w.sheet.hyperlinks[ref("M1")] == nil && cell("M1").style.styleName == nil)

        // Cell styles and Format Cells.
        select("N1", to: "N2")
        w.applyCellStyle(CellStyles.presets.first { $0.name == "Bad" }!)
        check("cell style applied to the selection", cell("N2").style.styleName == "Bad" && cell("N2").style.fill != nil)
        var initial = FormatCellsState(cell("N1").style)
        var state = initial
        state.numberFormat = "0.0%"; state.rotation = 30; state.shrink = true; state.bold = true
        state.left = true; state.right = true; state.top = true; state.bottom = true; state.innerH = true; state.borderStyle = "dashed"
        w.applyFormatCells(state, from: initial, range: CellRange("N1:N2")!)
        let n1 = cell("N1").style, n2 = cell("N2").style
        check("format cells: number, rotation, shrink, bold", n1.numberFormat == "0.0%" && n1.rotation == 30 && n2.shrink && n2.bold && n2.fill != nil)
        check("format cells: outer and inner borders", n1.top?.style == "dashed" && n1.bottom?.style == "dashed" && n2.top?.style == "dashed" && n2.bottom != nil && n1.left != nil)
        initial = FormatCellsState(cell("N1").style)
        state = initial
        state.fill = nil; state.locked = false; state.hiddenFormula = true
        w.applyFormatCells(state, from: initial, range: CellRange("N1:N2")!)
        check("format cells: background, protection, untouched rest", cell("N2").style.fill == nil && !cell("N2").style.locked && cell("N2").style.hiddenFormula
              && cell("N2").style.numberFormat == "0.0%")

        // Split window: four panes, panes map clicks, freeze removed.
        w.freezeTopRowAction(nil)
        select("D10")
        w.toggleSplitAction(nil)
        check("split window at the active cell", w.grid.split != nil && w.sheet.frozenRows == 0)
        if let s = w.grid.split {
            let p = w.grid.fromViewport(NSPoint(x: s.x / 2, y: s.y / 2))
            check("split panes map points back to the grid", w.grid.cell(at: p).row < 9, "\(w.grid.cell(at: p))")
        }
        w.grid.splitScroll = NSPoint(x: 0, y: 200)
        check("top pane scrolls on its own", w.grid.fromViewport(NSPoint(x: 5, y: 5)).y == 205)
        w.toggleSplitAction(nil)
        check("remove split", w.grid.split == nil && w.grid.frozenHeight == 0)

        // Status bar: statistics, hiding, Hide All Panels, zoom slider.
        w.selectSheet(statsSheet())
        select("A20", to: "B23")
        check("status bar shows sum, average, count", w.statusBarText.contains(NumberFormat.general(18)) && w.statusBarText.contains("8"), w.statusBarText)
        w.toggleStatusBarAction(nil)
        check("hide status bar", w.statusBarHidden)
        w.toggleStatusBarAction(nil)
        w.toggleAllPanelsAction(nil)
        check("Hide All Panels hides the status bar", w.statusBarHidden)
        w.toggleAllPanelsAction(nil)
        check("Show All Panels brings it back", !w.statusBarHidden)
        w.zoomSlider.doubleValue = 150
        w.zoomSliderChanged(w.zoomSlider)
        check("zoom slider zooms", abs(w.grid.zoom - 1.5) < 0.001 && w.zoomLabel.stringValue == "150%")
        w.actualSizeAction(nil)
        check("zoom commands move the slider", w.zoomSlider.doubleValue == 100)

        // Every new command is in the menus and validates.
        let menu = MenuBar.build(Cmd.menuBar)
        var actions = Set<Selector>()
        func walk(_ m: NSMenu) { for item in m.items { if let a = item.action { actions.insert(a) }; if let s = item.submenu { walk(s) } } }
        walk(menu)
        let wanted: [Selector] = [#selector(w.sortDialogAction(_:)), #selector(w.standardFilterAction(_:)), #selector(w.advancedFilterAction(_:)),
                                  #selector(w.subtotalsAction(_:)), #selector(w.textToColumnsAction(_:)), #selector(w.removeDuplicatesAction(_:)),
                                  #selector(w.descriptiveStatisticsAction(_:)), #selector(w.goalSeekAction(_:)), #selector(w.solverAction(_:)),
                                  #selector(w.moveCopySheetAction(_:)), #selector(w.tabColorAction(_:)), #selector(w.hideSheetAction(_:)),
                                  #selector(w.showSheetAction(_:)), #selector(w.toggleSplitAction(_:)), #selector(w.toggleStatusBarAction(_:)),
                                  #selector(w.insertHyperlinkAction(_:)), #selector(w.formatCellsAction(_:)), #selector(w.applyCellStyleAction(_:)),
                                  #selector(w.fillSeriesAction(_:)), #selector(w.fillUpAction(_:)), #selector(w.fillLeftAction(_:))]
        let missing = wanted.filter { !actions.contains($0) }.map(NSStringFromSelector)
        check("menus contain the new commands", missing.isEmpty, "\(missing)")
        var invalid: [String] = []
        func validate(_ m: NSMenu) {
            for item in m.items {
                if let a = item.action, w.responds(to: a) { _ = w.validateMenuItem(item) } else if item.action == nil && item.submenu == nil && !item.isSeparatorItem { invalid.append(item.title) }
                if let s = item.submenu { validate(s) }
            }
        }
        validate(menu)
        check("menu items validate", true)
        w.suppressAlerts = false
        return failed
    }
}
