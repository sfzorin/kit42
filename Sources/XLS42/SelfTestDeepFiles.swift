import AppKit
import Kit42

extension SelfTest {
    /// Import must preserve editable values and metadata, not merely produce a readable first sheet.
    static func deepFiles() -> Int {
        var failed = 0, checks = 0
        func check(_ name: String, _ ok: Bool) {
            checks += 1
            if !ok { failed += 1 }
            print(ok ? "ok  " : "FAIL", "deep files:", name)
        }
        func ref(_ name: String) -> CellRef { CellRef(name)! }
        func put(_ workbook: inout Workbook, _ address: String, _ value: Value, _ style: CellStyle = .default) {
            var cell = Cell(); cell.value = value; cell.style = style
            cell.input = XLSX.inputText(for: value, style: style, date1904: workbook.date1904)
            workbook.sheets[0][ref(address)] = cell
        }
        func formats(_ workbook: Workbook) -> [(String, Data)] { [("xlsx", XLSX.write(workbook)), ("ods", ODS.write(workbook))] }
        func xlsx(_ workbook: Workbook, _ edit: (inout ZipArchive) -> Void) -> Data {
            var zip = try! ZipArchive(data: XLSX.write(workbook))
            edit(&zip)
            return zip.data()
        }
        func ods(_ table: String, automatic: String = "", extra: String = "") -> Data {
            var zip = try! ZipArchive(data: ODS.write(Workbook()))
            let xml = """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0"><office:automatic-styles>\(automatic)</office:automatic-styles><office:body><office:spreadsheet><table:table table:name="Data">\(table)</table:table>\(extra)</office:spreadsheet></office:body></office:document-content>
            """
            zip["content.xml"] = Data(xml.utf8)
            return zip.data()
        }
        func rejectsODS(_ name: String, _ table: String) {
            do { _ = try ODS.read(ods(table)); check(name, false) }
            catch { check(name, true) }
        }

        // Literal strings are editable constants, even if they look like formulas or numbers.
        var literals = Workbook()
        let strings = ["=1+2", "00123", "TRUE", "15.03.2024", "'quoted", "", "  spaced  ", "Русский Türkçe", "first\rsecond", "first\r\nsecond", "tabs\tand\nlines"]
        for (index, text) in strings.enumerated() { put(&literals, "A\(index + 1)", .string(text)) }
        for (kind, data) in formats(literals) {
            if let back = try? SpreadsheetFile.read(data) {
                let calculated = Calculator.recalculate(back)
                for (index, text) in strings.enumerated() {
                    let cell = calculated.sheets[0][ref("A\(index + 1)")]
                    check("\(kind) literal string \(index + 1) remains constant and editable",
                          !cell.isFormula && cell.value == .string(text) && XLSX.constant(cell.input) == .string(text))
                }
            } else { check("\(kind) literal fixture opens", false) }
        }
        let csv = Calculator.recalculate(XLSX.readCSV(Data("=1+2,ordinary\n".utf8)))
        check("CSV text starting with equals is not executed as a formula", csv.sheets[0][ref("A1")].value == .string("=1+2") && !csv.sheets[0][ref("A1")].isFormula)
        var lines = Workbook(); put(&lines, "A1", .string("first\rsecond"))
        check("CSV quotes carriage returns", XLSX.readCSV(try! XLSX.writeCSV(lines.sheets[0])).sheets[0][ref("A1")].value == .string("first\rsecond"))
        var sparseCSV = Workbook(); put(&sparseCSV, "XFD1048576", .number(1))
        do { _ = try XLSX.writeCSV(sparseCSV.sheets[0]); check("CSV rejects an oversized sparse rectangle", false) }
        catch { check("CSV rejects an oversized sparse rectangle", true) }
        for type in ["org.openxmlformats.spreadsheetml.sheet", "org.oasis-open.opendocument.spreadsheet", "com.microsoft.excel.xls"] {
            do { _ = try SpreadsheetFile.read(Data([0, 1, 2]), typeName: type); check("explicit \(type) rejects invalid workbook bytes", false) }
            catch { check("explicit \(type) rejects invalid workbook bytes", true) }
        }
        check("automatic detection still opens CSV text", (try? SpreadsheetFile.read(Data("normal,42".utf8)))?.sheets[0][ref("B1")].value == .number(42))
        let badStructure = xlsx(Workbook()) { $0["xl/workbook.xml"] = Data("<not-a-workbook/>".utf8) }
        do { _ = try SpreadsheetFile.read(badStructure, typeName: "xlsx"); check("XLSX rejects invalid workbook structure", false) }
        catch { check("XLSX rejects invalid workbook structure", true) }

        // Empty input templates must retain number formats and unlocked cells.
        var blank = Workbook()
        var input = CellStyle(); input.numberFormat = "0.00"; input.locked = false; input.wrap = true
        put(&blank, "B3", .empty, input)
        blank.sheets[0].rowHeights[4] = 35
        blank.sheets[0].merges = [CellRange("D5:F6")!]
        let reopenedBlank = try? ODS.read(ODS.write(blank))
        let blankStyle = reopenedBlank?.sheets[0][ref("B3")].style
        check("ODS blank input cell keeps number format and protection", blankStyle?.numberFormat == "0.00" && blankStyle?.locked == false && blankStyle?.wrap == true)
        check("ODS empty custom-height row survives", abs((reopenedBlank?.sheets[0].rowHeights[4] ?? 0) - 35) < 0.1)
        check("ODS empty merged range survives", reopenedBlank?.sheets[0].merges == blank.sheets[0].merges)

        var bordered = Workbook()
        var borders = CellStyle(); borders.left = BorderSide(style: "dashed", color: .red); borders.bottom = BorderSide(style: "dotted", color: .blue)
        put(&bordered, "A1", .number(1), borders)
        let borderStyle = (try? ODS.read(ODS.write(bordered)))?.sheets[0][ref("A1")].style
        check("ODS dashed and dotted border patterns survive", borderStyle?.left?.style == "dashed" && borderStyle?.bottom?.style == "dotted")
        for pattern in ["thin", "medium", "thick", "hair", "dashed", "dotted", "double"] {
            var style = CellStyle(); style.top = BorderSide(style: pattern, color: .blue)
            put(&bordered, "A1", .number(1), style)
            let back = (try? ODS.read(ODS.write(bordered)))?.sheets[0][ref("A1")].style.top
            check("ODS preserves \(pattern) border thickness", back?.style == pattern && back?.width == style.top?.width)
        }

        var styled = Workbook()
        var parent = CellStyle(); parent.bold = true; parent.italic = true; parent.underline = true; parent.fill = .red; parent.wrap = true; parent.locked = false; parent.rotation = 30
        styled.cellStyles["Input Base"] = parent
        var direct = CellStyle(); direct.styleName = "Input Base"
        put(&styled, "A1", .string("Direct reset"), direct)
        if let back = try? ODS.read(ODS.write(styled)) {
            let style = back.sheets[0][ref("A1")].style
            check("ODS direct formatting can disable inherited font effects", !style.bold && !style.italic && !style.underline)
            check("ODS direct formatting can clear parent fill, wrap and rotation", style.fill == nil && !style.wrap && style.rotation == 0)
            check("ODS direct formatting can relock an unlocked named style", style.locked)
        } else { check("ODS named-style resets open", false) }

        var names = Workbook(); names.sheets[0].name = "Plan 1, O'Brien"
        put(&names, "A1", .number(5))
        names.names = ["TaxRate": "0.2", "TotalValue": "'Plan 1, O''Brien'!$A$1*2", "InputRange": "'Plan 1, O''Brien'!$A$1:$A$3"]
        names.sheets[0].printArea = CellRange("A1:D8")!
        for (kind, data) in formats(names) {
            let back = try? SpreadsheetFile.read(data)
            check("\(kind) named constant survives", back?.names["TaxRate"] == "0.2")
            check("\(kind) named expression survives", back?.names["TotalValue"] == names.names["TotalValue"])
            check("\(kind) quoted-sheet print area survives", back?.sheets[0].printArea == names.sheets[0].printArea)
        }

        // A 1904 workbook retains serials, formulas and its epoch through either format.
        var dated = Workbook(); dated.date1904 = true
        var dateStyle = CellStyle(); dateStyle.numberFormat = "yyyy-mm-dd"
        put(&dated, "A1", .number(0), dateStyle)
        put(&dated, "A2", .number(1.5), dateStyle)
        for (kind, data) in formats(dated) {
            let back = try? SpreadsheetFile.read(data)
            check("\(kind) retains 1904 date system and serial values", back?.date1904 == true && back?.sheets[0][ref("A1")].value == .number(0) && back?.sheets[0][ref("A2")].value == .number(1.5))
            check("\(kind) 1904 dates have correct editing text", back?.sheets[0][ref("A1")].input == "01.01.1904" && back?.sheets[0][ref("A2")].input == "02.01.1904 12:00")
        }

        // File conversion can occur before recalculation has rebuilt spill caches.
        var fixedArray = Workbook()
        var anchor = Cell(); anchor.input = "=A1:A2*2"; anchor.array = true; anchor.value = .number(2)
        fixedArray.sheets[0][ref("B1")] = anchor
        fixedArray.sheets[0].arrays[ref("B1")] = CellRange("B1:B2")!
        for (kind, data) in formats(fixedArray) {
            let back = try? SpreadsheetFile.read(data)
            check("\(kind) fixed array bounds survive without a recalculation cache", back?.sheets[0].arrays[ref("B1")] == CellRange("B1:B2")!)
        }

        // Invalid indices and dimensions must not reach Swift array/range traps.
        let hostileXLSX = xlsx(literals) { zip in
            zip["xl/worksheets/sheet1.xml"] = Data("""
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView><pane state="frozen" xSplit="NaN" ySplit="-3"/></sheetView></sheetViews><cols><col min="9" max="3"/><col min="9223372036854775807" max="9223372036854775807"/></cols><sheetData><row r="1"><c r="A1" s="-1" t="s"><v>-1</v></c><c r="B1" t="n"><v>42</v></c></row></sheetData><conditionalFormatting sqref="B1"><cfRule type="expression" dxfId="-1"><formula>1</formula></cfRule></conditionalFormatting></worksheet>
            """.utf8)
            zip["xl/styles.xml"] = Data("""
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts><font><color theme="-1"/></font><font><color indexed="-1"/></font></fonts><fills><fill/></fills><borders><border/></borders><cellXfs><xf fontId="-1" fillId="-1" borderId="-1"/></cellXfs></styleSheet>
            """.utf8)
        }
        let safe = try? XLSX.read(hostileXLSX)
        check("XLSX invalid indices/dimensions do not corrupt valid neighboring cells", safe?.sheets[0][ref("B1")].value == .number(42) && safe?.sheets[0].frozenRows == 0 && safe?.sheets[0].frozenCols == 0)
        let columns = xlsx(Workbook()) { zip in
            zip["xl/worksheets/sheet1.xml"] = Data("<worksheet><cols><col min=\"1\" max=\"1201\" width=\"20\"/></cols><sheetData/></worksheet>".utf8)
        }
        check("XLSX column settings beyond the old 1000-column cutoff survive", (try? XLSX.read(columns))?.sheets[0].columnWidths[1200] != nil)
        let repeated = try? ODS.read(ods("<table:table-row table:number-rows-repeated=\"1001\"><table:table-cell office:value-type=\"float\" office:value=\"7\"/></table:table-row>"))
        check("ODS repeated content rows beyond 1000 survive", repeated?.sheets[0][ref("A1001")].value == .number(7))
        let repeatedColumns = try? ODS.read(ods("<table:table-row><table:table-cell table:number-columns-repeated=\"1025\" office:value-type=\"float\" office:value=\"7\"/></table:table-row>"))
        check("ODS repeated content columns beyond 1024 survive", repeatedColumns?.sheets[0][CellRef(row: 0, col: 1024)].value == .number(7))
        rejectsODS("ODS rejects negative row repetition", "<table:table-row table:number-rows-repeated=\"-1\"/>")
        rejectsODS("ODS rejects negative column repetition", "<table:table-row><table:covered-table-cell table:number-columns-repeated=\"-3\"/></table:table-row>")
        rejectsODS("ODS rejects overflowing row repetition", "<table:table-row table:number-rows-repeated=\"9223372036854775807\"/>")
        rejectsODS("ODS rejects overflowing merge dimensions", "<table:table-row><table:table-cell table:number-columns-spanned=\"9223372036854775807\"/></table:table-row>")
        rejectsODS("ODS rejects overflowing matrix dimensions", "<table:table-row><table:table-cell table:formula=\"of:=1\" table:number-matrix-columns-spanned=\"9223372036854775807\" table:number-matrix-rows-spanned=\"2\"/></table:table-row>")
        let spaceData = ods("<table:table-row><table:table-cell office:value-type=\"string\"><text:p>A<text:s text:c=\"-3\"/>B</text:p></table:table-cell></table:table-row>")
        check("ODS malformed repeated spaces are bounded", (try? ODS.read(spaceData))?.sheets[0][ref("A1")].value == .string("A B"))
        print("XLS deep file regressions: \(checks - failed)/\(checks) passed")
        return failed
    }
}
