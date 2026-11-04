import AppKit
import Kit42

/// Self-test of the function catalog, data validation, outline, protection, pivot tables and
/// find & replace, including .xlsx / .ods round trips. Returns the number of failures.
extension SelfTest {
    static func features() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func cell(_ input: String) -> Cell {
            var c = Cell()
            c.input = input
            c.value = input.hasPrefix("=") ? .empty : XLSX.constant(input)
            return c
        }

        // Function catalog: every entry is implemented, described and translated.
        let calc = Calculator(Workbook())
        let unknown = FunctionCatalog.all.filter { f in
            guard let e = try? Formula.parse("=\(f.name)()") else { return true }
            return calc.scalar(calc.eval(e, sheet: 0, at: CellRef(row: 0, col: 0)), at: CellRef(row: 0, col: 0)) == .error("#NAME?")
        }.map(\.name)
        check("catalog functions all implemented (\(FunctionCatalog.all.count))", unknown.isEmpty, "\(unknown)")
        let translated = Set(xls42Strings.map { $0[0] })
        let untranslated = FunctionCatalog.all.filter { !translated.contains($0.summary) }.map(\.name)
            + FunctionCatalog.Category.allCases.filter { !translated.contains($0.rawValue) }.map(\.rawValue)
        check("catalog descriptions translated", untranslated.isEmpty, "\(untranslated)")
        check("catalog has no duplicates", FunctionCatalog.byName.count == FunctionCatalog.all.count)
        let hint = FunctionCatalog.call(at: "=ROUND(SUM(A1;A2);")
        check("signature hint: function at caret", hint?.function.name == "ROUND" && hint?.argument == 1, "\(String(describing: hint))")
        check("signature hint: inner call", FunctionCatalog.call(at: "=IF(A1>0,SUM(B1,")?.function.name == "SUM")
        check("signature hint: Russian name", FunctionCatalog.call(at: "=СУММ(")?.function.name == "SUM")
        check("signature hint: after close", FunctionCatalog.call(at: "=SUM(A1)") == nil)
        let names = FunctionWizard.fieldNames(FunctionCatalog.byName["SUMIFS"]!)
        check("wizard expands repeating arguments", names.count >= 5 && names.contains("[criteria_range2]"), "\(names)")

        // Data validation rules
        var wb = Workbook()
        wb.sheets[0][CellRef("H1")!] = cell("Red")
        wb.sheets[0][CellRef("H2")!] = cell("Green")
        func rule(_ kind: DataValidation.Kind, _ op: String = "between", a: String, _ b: String = "") -> DataValidation {
            var v = DataValidation(ranges: [CellRange("A1:A10")!], kind: kind)
            v.op = op; v.formula1 = a; v.formula2 = b
            return v
        }
        let at = CellRef(row: 0, col: 0)
        let list = rule(.list, a: "\"Yes,No, Maybe\"")
        check("validation list literal", list.accepts(.string("no"), at: at, workbook: wb, sheet: 0) && list.accepts(.string("Maybe"), at: at, workbook: wb, sheet: 0)
              && !list.accepts(.string("Perhaps"), at: at, workbook: wb, sheet: 0))
        let listRange = rule(.list, a: "$H$1:$H$5")
        check("validation list from range", listRange.listItems(wb, sheet: 0) == ["Red", "Green"] && !listRange.accepts(.string("Blue"), at: at, workbook: wb, sheet: 0))
        let whole = rule(.whole, a: "1", "10")
        check("validation whole between", whole.accepts(.number(5), at: at, workbook: wb, sheet: 0) && !whole.accepts(.number(5.5), at: at, workbook: wb, sheet: 0)
              && !whole.accepts(.number(11), at: at, workbook: wb, sheet: 0) && !whole.accepts(.string("x"), at: at, workbook: wb, sheet: 0))
        let dec = rule(.decimal, "greaterThan", a: "0.5")
        check("validation decimal >", dec.accepts(.number(0.6), at: at, workbook: wb, sheet: 0) && !dec.accepts(.number(0.5), at: at, workbook: wb, sheet: 0))
        let date = rule(.date, a: Value.formatGeneral(DateMath.parse("01.01.2024")!), Value.formatGeneral(DateMath.parse("31.12.2024")!))
        check("validation date range", date.accepts(XLSX.constant("15.03.2024"), at: at, workbook: wb, sheet: 0) && !date.accepts(XLSX.constant("15.03.2025"), at: at, workbook: wb, sheet: 0))
        let len = rule(.textLength, "lessThanOrEqual", a: "3")
        check("validation text length", len.accepts(.string("abc"), at: at, workbook: wb, sheet: 0) && !len.accepts(.string("abcd"), at: at, workbook: wb, sheet: 0))
        check("range subtraction", CellRange("A1:C3")!.subtracting(CellRange("B2:B2")!).reduce(0) { $0 + $1.count } == 8)

