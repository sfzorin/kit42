import Foundation
import Kit42

extension SelfTest {
    static func deepSheetReferences() -> Int {
        var checked = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            checked += 1
            if !ok { failed += 1; print("FAIL deep sheet references:", name) }
        }
        func cell(_ input: String) -> Cell {
            var cell = Cell(); cell.input = input
            cell.value = cell.isFormula ? .empty : XLSX.constant(input)
            return cell
        }
        let source = "O'Brien", renamed = "L'été 2026"
        let oldRef = "'O''Brien'!", newRef = "'L''été 2026'!"
        var wb = Workbook()
        wb.sheets = [Sheet(name: source), Sheet(name: "Other")]
        wb.sheets[0][CellRef("A1")!] = cell("7")
        wb.sheets[0][CellRef("A2")!] = cell("9")
        wb.sheets[0][CellRef("B1")!] = cell("=\(oldRef)A1+Other!A1")
        wb.sheets[0][CellRef("C1")!] = cell("=\"O'Brien\"")
        wb.sheets[1][CellRef("A1")!] = cell("100")
        wb.sheets[1][CellRef("B1")!] = cell("=SUM(\(oldRef)$A$1:$A$2)")
        wb.sheets[1][CellRef("C1")!] = cell("=Other!A1 + 1")
        wb.names["SourceData"] = oldRef + "$A$1:$A$2"
        wb.names["SourceTotal"] = "SUM(" + oldRef + "$A$1:$A$2)"
        wb.names["Literal"] = "\"O'Brien\""
        var validation = DataValidation(ranges: [CellRange("D1:D2")!], kind: .whole)
        validation.formula1 = oldRef + "$A$1"; validation.formula2 = oldRef + "$A$2"
        wb.sheets[0].validations = [validation]
        wb.sheets[0].conditionalFormats = [
            ConditionalFormat(range: CellRange("D1:D2")!, kind: .expression(oldRef + "A1>0")),
            ConditionalFormat(range: CellRange("E1:E2")!, kind: .cellIs(op: "between", values: [oldRef + "$A$1", oldRef + "$A$2"]))
        ]
        wb.sheets[0].charts = [SheetChart(kind: .column, title: source, series: [
            .init(name: "=" + oldRef + "$A$1", categories: oldRef + "$A$1:$A$2", values: oldRef + "$A$1:$A$2")
        ], anchor: CellRef("G1")!, size: CGSize(width: 300, height: 200))]
        wb.sheets[0].hyperlinks[CellRef("F1")!] = "#" + oldRef + "A1"
        wb.sheets[0].hyperlinks[CellRef("F2")!] = "https://example.com/O'Brien"
        wb.sheets[1].pivot = PivotSpec(sourceSheet: source, source: CellRange("A1:B2")!, rowField: 0, colField: nil, valueField: 1, aggregate: .sum)

