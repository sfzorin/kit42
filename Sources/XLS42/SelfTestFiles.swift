import AppKit
import Kit42

/// File round trips of the Solver model, split window, named cell styles and legacy array formulas (.xlsx and .ods).
extension SelfTest {
    static func viewAndModelFiles() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func ref(_ a1: String) -> CellRef { CellRef(a1)! }
        func text(_ data: Data, _ path: String) -> String { String(decoding: (try? ZipArchive(data: data))?[path] ?? Data(), as: UTF8.self) }
        func put(_ wb: inout Workbook, _ sheet: Int, _ a1: String, _ input: String) {
            var c = Cell(); c.input = input; c.value = input.hasPrefix("=") ? .empty : XLSX.constant(input)
            wb.sheets[sheet][ref(a1)] = c
        }
        func formats(_ wb: Workbook) -> [(String, Data)] { [("xlsx", XLSX.write(wb)), ("ods", ODS.write(wb))] }

        // MARK: Solver model
        var wb = Workbook()
        wb.sheets = [Sheet(name: "Data"), Sheet(name: "Plan 1")]
        for (a, v) in [("A1", "0"), ("B1", "0"), ("C1", "=3*A1+5*B1"), ("D1", "=A1"), ("E1", "=2*B1"), ("F1", "=3*A1+2*B1"), ("G1", "4")] { put(&wb, 1, a, v) }
        var model = SolverModel(objective: ref("C1"), goal: .max, variables: [ref("A1"), ref("B1")])
        model.constraints = [.init(lhs: CellRange("D1")!, op: .le, rhs: "$G$1"), .init(lhs: CellRange("E1")!, op: .le, rhs: "12"),
                             .init(lhs: CellRange("F1")!, op: .le, rhs: "18"), .init(lhs: CellRange("A1")!, op: .int),
                             .init(lhs: CellRange("B1")!, op: .ge, rhs: "0.5")]
        wb.sheets[1].solver = model
        var other = SolverModel(objective: ref("C1"), goal: .value(7.5), variables: [ref("A1")])
        other.constraints = [.init(lhs: CellRange("A1")!, op: .bin), .init(lhs: CellRange("B1")!, op: .eq, rhs: "2")]
        other.nonNegative = false
        other.linear = false
        put(&wb, 0, "C1", "=A1*2"); put(&wb, 0, "A1", "1")
        wb.sheets[0].solver = other
        wb = Calculator.recalculate(wb)
        for (kind, data) in formats(wb) {
            guard let back = try? SpreadsheetFile.read(data) else { check("\(kind): solver file reads", false); continue }
            var m1 = back.sheets[1].solver, m0 = back.sheets[0].solver
            m1?.extra = [:]; m0?.extra = [:]
            check("\(kind): solver model with ≤ ref, int, ≥ constraints round trips", m1 == model, "\(String(describing: m1))")
            check("\(kind): solver value goal, binary, free, nonlinear round trip", m0 == other, "\(String(describing: m0))")
            check("\(kind): solver names stay hidden (not defined names)", back.names.keys.allSatisfy { !$0.hasPrefix("solver") }, "\(back.names)")
            if let m = back.sheets[1].solver, let r = Solver.solve(back, sheet: 1, model: m) {
                check("\(kind): solver model from the file solves", r.status == .optimal && r.values.count == 2 && abs(r.values[0] - 2) < 1e-6 && abs(r.values[1] - 6) < 1e-6, "\(r.values)")
            } else { check("\(kind): solver model from the file solves", false) }
            check("\(kind): LibreOffice engine kept", back.sheets[0].solver?.extra["solver_lo_eng"] == "\"\(SolverFiles.nonlinearEngine)\"", "\(back.sheets[0].solver?.extra ?? [:])")
        }
        let wbXML = text(XLSX.write(wb), "xl/workbook.xml")
        check("xlsx: Excel's hidden sheet-scoped solver names", wbXML.contains("<definedName name=\"solver_opt\" localSheetId=\"1\" hidden=\"1\">'Plan 1'!$C$1</definedName>")
              && wbXML.contains("<definedName name=\"solver_adj\" localSheetId=\"1\" hidden=\"1\">'Plan 1'!$A$1:$B$1</definedName>")
              && wbXML.contains("name=\"solver_rel4\" localSheetId=\"1\" hidden=\"1\">4<") && wbXML.contains("name=\"solver_rhs4\" localSheetId=\"1\" hidden=\"1\">&quot;integer&quot;<")
              && wbXML.contains("name=\"solver_typ\" localSheetId=\"0\" hidden=\"1\">3<") && wbXML.contains("name=\"solver_val\" localSheetId=\"0\" hidden=\"1\">7.5<")
              && wbXML.contains("name=\"solver_neg\" localSheetId=\"0\" hidden=\"1\">2<") && wbXML.contains("name=\"solver_eng\" localSheetId=\"1\" hidden=\"1\">2<")
              && wbXML.contains("name=\"solver_num\" localSheetId=\"1\" hidden=\"1\">5<") && wbXML.contains("name=\"solver_ver\" localSheetId=\"1\" hidden=\"1\">3<"),
              wbXML.components(separatedBy: "<definedNames>").last?.prefix(600).description ?? "")
        let content = text(ODS.write(wb), "content.xml")
        let table2 = content.components(separatedBy: "<table:table table:name=\"Plan 1\"").last ?? ""
        check("ods: solver model in the sheet's named expressions (as LibreOffice)",
              table2.contains("<table:named-range table:name=\"solver_opt\" table:base-cell-address=\"$'Plan 1'.$A$1\" table:cell-range-address=\"$'Plan 1'.$C$1\" table:range-usable-as=\"hidden\"/>")
              && table2.contains("<table:named-expression table:name=\"solver_rel4\" table:base-cell-address=\"$'Plan 1'.$A$1\" table:expression=\"4\" loext:hidden=\"true\"/>")
              && table2.range(of: "</table:named-expressions></table:table>") != nil, String(table2.suffix(500)))
        // Excel-style names written by another program: workbook-level, rhs "integer", no solver_num.
        let foreign = """
        <definedName name="solver_opt">'Plan 1'!$C$1</definedName><definedName name="solver_adj">'Plan 1'!$A$1,'Plan 1'!$B$1</definedName>\
        <definedName name="solver_typ">2</definedName><definedName name="solver_lhs1">'Plan 1'!$A$1</definedName><definedName name="solver_rel1">4</definedName>\
        <definedName name="solver_rhs1">"integer"</definedName><definedName name="solver_lhs2">'Plan 1'!$A$1:$B$1</definedName><definedName name="solver_rel2">3</definedName>\
        <definedName name="solver_rhs2">'Plan 1'!$G$1</definedName><definedName name="solver_lin">2</definedName>
        """
        var plain = wb
        plain.sheets[0].solver = nil; plain.sheets[1].solver = nil
        var zip = try? ZipArchive(data: XLSX.write(plain))
        let w = text(XLSX.write(plain), "xl/workbook.xml").replacingOccurrences(of: "<calcPr", with: "<definedNames>\(foreign)</definedNames><calcPr")
        zip?["xl/workbook.xml"] = Data(w.utf8)
        let fm = (zip.flatMap { try? XLSX.read($0.data()) })?.sheets[1].solver
        check("xlsx: workbook-level solver names from other programs", fm?.goal == .min && fm?.variables == [ref("A1"), ref("B1")] && fm?.linear == false
              && fm?.constraints == [.init(lhs: CellRange("A1")!, op: .int, rhs: ""), .init(lhs: CellRange("A1:B1")!, op: .ge, rhs: "$G$1")], "\(String(describing: fm))")
        var shifted = wb
        DataTools.shiftCells(&shifted, sheet: 1, rows: true, at: 0, count: 2)
        check("solver model follows inserted rows", shifted.sheets[1].solver?.objective == ref("C3") && shifted.sheets[1].solver?.constraints.first?.rhs == "$G$3",
              "\(String(describing: shifted.sheets[1].solver))")

