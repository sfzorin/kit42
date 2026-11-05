import AppKit
import Kit42

/// Self-test of the data tools: sort, filters, subtotals, duplicates, text to columns, series, goal seek, solver.
extension SelfTest {
    static func dataTools() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func book(_ rows: [[String]]) -> Workbook {
            var wb = Workbook()
            for (r, row) in rows.enumerated() {
                for (c, v) in row.enumerated() where !v.isEmpty {
                    var cell = Cell()
                    cell.input = v
                    cell.value = v.hasPrefix("=") ? .empty : XLSX.constant(v)
                    wb.sheets[0][CellRef(row: r, col: c)] = cell
                }
            }
            return Calculator.recalculate(wb)
        }
        func col(_ wb: Workbook, _ c: Int, _ rows: ClosedRange<Int>) -> [String] {
            rows.map { wb.sheets[0][CellRef(row: $0, col: c)].value.plain }
        }

        // Sort: header detection, two keys, formulas keep their row-relative references.
        var wb = book([["Name", "Dept", "Pay", "Double"], ["Bob", "B", "30", "=C2*2"], ["amy", "A", "50", "=C3*2"],
                       ["Cid", "A", "20", "=C4*2"], ["Dan", "B", "30", "=C5*2"], ["", "", "", ""]])
        let range = CellRange("A1:D5")!
        check("sort: header detected", DataTools.detectHeader(wb.sheets[0], range))
        DataTools.sort(&wb, sheet: 0, range: range, keys: [.init(index: 1), .init(index: 2, ascending: false)], options: .init())
        wb = Calculator.recalculate(wb)
        check("sort by two keys", col(wb, 0, 1...4) == ["amy", "Cid", "Bob", "Dan"], "\(col(wb, 0, 1...4))")
        check("sort keeps formulas on their rows", wb.sheets[0][CellRef("D2")!].input == "=C2*2" && col(wb, 3, 1...4) == ["100", "40", "60", "60"],
              "\(wb.sheets[0][CellRef("D2")!].input) \(col(wb, 3, 1...4))")
        var ci = book([["b"], ["B"], ["a"], ["A"], ["x10"], ["x9"]])
        DataTools.sort(&ci, sheet: 0, range: CellRange("A1:A6")!, keys: [.init(index: 0)], options: .init(header: false, caseSensitive: true, natural: true))
        check("sort case-sensitive, natural order", col(ci, 0, 0...5) == ["a", "A", "b", "B", "x9", "x10"], "\(col(ci, 0, 0...5))")
        var days = book([["Wed"], ["Mon"], ["Sun"], ["Fri"]])
        DataTools.sort(&days, sheet: 0, range: CellRange("A1:A4")!, keys: [.init(index: 0)], options: .init(header: false, customList: DataTools.builtinLists[0]))
        check("sort by a custom list (weekdays)", col(days, 0, 0...3) == ["Sun", "Mon", "Wed", "Fri"], "\(col(days, 0, 0...3))")
        var ltr = book([["3", "1", "2"], ["c", "a", "b"]])
        DataTools.sort(&ltr, sheet: 0, range: CellRange("A1:C2")!, keys: [.init(index: 0)], options: .init(header: false, leftToRight: true))
        check("sort left to right", ltr.sheets[0][CellRef("A2")!].value == .string("a") && ltr.sheets[0][CellRef("C1")!].value == .number(3))
        var blanks = book([["2"], [""], ["1"], ["3"]])
        DataTools.sort(&blanks, sheet: 0, range: CellRange("A1:A4")!, keys: [.init(index: 0, ascending: false)], options: .init(header: false))
        check("sort keeps blanks last when descending", col(blanks, 0, 0...3) == ["3", "2", "1", ""], "\(col(blanks, 0, 0...3))")