        let original = wb
        wb.sheets[0].name = renamed
        SheetWindowController.renameReferences(&wb, from: source, to: renamed)
        wb = Calculator.recalculate(wb)
        check("escaped apostrophe self-reference", wb.sheets[0][CellRef("B1")!].input == "=\(newRef)A1+Other!A1")
        check("renamed formula recalculates", wb.sheets[0][CellRef("B1")!].value == .number(107))
        check("other-sheet range reference", wb.sheets[1][CellRef("B1")!].input == "=SUM(\(newRef)$A$1:$A$2)" && wb.sheets[1][CellRef("B1")!].value == .number(16))
        check("unaffected formula spelling retained", wb.sheets[1][CellRef("C1")!].input == "=Other!A1 + 1")
        check("literal sheet-name text retained", wb.sheets[0][CellRef("C1")!].input == "=\"O'Brien\"" && wb.names["Literal"] == "\"O'Brien\"")
        check("named range", wb.names["SourceData"] == newRef + "$A$1:$A$2")
        check("named expression", wb.names["SourceTotal"] == "SUM(" + newRef + "$A$1:$A$2)")
        check("validation lower and upper references", wb.sheets[0].validations[0].formula1 == newRef + "$A$1" && wb.sheets[0].validations[0].formula2 == newRef + "$A$2")
        if case .expression(let formula) = wb.sheets[0].conditionalFormats[0].kind {
            check("conditional expression", formula == newRef + "A1>0")
        } else { check("conditional expression", false) }
        if case .cellIs(_, let values) = wb.sheets[0].conditionalFormats[1].kind {
            check("conditional bounds", values == [newRef + "$A$1", newRef + "$A$2"])
        } else { check("conditional bounds", false) }
        let series = wb.sheets[0].charts[0].series[0]
        check("chart values and categories", series.values == newRef + "$A$1:$A$2" && series.categories == newRef + "$A$1:$A$2")
        check("chart series-name reference", series.name == "=" + newRef + "$A$1")
        check("chart still resolves", ChartRenderer.resolve(wb.sheets[0].charts[0], workbook: wb, sheet: 0).first?.values == [7, 9])
        check("internal hyperlink", wb.sheets[0].hyperlinks[CellRef("F1")!] == "#" + newRef + "A1")
        check("external hyperlink retained", wb.sheets[0].hyperlinks[CellRef("F2")!] == "https://example.com/O'Brien")
        check("pivot source", wb.sheets[1].pivot?.sourceSheet == renamed)

        var copy = original.sheets[0]
        SheetWindowController.renameReferences(&copy, from: source, to: "Copy")
        copy.name = "Copy"; copy[CellRef("A1")!] = cell("11")
        var copiedWorkbook = original; copiedWorkbook.sheets.append(copy)
        copiedWorkbook = Calculator.recalculate(copiedWorkbook)
        check("copy explicit self-reference points to copy", copiedWorkbook.sheets[2][CellRef("B1")!].input == "=Copy!A1+Other!A1" && copiedWorkbook.sheets[2][CellRef("B1")!].value == .number(111))
        check("copy leaves original references", copiedWorkbook.sheets[0][CellRef("B1")!].input == original.sheets[0][CellRef("B1")!].input && copiedWorkbook.names == original.names)
        check("copied chart references", copiedWorkbook.sheets[2].charts[0].series[0].name == "=Copy!$A$1")
        check("copied validation references", copiedWorkbook.sheets[2].validations[0].formula1 == "Copy!$A$1")

        for invalid in ["", "   ", "a/b", "a:b", "a[b]", "a\\b", "a?b", "a*b", "'a", "a'", "a\nb", "a\0b", String(repeating: "x", count: 32), String(repeating: "😀", count: 16)] {
            check("invalid sheet name \(invalid.debugDescription)", !SheetWindowController.validSheetName(invalid))
        }
        check("31 UTF-16 units valid", SheetWindowController.validSheetName(String(repeating: "😀", count: 15) + "x"))
        check("interior apostrophe valid", SheetWindowController.validSheetName(source))
        for base in [String(repeating: "x", count: 31), String(repeating: "😀", count: 15) + "x"] {
            var names = Workbook(); names.sheets = [Sheet(name: base)]
            var generated = Set([base.lowercased()])
            for _ in 0..<12 {
                let name = SheetWindowController.uniqueSheetName(base, in: names)
                check("unique bounded copy name \(name)", SheetWindowController.validSheetName(name) && generated.insert(name.lowercased()).inserted)
                names.sheets.append(Sheet(name: name))
            }
        }
        var names = Workbook(); names.sheets = [Sheet(name: "Data"), Sheet(name: "DATA (2)")]
        check("case-insensitive copy collision", SheetWindowController.uniqueSheetName("Data", in: names) == "Data (3)")
        print("XLS deep sheet reference regressions: \(checked - failed)/\(checked) passed")
        return failed
    }
}