        // MARK: Split window
        var sw = Workbook()
        sw.sheets = [Sheet(name: "Split"), Sheet(name: "Columns"), Sheet(name: "Frozen")]
        for s in 0..<3 { put(&sw, s, "A1", "1") }
        let split = SheetSplit(x: 150, y: 60, topLeft: ref("B3"), bottomRight: ref("F20"), activePane: "bottomRight")
        sw.sheets[0].split = split
        sw.sheets[1].split = SheetSplit(x: 100, y: 0, topLeft: ref("A5"), bottomRight: ref("D5"), activePane: "topRight")
        sw.sheets[2].split = split
        sw.sheets[2].frozenRows = 1
        for (kind, data) in formats(sw) {
            guard let back = try? SpreadsheetFile.read(data) else { check("\(kind): split file reads", false); continue }
            check("\(kind): split window round trips", back.sheets[0].split == split, "\(String(describing: back.sheets[0].split))")
            check("\(kind): vertical split line only", back.sheets[1].split == sw.sheets[1].split, "\(String(describing: back.sheets[1].split))")
            check("\(kind): frozen panes win over a split", back.sheets[2].frozenRows == 1 && back.sheets[2].split == nil, "\(String(describing: back.sheets[2].split))")
        }
        let sheetXML = text(XLSX.write(sw), "xl/worksheets/sheet1.xml")
        check("xlsx: pane state=split in twips with the headers", sheetXML.contains("<sheetView workbookViewId=\"0\" tabSelected=\"1\" topLeftCell=\"B3\"><pane xSplit=\"2640\" ySplit=\"1200\" topLeftCell=\"F20\" activePane=\"bottomRight\" state=\"split\"/>"),
              sheetXML.components(separatedBy: "<sheetViews>").last?.prefix(300).description ?? "")
        let settings = text(ODS.write(sw), "settings.xml")
        check("ods: split mode 1, position in pixels, pane positions", settings.contains("xmlns:ooo=\"http://openoffice.org/2004/office\"")
              && settings.contains("<config:config-item config:name=\"HorizontalSplitMode\" config:type=\"short\">1</config:config-item><config:config-item config:name=\"VerticalSplitMode\" config:type=\"short\">1</config:config-item><config:config-item config:name=\"HorizontalSplitPosition\" config:type=\"int\">176</config:config-item><config:config-item config:name=\"VerticalSplitPosition\" config:type=\"int\">80</config:config-item><config:config-item config:name=\"ActiveSplitRange\" config:type=\"short\">3</config:config-item><config:config-item config:name=\"PositionLeft\" config:type=\"int\">1</config:config-item><config:config-item config:name=\"PositionRight\" config:type=\"int\">5</config:config-item><config:config-item config:name=\"PositionTop\" config:type=\"int\">2</config:config-item><config:config-item config:name=\"PositionBottom\" config:type=\"int\">19</config:config-item>"),
              String(settings.suffix(900)))
        // Split from Excel: xSplit/ySplit in twips with the default pane (state omitted).
        if var z = try? ZipArchive(data: XLSX.write(sw)) {
            z["xl/worksheets/sheet1.xml"] = Data(sheetXML.replacingOccurrences(of: "<pane xSplit=\"2640\" ySplit=\"1200\" topLeftCell=\"F20\" activePane=\"bottomRight\" state=\"split\"/>",
                                                                                with: "<pane xSplit=\"3390\" topLeftCell=\"H1\" activePane=\"topRight\"/>").utf8)
            let s = (try? XLSX.read(z.data()))?.sheets[0].split
            check("xlsx: Excel split without state reads", s?.x == 200 && s?.y == 0 && s?.bottomRight == ref("H1") && s?.topLeft == ref("B1") && s?.activePane == "topRight", "\(String(describing: s))")
        }