        // Standard filter: conditions, AND/OR, no duplicates, copy results.
        var f = book([["Item", "Qty", "Region"], ["pen", "5", "North"], ["pencil", "12", "South"], ["paper", "40", "North"],
                      ["pen", "5", "North"], ["ink", "", "East"], ["eraser", "8", "South"]])
        let list = CellRange("A1:C7")!
        let calc = Calculator(f)
        let gt = DataTools.passingRows(f.sheets[0], range: list, criteria: [.init(field: 1, condition: .init(op: .greaterThan, value: "6"))],
                                       caseSensitive: false, header: true, calc: calc)
        check("filter greater than", gt == [2, 3, 6], "\(gt)")
        let andOr = DataTools.passingRows(f.sheets[0], range: list, criteria: [
            .init(field: 2, condition: .init(op: .equal, value: "north")), .init(field: 1, condition: .init(op: .lessThan, value: "10")),
            .init(field: 0, condition: .init(op: .beginsWith, value: "er"), or: true)], caseSensitive: false, header: true, calc: calc)
        check("filter (A AND B) OR C", andOr == [1, 4, 6], "\(andOr)")
        let ops: [(FilterCondition.Op, String, [Int])] = [(.contains, "pen", [1, 2, 4]), (.endsWith, "r", [3, 6]), (.top, "2", [2, 3]),
                                                           (.bottom, "1", [1, 4]), (.empty, "", [5]), (.notEmpty, "", [1, 2, 3, 4, 6]),
                                                           (.notEqual, "pen", [2, 3, 5, 6]), (.equal, "p*r", [3]), (.topPercent, "40", [2, 3])]
        for (op, v, expected) in ops {
            let field = [.top, .bottom, .empty, .notEmpty, .topPercent].contains(op) ? 1 : 0
            let got = DataTools.passingRows(f.sheets[0], range: list, criteria: [.init(field: field, condition: .init(op: op, value: v))], caseSensitive: false, header: true, calc: calc)
            check("filter \(op.rawValue) \(v)", got == expected, "\(got)")
        }
        DataTools.standardFilter(&f, sheet: 0, range: list, criteria: [.init(field: 2, condition: .init(op: .equal, value: "North"))],
                                 caseSensitive: false, unique: true, header: true, copyTo: (0, CellRef("E1")!))
        check("standard filter copies unique results", col(f, 4, 0...3) == ["Item", "pen", "paper", ""], "\(col(f, 4, 0...3))")
        DataTools.standardFilter(&f, sheet: 0, range: list, criteria: [.init(field: 1, condition: .init(op: .greaterThanOrEqual, value: "8")),
                                                                       .init(field: 1, condition: .init(op: .lessThan, value: "20"))],
                                 caseSensitive: false, unique: false, header: true, copyTo: nil)
        check("standard filter hides rows, kept as AutoFilter conditions", f.sheets[0].filterHidden == [1, 3, 4, 5]
              && f.sheets[0].customFilters[1]?.conditions.count == 2 && f.sheets[0].autoFilter == list, "\(f.sheets[0].filterHidden.sorted())")
        let back = (try? XLSX.read(XLSX.write(f)))?.sheets[0]
        check("filter conditions round trip in .xlsx", back?.customFilters[1] == f.sheets[0].customFilters[1] && back?.filterHidden == f.sheets[0].filterHidden,
              "\(String(describing: back?.customFilters))")
        let odsBack = (try? ODS.read(ODS.write(f)))?.sheets[0]
        check("filter conditions round trip in .ods", odsBack?.customFilters[1] == f.sheets[0].customFilters[1] && odsBack?.filterHidden == f.sheets[0].filterHidden
              && odsBack?.autoFilter == list, "\(String(describing: odsBack?.customFilters)) \(String(describing: odsBack?.filterHidden))")
        var values = f
        values.sheets[0].customFilters = [:]
        values.sheets[0].filterValues = [2: ["North", "East"]]
        DataTools.refilter(&values.sheets[0], workbook: values)
        let valuesBack = (try? ODS.read(ODS.write(values)))?.sheets[0]
        check("filter value lists round trip in .ods", valuesBack?.filterValues == values.sheets[0].filterValues, "\(String(describing: valuesBack?.filterValues))")
        var top = f
        top.sheets[0].customFilters = [1: ColumnFilter(conditions: [.init(op: .top, value: "2")])]
        DataTools.refilter(&top.sheets[0], workbook: top)
        let topBack = (try? XLSX.read(XLSX.write(top)))?.sheets[0]
        check("top 10 filter round trip in .xlsx", topBack?.customFilters[1] == top.sheets[0].customFilters[1] && top.sheets[0].filterHidden == [1, 4, 5, 6],
              "\(String(describing: topBack?.customFilters)) \(top.sheets[0].filterHidden.sorted())")

