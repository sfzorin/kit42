import AppKit
import Kit42

/// Self-test of pivot tables saved in files (.xlsx pivot parts, .ods data pilot) and of refresh after reopening.
extension SelfTest {
    static func constantCell(_ input: String) -> Cell {
        var c = Cell()
        c.input = input
        c.value = XLSX.constant(input)
        return c
    }

    /// Data sheet + "Cross" (Region × Product, sum) + "ByRegion" (average, no column field).
    static func pivotDemo() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "Data"
        let rows = [["Region", "Product", "Amount"], ["North", "A", "10"], ["South", "A", "5"], ["North", "B", "7"],
                    ["East", "B", "4"], ["North", "A", "3"], ["South", "C", "8"]]
        for (r, row) in rows.enumerated() { for (c, v) in row.enumerated() { wb.sheets[0][CellRef(row: r, col: c)] = constantCell(v) } }
        var cross = PivotSpec(sourceSheet: "Data", source: CellRange("A1:C7")!, rowField: 0, colField: 1, valueField: 2, aggregate: .sum)
        cross.name = "PivotTable1"
        var avg = PivotSpec(sourceSheet: "Data", source: CellRange("A1:C7")!, rowField: 0, colField: nil, valueField: 2, aggregate: .average)
        avg.name = "PivotTable2"
        if let s = Pivot.build(cross, workbook: wb, name: "Cross") { wb.sheets.append(s) }
        if let s = Pivot.build(avg, workbook: wb, name: "ByRegion") { wb.sheets.append(s) }
        return wb
    }

    static func pivotFiles() -> Int {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print(ok ? "ok  " : "FAIL", name, ok ? "" : detail())
            if !ok { failed += 1 }
        }
        func values(_ s: Sheet) -> [String: String] {
            Dictionary(uniqueKeysWithValues: s.cells.filter { !$0.value.value.isEmpty }.map { ($0.key.a1, $0.value.value.plain) })
        }
        let wb = pivotDemo()
        check("pivot demo has two pivot sheets", wb.sheets.count == 3 && wb.sheets[1].pivot != nil && wb.sheets[2].pivot != nil)
        let cross = wb.sheets[1], byRegion = wb.sheets[2]
        check("pivot location covers the result", cross.pivot?.location == CellRange("A1:E6") && byRegion.pivot?.location == CellRange("A1:B5"),
              "\(cross.pivot?.location?.a1 ?? "-") \(byRegion.pivot?.location?.a1 ?? "-")")

        for (format, data) in [("xlsx", XLSX.write(wb)), ("ods", ODS.write(wb))] {
            guard var back = try? SpreadsheetFile.read(data), back.sheets.count == 3 else { check("\(format) pivot file reads back", false); continue }
            let p = back.sheets[1].pivot, q = back.sheets[2].pivot
            check("\(format) pivot definition round trip", p?.sourceSheet == "Data" && p?.source == CellRange("A1:C7") && p?.rowField == 0
                  && p?.colField == 1 && p?.valueField == 2 && p?.aggregate == .sum && p?.anchor == CellRef(row: 0, col: 0)
                  && q?.colField == nil && q?.aggregate == .average && q?.name == "PivotTable2",
                  "\(String(describing: p)) \(String(describing: q))")
            check("\(format) pivot cells kept", values(back.sheets[1]) == values(cross), "\(values(back.sheets[1]))")
            Pivot.refresh(&back, sheet: 1)
            Pivot.refresh(&back, sheet: 2)
            check("\(format) refresh after reopening gives the same result", values(back.sheets[1]) == values(cross) && values(back.sheets[2]) == values(byRegion),
                  "\(values(back.sheets[1]))\n\(values(cross))")
            // The source grows by a row: refresh uses the current region.
            for (c, v) in ["West", "C", "100"].enumerated() { back.sheets[0][CellRef(row: 7, col: c)] = constantCell(v) }
            Pivot.refresh(&back, sheet: 1)
            let s = back.sheets[1]
            check("\(format) refresh follows a grown source", s.pivot?.source == CellRange("A1:C8") && s[CellRef("A6")!].value == .string("West")
                  && s[CellRef("E7")!].value == .number(137) && s[CellRef("A8")!].value.isEmpty,
                  "\(s.pivot?.source.a1 ?? "-") \(values(s))")
            // ... and shrinks: old rows of the result are cleared.
            for c in 0...2 { back.sheets[0][CellRef(row: 7, col: c)] = Cell(); back.sheets[0][CellRef(row: 6, col: c)] = Cell() }
            Pivot.refresh(&back, sheet: 1)
            let t = back.sheets[1]
            check("\(format) refresh follows a shrunk source", t.pivot?.source == CellRange("A1:C6") && t[CellRef("D6")!].value == .number(29)
                  && t[CellRef("E6")!].value.isEmpty && t[CellRef("A7")!].value.isEmpty && t.pivot?.location == CellRange("A1:D6"), "\(values(t))")
        }

        // Fields follow their names when source columns are reordered.
        var moved = wb
        for r in 0...6 {
            let a = moved.sheets[0][CellRef(row: r, col: 0)], b = moved.sheets[0][CellRef(row: r, col: 1)]
            moved.sheets[0][CellRef(row: r, col: 0)] = b
            moved.sheets[0][CellRef(row: r, col: 1)] = a
        }
        let up = Pivot.updated(cross.pivot!, workbook: moved)
        check("pivot fields follow header names", up.rowField == 1 && up.colField == 0 && up.valueField == 2, "\(up.rowField) \(String(describing: up.colField))")

        // A pivot table made elsewhere (LibreOffice's .xlsx export: compact layout at A3, empty cells) refreshes in place.
        var plain = wb
        plain.sheets.removeLast(2)
        var other = Sheet(name: "Pivot")
        other[CellRef("A1")!] = constantCell("note")
        plain.sheets.append(other)
        var zip = try! ZipArchive(data: XLSX.write(plain))
        let ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        zip["xl/pivotCache/pivotCacheDefinition1.xml"] = Data("""
        <pivotCacheDefinition \(ns) recordCount="6"><cacheSource type="worksheet"><worksheetSource ref="A1:C7" sheet="Data"/></cacheSource>\
        <cacheFields count="3"><cacheField name="Region" numFmtId="0"><sharedItems/></cacheField><cacheField name="Product" numFmtId="0"><sharedItems/></cacheField>\
        <cacheField name="Amount" numFmtId="0"><sharedItems/></cacheField></cacheFields></pivotCacheDefinition>
        """.utf8)
        zip["xl/pivotTables/pivotTable1.xml"] = Data("""
        <pivotTableDefinition \(ns) name="DataPilot1" cacheId="7" dataCaption="Values" compact="1"><location ref="A3:B8" firstHeaderRow="1" firstDataRow="1" firstDataCol="1"/>\
        <pivotFields count="3"><pivotField axis="axisRow" showAll="0"/><pivotField showAll="0"/><pivotField dataField="1" showAll="0"/></pivotFields>\
        <rowFields count="1"><field x="0"/></rowFields><colFields count="1"><field x="-2"/></colFields>\
        <dataFields count="1"><dataField name="Max - Amount" fld="2" subtotal="max"/></dataFields></pivotTableDefinition>
        """.utf8)
        zip["xl/worksheets/_rels/sheet2.xml.rels"] = Data("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotTable" Target="../pivotTables/pivotTable1.xml"/></Relationships>
        """.utf8)
        var wbXML = zip.string("xl/workbook.xml")!
        wbXML = wbXML.replacingOccurrences(of: "</workbook>", with: "<pivotCaches><pivotCache cacheId=\"7\" r:id=\"rIdX\"/></pivotCaches></workbook>")
        zip["xl/workbook.xml"] = Data(wbXML.utf8)
        var rels = zip.string("xl/_rels/workbook.xml.rels")!
        rels = rels.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"rIdX\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/pivotCacheDefinition\" Target=\"pivotCache/pivotCacheDefinition1.xml\"/></Relationships>")
        zip["xl/_rels/workbook.xml.rels"] = Data(rels.utf8)
        if var foreign = try? XLSX.read(zip.data()), foreign.sheets.count == 2, let p = foreign.sheets[1].pivot {
            check("foreign pivot table read", p.anchor == CellRef("A3") && p.rowField == 0 && p.colField == nil && p.aggregate == .max
                  && p.location == CellRange("A3:B8") && p.name == "DataPilot1", "\(p)")
            Pivot.refresh(&foreign, sheet: 1)
            let s = foreign.sheets[1]
            check("foreign pivot refreshes at its anchor", s[CellRef("A1")!].value == .string("note") && s[CellRef("A3")!].value == .string("Region")
                  && s[CellRef("A4")!].value == .string("East") && s[CellRef("B5")!].value == .number(10) && s[CellRef("B7")!].value == .number(10)
                  && s[CellRef("A8")!].value.isEmpty && s.pivot?.location == CellRange("A3:B7"), "\(values(s))")
        } else { check("foreign pivot table read", false) }
        return failed
    }
}