        // MARK: Named cell styles in .ods
        var cs = featureDemo()
        var accent = Cell(); accent.input = "a"; accent.value = .string("a")
        accent.style = CellStyles.applied(CellStyles.preset(named: "Accent1")!, to: accent.style)
        cs.sheets[0][ref("B3")] = accent
        var mine = CellStyle.default; mine.italic = true; mine.fill = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1); mine.styleName = "Mine"
        cs.cellStyles["Mine"] = mine
        let odsData = ODS.write(cs)
        let stylesXML = text(odsData, "styles.xml"), odsContent = text(odsData, "content.xml")
        check("ods: named styles in office:styles with display names", stylesXML.contains("<style:style style:name=\"Heading_20_1\" style:display-name=\"Heading 1\" style:family=\"table-cell\" style:parent-style-name=\"Default\">")
              && stylesXML.contains("style:name=\"Accent_20_1\" style:display-name=\"Accent 1\"") && stylesXML.contains("style:name=\"Good\" style:display-name=\"Good\"")
              && stylesXML.contains("style:name=\"Mine\""), String(stylesXML.suffix(800)))
        check("ods: cells use them as parent styles", odsContent.contains("style:parent-style-name=\"Heading_20_1\"") && odsContent.contains("style:parent-style-name=\"Good\"")
              && odsContent.contains("style:parent-style-name=\"Accent_20_1\""))
        for (kind, data) in formats(cs) {
            guard let back = try? SpreadsheetFile.read(data) else { check("\(kind): styles file reads", false); continue }
            let s = back.sheets[0]
            check("\(kind): cells keep their style names", s[ref("B1")].style.styleName == "Heading 1" && s[ref("B2")].style.styleName == "Good" && s[ref("B3")].style.styleName == "Accent1"
                  && s[ref("B1")].style.bold && s[ref("B3")].style.fill.map(XLSX.argb) == "FF4472C4", "\(String(describing: s[ref("B3")].style.styleName))")
            check("\(kind): document styles kept (also unused ones)", back.cellStyles["Mine"]?.italic == true && back.cellStyles["Mine"]?.fill.map(XLSX.argb) == "FF0000FF"
                  && back.cellStyles["Heading 1"]?.fontSize == 15, "\(back.cellStyles.keys.sorted())")
            // ods → xlsx → ods and back keep the names.
            if let again = try? SpreadsheetFile.read(kind == "ods" ? XLSX.write(back) : ODS.write(back)) {
                check("\(kind): styles survive the other format too", again.sheets[0][ref("B3")].style.styleName == "Accent1" && again.cellStyles["Mine"] != nil)
            }
        }
        // A LibreOffice-made file: its own styles (Accent 1 over Accent, Excel Built-in names from .xlsx imports).
        let loStyles = """
        <style:style style:name="Default" style:family="table-cell"/><style:style style:name="Accent" style:family="table-cell" style:parent-style-name="Default"><style:text-properties fo:font-weight="bold"/></style:style>\
        <style:style style:name="Accent_20_1" style:display-name="Accent 1" style:family="table-cell" style:parent-style-name="Accent"><style:table-cell-properties fo:background-color="#000000"/><style:text-properties fo:color="#ffffff"/></style:style>\
        <style:style style:name="Excel_20_Built-in_20_Bad" style:display-name="Excel Built-in Bad" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:background-color="#ffc7ce"/></style:style>\
        <style:style style:name="Footnote" style:family="table-cell" style:parent-style-name="Default"><style:text-properties fo:font-style="italic"/></style:style>
        """
        var plainCells = Workbook()
        put(&plainCells, 0, "A1", "x"); put(&plainCells, 0, "A2", "y"); put(&plainCells, 0, "A3", "z")
        plainCells.sheets[0][ref("A1")].style.underline = true
        plainCells.sheets[0][ref("A2")].style.strike = true
        plainCells.sheets[0][ref("A3")].style.wrap = true
        if var z = try? ZipArchive(data: ODS.write(plainCells)) {
            var st = text(z.data(), "styles.xml")
            st = st.replacingOccurrences(of: "<style:style style:name=\"Default\" style:family=\"table-cell\"/>", with: loStyles)
            z["styles.xml"] = Data(st.utf8)
            var c = text(z.data(), "content.xml")
            for (i, parent) in ["Accent_20_1", "Excel_20_Built-in_20_Bad", "Footnote"].enumerated() {
                c = c.replacingOccurrences(of: "style:name=\"ce\(i + 1)\" style:family=\"table-cell\" style:parent-style-name=\"Default\"", with: "style:name=\"ce\(i + 1)\" style:family=\"table-cell\" style:parent-style-name=\"\(parent)\"")
            }
            z["content.xml"] = Data(c.utf8)
            let back = try? ODS.read(z.data())
            let a1 = back?.sheets[0][ref("A1")].style, a2 = back?.sheets[0][ref("A2")].style, a3 = back?.sheets[0][ref("A3")].style
            check("ods: LibreOffice styles read (Accent 1 → Accent1, inherited formatting)", a1?.styleName == "Accent1" && a1?.bold == true && a1?.fill.map(XLSX.argb) == "FF000000" && a1?.underline == true,
                  "\(String(describing: a1?.styleName)) \(String(describing: a1?.bold))")
            check("ods: Excel Built-in names and LibreOffice-only styles", a2?.styleName == "Bad" && a3?.styleName == "Footnote" && a3?.italic == true
                  && back?.cellStyles["Footnote"] != nil && back?.cellStyles["Accent"] != nil, "\(String(describing: a2?.styleName)) \(back?.cellStyles.keys.sorted() ?? [])")
        }

        // MARK: Legacy array formulas
        var aw = Workbook()
        for (a, v) in [("A1", "1"), ("A2", "2"), ("A3", "3"), ("C1", "=A1:A3*2"), ("D1", "=10"), ("E1", "=TRANSPOSE(A1:A3)")] { put(&aw, 0, a, v) }
        for (a, r) in [("C1", "C1:C4"), ("D1", "D1:D3"), ("E1", "E1:F1")] {
            aw.sheets[0][ref(a)].array = true
            aw.sheets[0].arrays[ref(a)] = CellRange(r)!
        }
        aw = Calculator.recalculate(aw)
        func show(_ wb: Workbook, _ a1: String) -> String { display(wb.sheets[0][ref(a1)].value) }
        check("array formula fills its range (extra cells #N/A)", ["C1", "C2", "C3", "C4"].map { show(aw, $0) } == ["2", "4", "6", "#N/A"], ["C1", "C2", "C3", "C4"].map { show(aw, $0) }.description)
        check("array formula: a single value repeats, a wider result is cut", ["D1", "D2", "D3", "E1", "F1", "G1"].map { show(aw, $0) } == ["10", "10", "10", "1", "2", ""],
              ["D1", "D2", "D3", "E1", "F1", "G1"].map { show(aw, $0) }.description)
        let arraySheet = text(XLSX.write(aw), "xl/worksheets/sheet1.xml")
        check("xlsx: legacy array formula (t=array, its range, no cm)", arraySheet.contains("<c r=\"C1\"><f t=\"array\" ref=\"C1:C4\">A1:A3*2</f>") && arraySheet.contains("<f t=\"array\" ref=\"E1:F1\">TRANSPOSE(A1:A3)</f>")
              && !arraySheet.contains("cm=\"1\""), arraySheet.components(separatedBy: "<sheetData>").last?.prefix(500).description ?? "")
        check("ods: matrix spans", text(ODS.write(aw), "content.xml").contains("table:formula=\"of:=[.A1:.A3]*2\" table:number-matrix-columns-spanned=\"1\" table:number-matrix-rows-spanned=\"4\""))
        for (kind, data) in formats(aw) {
            let back = (try? SpreadsheetFile.read(data)).map(Calculator.recalculate)
            // (.ods: TRANSPOSE, a dynamic-array function, spills to its natural size again.)
            let fixed = kind == "ods" ? aw.sheets[0].arrays.filter { $0.key != ref("E1") } : aw.sheets[0].arrays
            check("\(kind): array ranges read back", back?.sheets[0].arrays == fixed && back.map { show($0, "C4") } == "#N/A" && back.map { show($0, "D3") } == "10"
                  && back.map { show($0, "F1") } == "2",
                  "\(String(describing: back?.sheets[0].arrays))")
        }
        return failed
    }
}