        // Advanced filter with a criteria range (rows = OR, columns = AND).
        var adv = book([["Item", "Qty", "Region", "", "Qty", "Region"], ["pen", "5", "North", "", ">6", "South"], ["pencil", "12", "South", "", "", "North"],
                        ["paper", "40", "North"], ["eraser", "8", "South"]])
        let okAdv = DataTools.advancedFilter(&adv, sheet: 0, list: CellRange("A1:C5")!, criteria: (0, CellRange("E1:F3")!), unique: false, copyTo: nil)
        check("advanced filter", okAdv && adv.sheets[0].filterHidden.isEmpty, "\(adv.sheets[0].filterHidden.sorted())")
        _ = DataTools.advancedFilter(&adv, sheet: 0, list: CellRange("A1:C5")!, criteria: (0, CellRange("E1:F2")!), unique: false, copyTo: nil)
        check("advanced filter AND row", adv.sheets[0].filterHidden == [1, 3], "\(adv.sheets[0].filterHidden.sorted())")

        // Subtotals and Remove All.
        var sub = book([["Region", "Sales"], ["East", "10"], ["East", "20"], ["West", "5"], ["West", "7"], ["West", "8"]])
        let r2 = DataTools.subtotals(&sub, sheet: 0, range: CellRange("A1:B6")!, groupBy: 0, function: 9, columns: [1], replace: true, pageBreaks: true)
        sub = Calculator.recalculate(sub)
        check("subtotals inserted", r2 == CellRange("A1:B9") && col(sub, 1, 3...3) == ["30"] && col(sub, 1, 7...8) == ["20", "50"]
              && sub.sheets[0][CellRef("A4")!].value.plain.contains("East"), "\(col(sub, 0, 0...8)) \(col(sub, 1, 0...8))")
        check("subtotals outline and page break", sub.sheets[0].rowLevels[1] == 2 && sub.sheets[0].rowLevels[3] == 1 && sub.sheets[0].rowLevels[8] == nil
              && sub.sheets[0].rowBreaks == [4], "\(sub.sheets[0].rowLevels) \(sub.sheets[0].rowBreaks)")
        let r3 = DataTools.subtotals(&sub, sheet: 0, range: r2, groupBy: 0, function: 1, columns: [1], replace: true, pageBreaks: false)
        sub = Calculator.recalculate(sub)
        check("subtotals replace (average)", r3 == CellRange("A1:B9") && col(sub, 1, 3...3) == ["15"] && col(sub, 1, 8...8) == ["10"], "\(col(sub, 1, 0...8))")
        let r4 = DataTools.removeSubtotals(&sub, sheet: 0, range: r3)
        check("subtotals Remove All", r4 == CellRange("A1:B6") && col(sub, 1, 1...5) == ["10", "20", "5", "7", "8"] && sub.sheets[0].rowLevels.isEmpty,
              "\(col(sub, 1, 0...6))")