        // Protection hashes (reference values from openpyxl.worksheet.protection.hash_password)
        check("legacy password hash", SheetProtection.legacyHash("test") == "CBEB" && SheetProtection.legacyHash("password") == "83AF"
              && SheetProtection.legacyHash("Пароль") == "A330", SheetProtection.legacyHash("test"))
        let prot = SheetProtection(password: "secret")
        check("protection password check", prot.matches("secret") && !prot.matches("Secret") && SheetProtection().matches(""))

        // Outline model
        var s = Sheet(name: "T")
        s.changeOutline(2...5, rows: true, by: 1)
        s.changeOutline(3...4, rows: true, by: 1)
        check("outline groups", s.outlineGroups(rows: true, level: 1) == [2...5] && s.outlineGroups(rows: true, level: 2) == [3...4] && s.maxRowLevel == 2)
        s.setCollapsed(3...4, rows: true, true)
        check("outline collapse hides rows", s.isRowHidden(3) && s.isRowHidden(4) && !s.isRowHidden(2) && s.isCollapsed(3...4, rows: true))
        s.showOutlineLevel(1, rows: true)
        check("outline level 1 hides all grouped rows", (2...5).allSatisfy { s.isRowHidden($0) } && !s.isRowHidden(6))
        s.showOutlineLevel(3, rows: true)
        check("outline level 3 shows all", !(2...5).contains { s.isRowHidden($0) })

        // Pivot table
        var p = Workbook()
        let data = [["Region", "Product", "Amount"], ["North", "A", "10"], ["South", "A", "5"], ["North", "B", "7"], ["North", "A", "3"]]
        for (r, row) in data.enumerated() { for (c, v) in row.enumerated() { p.sheets[0][CellRef(row: r, col: c)] = cell(v) } }
        check("pivot current region", Pivot.currentRegion(p.sheets[0], around: CellRef("B3")!) == CellRange("A1:C5"))
        let spec = PivotSpec(sourceSheet: p.sheets[0].name, source: CellRange("A1:C5")!, rowField: 0, colField: 1, valueField: 2, aggregate: .sum)
        if let pv = Pivot.build(spec, workbook: p, name: "P") {
            // Rows: header (0), column keys (1), North (2), South (3), Grand Total (4); columns: A, B, total.
            check("pivot cross table", pv[CellRef("A3")!].value == .string("North") && pv[CellRef("B3")!].value == .number(13) && pv[CellRef("C3")!].value == .number(7)
                  && pv[CellRef("D3")!].value == .number(20) && pv[CellRef("B5")!].value == .number(18) && pv[CellRef("D5")!].value == .number(25)
                  && pv[CellRef("D2")!].style.bold, "\(pv.cells.sorted { $0.key < $1.key }.map { "\($0.key.a1)=\($0.value.value.plain)" })")
        } else { check("pivot built", false) }
        var avg = spec
        avg.colField = nil
        avg.aggregate = .average
        let pa = Pivot.build(avg, workbook: p, name: "P2")
        check("pivot average without column field", pa?[CellRef("B2")!].value == .number(20.0 / 3) && pa?[CellRef("B4")!].value == .number(6.25)
              && pa?[CellRef("A4")!].value == .string(L("Grand Total")))