        // Remove duplicates, text to columns, series, fill up/left.
        var dup = book([["a", "1"], ["b", "2"], ["A", "1"], ["b", "3"], ["c", "9"]])
        let removed = DataTools.removeDuplicates(&dup, sheet: 0, range: CellRange("A1:B5")!, columns: [0], header: false)
        check("remove duplicates", removed == 2 && col(dup, 0, 0...4) == ["a", "b", "c", "", ""], "\(removed) \(col(dup, 0, 0...4))")
        var t2c = book([["x;12;\"a;b\";31.12.2024"], ["y;;z;01.02.2025"]])
        DataTools.textToColumns(&t2c, sheet: 0, range: CellRange("A1:A2")!, options: .init(delimiters: [";"], types: [.text, .general, .general, .dateDMY]))
        check("text to columns", t2c.sheets[0][CellRef("B1")!].value == .number(12) && t2c.sheets[0][CellRef("C1")!].value == .string("a;b")
              && NumberFormat.format(t2c.sheets[0][CellRef("D2")!].value, "dd.mm.yyyy").text == "01.02.2025", "\(col(t2c, 2, 0...1))")
        var fixed = book([["AB  123"]])
        DataTools.textToColumns(&fixed, sheet: 0, range: CellRange("A1")!, options: .init(fixedBreaks: [4]))
        check("text to columns, fixed width", fixed.sheets[0][CellRef("A1")!].value == .string("AB") && fixed.sheets[0][CellRef("B1")!].value == .number(123))
        var ser = book([["1"], [""], [""], [""], [""]])
        DataTools.fillSeries(&ser, sheet: 0, range: CellRange("A1:A5")!, direction: .down, type: .linear, unit: .day, step: 2.5, stop: 8)
        check("series linear with stop", col(ser, 0, 0...4) == ["1", "3.5", "6", "", ""], "\(col(ser, 0, 0...4))")
        var grow = book([["3", "", "", ""]])
        DataTools.fillSeries(&grow, sheet: 0, range: CellRange("A1:D1")!, direction: .right, type: .growth, unit: .day, step: 2, stop: nil)
        check("series growth", grow.sheets[0][CellRef("D1")!].value == .number(24))
        var dates = Workbook()
        var d0 = Cell(); d0.value = .number(DateMath.serial(year: 2024, month: 1, day: 31)!); d0.style.numberFormat = "dd.mm.yyyy"; d0.input = "31.01.2024"
        dates.sheets[0][CellRef("A1")!] = d0
        DataTools.fillSeries(&dates, sheet: 0, range: CellRange("A1:A3")!, direction: .down, type: .date, unit: .month, step: 1, stop: nil)
        check("series by month", NumberFormat.format(dates.sheets[0][CellRef("A3")!].value, "dd.mm.yyyy").text == "31.03.2024"
              && NumberFormat.format(dates.sheets[0][CellRef("A2")!].value, "dd.mm.yyyy").text == "29.02.2024")
        DataTools.fillSeries(&dates, sheet: 0, range: CellRange("A1:A3")!, direction: .down, type: .date, unit: .weekday, step: 1, stop: nil)
        check("series by weekday", NumberFormat.format(dates.sheets[0][CellRef("A3")!].value, "dd.mm.yyyy").text == "02.02.2024")
        var up = book([["", ""], ["", ""], ["=B3+1", "5"]])
        DataTools.fill(&up, sheet: 0, range: CellRange("A1:A3")!, direction: .up)
        check("fill up shifts formulas", up.sheets[0][CellRef("A1")!].input == "=B1+1")

        // Goal seek: loan payment, square root, a cubic.
        let gs = book([["0.05", "10", "=PMT(A1/12,B1*12,D1)", "1000"]])
        let loan = DataTools.goalSeek(gs, sheet: 0, formula: CellRef("C1")!, target: -500, variable: CellRef("D1")!)
        let rate = 0.05 / 12, exact = 500 * (1 - pow(1 + rate, -120)) / rate
        check("goal seek (loan amount for a payment)", loan.map { abs($0 - exact) < 1e-6 } ?? false, "\(String(describing: loan)) vs \(exact)")
        let sq = book([["1", "=A1^2"]])
        let root = DataTools.goalSeek(sq, sheet: 0, formula: CellRef("B1")!, target: 2, variable: CellRef("A1")!)
        check("goal seek x² = 2", root.map { abs($0 - 2.0.squareRoot()) < 1e-8 } ?? false, "\(String(describing: root))")

        // Solver: textbook LP, integer program, nonlinear minimum, target value.
        let lp = book([["0", "0", "=3*A1+5*B1", "=A1", "=2*B1", "=3*A1+2*B1"]])
        var model = SolverModel(objective: CellRef("C1")!, goal: .max, variables: [CellRef("A1")!, CellRef("B1")!])
        model.constraints = [.init(lhs: CellRange("D1")!, op: .le, rhs: "4"), .init(lhs: CellRange("E1")!, op: .le, rhs: "12"),
                             .init(lhs: CellRange("F1")!, op: .le, rhs: "18")]
        let s1 = Solver.solve(lp, sheet: 0, model: model)
        check("solver LP (max 3x+5y → x=2, y=6, 36)", s1.map { $0.status == .optimal && abs($0.objective - 36) < 1e-9 && abs($0.values[0] - 2) < 1e-9 && abs($0.values[1] - 6) < 1e-9 } ?? false,
              "\(String(describing: s1))")
        let ip = book([["0", "0", "=8*A1+5*B1", "=A1+B1", "=9*A1+5*B1"]])
        var im = SolverModel(objective: CellRef("C1")!, goal: .max, variables: [CellRef("A1")!, CellRef("B1")!])
        im.constraints = [.init(lhs: CellRange("D1")!, op: .le, rhs: "6"), .init(lhs: CellRange("E1")!, op: .le, rhs: "45"),
                          .init(lhs: CellRange("A1:B1")!, op: .int)]
        let s2 = Solver.solve(ip, sheet: 0, model: im)
        check("solver integer program (→ 40 at x=5, y=0)", s2.map { abs($0.objective - 40) < 1e-9 && $0.values == [5, 0] } ?? false, "\(String(describing: s2))")
        let mixMin = book([["0", "0", "=2*A1+3*B1", "=A1+B1", "=A1-B1"]])
        var mm = SolverModel(objective: CellRef("C1")!, goal: .min, variables: [CellRef("A1")!, CellRef("B1")!])
        mm.constraints = [.init(lhs: CellRange("D1")!, op: .ge, rhs: "10"), .init(lhs: CellRange("E1")!, op: .eq, rhs: "2")]
        let s3 = Solver.solve(mixMin, sheet: 0, model: mm)
        check("solver LP min with ≥ and = (→ x=6, y=4, 24)", s3.map { abs($0.objective - 24) < 1e-9 } ?? false, "\(String(describing: s3))")
        let nl = book([["0", "0", "=(A1-3)^2+(B1+1)^2+1"]])
        var nm = SolverModel(objective: CellRef("C1")!, goal: .min, variables: [CellRef("A1")!, CellRef("B1")!])
        nm.nonNegative = false
        let s4 = Solver.solve(nl, sheet: 0, model: nm)
        check("solver nonlinear minimum (→ 3, −1)", s4.map { abs($0.values[0] - 3) < 1e-4 && abs($0.values[1] + 1) < 1e-4 && $0.engine != "simplex" } ?? false,
              "\(String(describing: s4))")
        nm.nonNegative = true
        let s5 = Solver.solve(nl, sheet: 0, model: nm)
        check("solver nonlinear with x ≥ 0 (→ 3, 0)", s5.map { abs($0.values[0] - 3) < 1e-3 && abs($0.values[1]) < 1e-3 } ?? false, "\(String(describing: s5))")
        var tm = SolverModel(objective: CellRef("B1")!, goal: .value(2), variables: [CellRef("A1")!])
        tm.linear = false
        let s6 = Solver.solve(sq, sheet: 0, model: tm)
        check("solver value of (x² = 2)", s6.map { abs($0.values[0] - 2.0.squareRoot()) < 1e-4 } ?? false, "\(String(describing: s6))")
        let infeasible = book([["0", "=A1"]])
        var inf = SolverModel(objective: CellRef("B1")!, goal: .max, variables: [CellRef("A1")!])
        inf.constraints = [.init(lhs: CellRange("B1")!, op: .ge, rhs: "5"), .init(lhs: CellRange("B1")!, op: .le, rhs: "3")]
        check("solver reports an infeasible model", Solver.solve(infeasible, sheet: 0, model: inf)?.status == .infeasible)
        failed += sheetFeatureFiles()
        return failed
    }

    /// Tab colour, hidden sheets, hyperlinks, named cell styles, rotation/shrink, page breaks in .xlsx and .ods.
    static func sheetFeatureFiles() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        let wb = featureDemo()
        for (kind, data) in [("xlsx", XLSX.write(wb)), ("ods", ODS.write(wb))] {
            guard let back = try? SpreadsheetFile.read(data) else { check("\(kind) reads back", false); continue }
            let s = back.sheets[0]
            let tab = s.tabColor.map(XLSX.argb)
            check("\(kind): tab colour and hidden sheet", tab == "FFFF0000" && back.sheets[1].hidden && !back.sheets[2].hidden, "\(String(describing: tab)) \(back.sheets.map(\.hidden))")
            check("\(kind): hyperlinks", s.hyperlinks[CellRef("A1")!] == "https://www.apple.com/" && s.hyperlinks[CellRef("A2")!] == "#Third!B5",
                  "\(s.hyperlinks)")
            let b1 = s[CellRef("B1")!].style, b2 = s[CellRef("B2")!].style
            check("\(kind): rotation, shrink, hidden formula", b1.rotation == 45 && b2.rotation == -30 && b2.shrink && b2.hiddenFormula,
                  "\(b1.rotation) \(b2.rotation) \(b2.shrink) \(b2.hiddenFormula)")
            if kind == "xlsx" {
                check("xlsx: named cell styles", b1.styleName == "Heading 1" && b2.styleName == "Good" && b1.bold && b1.fontSize == 15, "\(String(describing: b1.styleName))")
                check("xlsx: manual page breaks", s.rowBreaks == [10], "\(s.rowBreaks)")
            }
        }
        let styles = String(decoding: (try? ZipArchive(data: XLSX.write(wb)))?["xl/styles.xml"] ?? Data(), as: UTF8.self)
        check("xlsx cellStyles list the named styles", styles.range(of: "<cellStyle name=\"Heading 1\" xfId=\"[0-9]+\" builtinId=\"16\"/>", options: .regularExpression) != nil
              && styles.contains("name=\"Good\""), styles.components(separatedBy: "<cellStyles").last ?? "")
        return failed
    }

    /// Workbook with sheet features (also `XLS42 --feature-demo out.xlsx|ods` for checks in Excel/LibreOffice).
    static func featureDemo() -> Workbook {
        var wb = Workbook()
        wb.sheets = [Sheet(name: "Visible"), Sheet(name: "Secret"), Sheet(name: "Third")]
        wb.sheets[0].tabColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        wb.sheets[1].hidden = true
        var link = Cell(); link.input = "Apple"; link.value = .string("Apple")
        wb.sheets[0][CellRef("A1")!] = link
        wb.sheets[0].hyperlinks[CellRef("A1")!] = "https://www.apple.com/"
        var place = Cell(); place.input = "Go"; place.value = .string("Go")
        wb.sheets[0][CellRef("A2")!] = place
        wb.sheets[0].hyperlinks[CellRef("A2")!] = "#Third!B5"
        var styled = Cell(); styled.input = "Title"; styled.value = .string("Title")
        styled.style = CellStyles.applied(CellStyles.presets.first { $0.name == "Heading 1" }!, to: styled.style)
        styled.style.rotation = 45
        wb.sheets[0][CellRef("B1")!] = styled
        var good = Cell(); good.input = "ok"; good.value = .string("ok")
        good.style = CellStyles.applied(CellStyles.presets.first { $0.name == "Good" }!, to: good.style)
        good.style.shrink = true
        good.style.hiddenFormula = true
        good.style.rotation = -30
        wb.sheets[0][CellRef("B2")!] = good
        wb.sheets[0].rowBreaks = [10]
        // A filtered table on the third sheet: Qty > 6 and Region begins with "N".
        for (r, row) in [["Item", "Qty", "Region"], ["pen", "5", "North"], ["pencil", "12", "South"], ["paper", "40", "North"], ["ink", "8", "Nordic"]].enumerated() {
            for (c, v) in row.enumerated() {
                var cell = Cell(); cell.input = v; cell.value = XLSX.constant(v)
                wb.sheets[2][CellRef(row: r, col: c)] = cell
            }
        }
        wb.sheets[2].autoFilter = CellRange("A1:C5")
        wb.sheets[2].customFilters = [1: ColumnFilter(conditions: [.init(op: .greaterThan, value: "6")]), 2: ColumnFilter(conditions: [.init(op: .beginsWith, value: "N")])]
        DataTools.refilter(&wb.sheets[2], workbook: wb)
        return wb
    }
}