        // Find & replace options
        var o = FindOptions(text: "ab")
        check("find substring, case-insensitive", o.matches("xABy") && !o.matches("a b"))
        o.matchCase = true
        check("find match case", !o.matches("xABy") && o.matches("xaby"))
        o.entireCell = true
        check("find entire cell", !o.matches("xaby") && o.matches("ab"))
        var f = FindOptions(text: "A1", replacement: "B1")
        check("replace in formulas", f.replaced(cell("=A1*2")) == "=B1*2")
        f.inFormulas = false
        check("look in values skips formulas", f.replaced(cell("=A1*2")) == nil && f.replaced(cell("A1 x")) == "B1 x")

        // .xlsx and .ods round trips
        var rt = Workbook()
        rt.sheets[0][CellRef("A1")!] = cell("Yes")
        var unlocked = cell("free")
        unlocked.style.locked = false
        rt.sheets[0][CellRef("B2")!] = unlocked
        var v1 = DataValidation(ranges: [CellRange("A1:A10")!, CellRange("C1")!], kind: .list)
        v1.formula1 = "\"Yes,No\""
        v1.errorStyle = "warning"
        v1.errorTitle = "Pick"
        v1.errorMessage = "Yes or No"
        var v2 = DataValidation(ranges: [CellRange("D1:D5")!], kind: .whole)
        v2.formula1 = "1"; v2.formula2 = "10"
        var v3 = DataValidation(ranges: [CellRange("E1:E3")!], kind: .decimal)
        v3.op = "greaterThanOrEqual"; v3.formula1 = "2.5"
        var v4 = DataValidation(ranges: [CellRange("F1:F3")!], kind: .textLength)
        v4.op = "lessThan"; v4.formula1 = "5"
        var v5 = DataValidation(ranges: [CellRange("G1:G3")!], kind: .list)
        v5.formula1 = "$H$1:$H$5"
        rt.sheets[0].validations = [v1, v2, v3, v4, v5]
        rt.sheets[0].changeOutline(1...4, rows: true, by: 1)
        rt.sheets[0].changeOutline(2...3, rows: true, by: 1)
        rt.sheets[0].setCollapsed(2...3, rows: true, true)
        rt.sheets[0].changeOutline(5...6, rows: false, by: 1)
        rt.sheets[0].setCollapsed(5...6, rows: false, true)
        rt.sheets[0].protection = SheetProtection(password: "pw")
        for (format, data) in [("xlsx", XLSX.write(rt)), ("ods", ODS.write(rt))] {
            guard let back = try? SpreadsheetFile.read(data) else { check("\(format) reads back", false); continue }
            let b = back.sheets[0]
            let kinds = b.validations.map(\.kind)
            let list = b.validations.first { $0.kind == .list && $0.formula1.hasPrefix("\"") }
            check("\(format) validations round trip", kinds.count == 5 && Set(kinds) == [.list, .whole, .decimal, .textLength]
                  && list?.formula1 == "\"Yes,No\"" && list?.errorStyle == "warning" && list?.errorMessage == "Yes or No" && list?.errorTitle == "Pick"
                  && list?.ranges.contains(CellRange("A1:A10")!) == true
                  && b.validations.contains { $0.kind == .whole && $0.formula1 == "1" && $0.formula2 == "10" && $0.op == "between" }
                  && b.validations.contains { $0.kind == .decimal && $0.op == "greaterThanOrEqual" && $0.formula1 == "2.5" }
                  && b.validations.contains { $0.kind == .textLength && $0.op == "lessThan" && $0.formula1 == "5" }
                  && b.validations.contains { $0.kind == .list && $0.formula1.replacingOccurrences(of: "$", with: "") == "H1:H5" },
                  "\(b.validations.map { "\($0.kind) \($0.op) \($0.formula1) \($0.formula2) \($0.ranges.map(\.a1))" })")
            check("\(format) outline round trip", b.rowLevels == [1: 1, 2: 2, 3: 2, 4: 1] && b.outlineHiddenRows == [2, 3] && b.colLevels == [5: 1, 6: 1]
                  && b.outlineHiddenCols == [5, 6], "rows \(b.rowLevels) hidden \(b.outlineHiddenRows) cols \(b.colLevels) \(b.outlineHiddenCols)")
            check("\(format) protection round trip", b.protection?.matches("pw") == true && b.protection?.matches("nope") == false
                  && b[CellRef("B2")!].style.locked == false && b[CellRef("A1")!].style.locked, "\(String(describing: b.protection))")
        }
        return failed
    }
}
