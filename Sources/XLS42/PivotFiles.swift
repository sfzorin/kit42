import AppKit
import Kit42

/// Pivot tables in files: .xlsx pivot cache + pivot table parts, .ods `table:data-pilot-tables`.
/// The result cells are written to the sheet as usual (viewers without pivot support show them);
/// the definition lets Excel / LibreOffice treat the block as a pivot table and lets XLS42 refresh it
/// after reopening.
enum PivotFiles {
    static let subtotals: [PivotSpec.Aggregate: String] = [.sum: "sum", .count: "count", .average: "average", .min: "min", .max: "max"]

    static func aggregate(_ name: String?) -> PivotSpec.Aggregate {
        switch name?.lowercased() {
        case "count", "countnums": return .count
        case "average": return .average
        case "min": return .min
        case "max": return .max
        default: return .sum
        }
    }

    /// Result block size for the spec (matches `Pivot.build`): header rows + keys + grand total.
    static func location(_ spec: PivotSpec, rows: Int, cols: Int) -> CellRange {
        let a = spec.anchor
        let height = spec.colField == nil ? rows + 2 : rows + 3
        let width = spec.colField == nil ? 2 : cols + 2
        return CellRange(a, CellRef(row: a.row + height - 1, col: a.col + width - 1))
    }

    private static func number(_ d: Double) -> String { Value.formatGeneral(d) }

    // MARK: - .xlsx writing

    struct XLSXPart { var types: String; var cacheEntry: String; var workbookRel: String }

    /// Writes pivotCacheDefinition<n>.xml and pivotTable<n>.xml for the pivot on sheet `sheetNumber` (1-based).
    static func writeXLSX(_ spec: PivotSpec, workbook: Workbook, sheetNumber: Int, n: Int, zip: inout ZipArchive) -> XLSXPart? {
        guard let si = workbook.sheetIndex(named: spec.sourceSheet), spec.source.rows.count >= 2 else { return nil }
        let src = workbook.sheets[si]
        let names = Pivot.headers(src, spec.source)
        guard spec.rowField < names.count, spec.valueField < names.count, (spec.colField ?? 0) < names.count else { return nil }
        let (rowKeys, colKeys) = Pivot.axisKeys(spec, workbook: workbook)
        let axis = Set([spec.rowField] + (spec.colField.map { [$0] } ?? []))
        var fieldKeys: [Int: [Pivot.Key]] = [:]

        // Cache definition: source range, one cache field per source column with its distinct items.
        var cache = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <pivotCacheDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" saveData="0" refreshOnLoad="1" \
        createdVersion="3" refreshedVersion="3" minRefreshableVersion="3" recordCount="\(spec.source.rows.count - 1)">\
        <cacheSource type="worksheet"><worksheetSource ref="\(spec.source.a1)" sheet="\(xmlEscape(spec.sourceSheet))"/></cacheSource>\
        <cacheFields count="\(names.count)">
        """
        var used = Set<String>()
        for (i, name) in names.enumerated() {
            // Cache field names must be unique.
            var unique = name, k = 2
            while used.contains(unique.lowercased()) { unique = "\(name)\(k)"; k += 1 }
            used.insert(unique.lowercased())
            cache += "<cacheField name=\"\(xmlEscape(unique))\" numFmtId=\"0\">"
            let c = spec.source.start.col + i
            let values = (spec.source.start.row + 1...spec.source.end.row).map { src[CellRef(row: $0, col: c)].value }
            let nums = values.compactMap { v -> Double? in if case .number(let d) = v { return d }; return nil }
            let hasBlank = values.contains { $0.isEmpty }
            let hasText = values.contains { if case .number = $0 { return false }; return !$0.isEmpty }
            var attrs = ""
            if !hasText && !nums.isEmpty {
                attrs = " containsSemiMixedTypes=\"0\" containsString=\"0\" containsNumber=\"1\""
                if nums.allSatisfy({ $0 == $0.rounded() }) { attrs += " containsInteger=\"1\"" }
                attrs += " minValue=\"\(number(nums.min()!))\" maxValue=\"\(number(nums.max()!))\""
            } else if hasText && !nums.isEmpty {
                attrs = " containsMixedTypes=\"1\" containsNumber=\"1\" minValue=\"\(number(nums.min()!))\" maxValue=\"\(number(nums.max()!))\""
            }
            if hasBlank { attrs += " containsBlank=\"1\"" }
            if axis.contains(i) {
                let keys = Pivot.keys(src, spec.source, field: i)
                fieldKeys[i] = keys
                cache += "<sharedItems\(attrs) count=\"\(keys.count)\">"
                for key in keys {
                    if key.blank { cache += "<m/>" }
                    else if let d = key.number { cache += "<n v=\"\(number(d))\"/>" }
                    else { cache += "<s v=\"\(xmlEscape(key.text))\"/>" }
                }
                cache += "</sharedItems>"
            } else {
                cache += "<sharedItems\(attrs)/>"
            }
            cache += "</cacheField>"
        }
        cache += "</cacheFields></pivotCacheDefinition>"

        // Pivot table: classic layout (field names in the header row) like the cells XLS42 writes.
        let loc = location(spec, rows: rowKeys.count, cols: colKeys.count)
        let caption = "\(spec.aggregate.title) – \(names[spec.valueField])"
        var t = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <pivotTableDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" name="\(xmlEscape(spec.name))" cacheId="\(n)" \
        applyNumberFormats="0" applyBorderFormats="0" applyFontFormats="0" applyPatternFormats="0" applyAlignmentFormats="0" applyWidthHeightFormats="1" \
        dataCaption="Values" grandTotalCaption="\(xmlEscape(L("Grand Total")))" updatedVersion="3" minRefreshableVersion="3" useAutoFormatting="1" itemPrintTitles="1" \
        createdVersion="3" indent="0" compact="0" compactData="0" outline="1" outlineData="1" gridDropZones="1" multipleFieldFilters="0">\
        <location ref="\(loc.a1)" firstHeaderRow="1" firstDataRow="\(spec.colField == nil ? 1 : 2)" firstDataCol="1"/>\
        <pivotFields count="\(names.count)">
        """
        func index(_ keys: [Pivot.Key], _ field: Int) -> [Int] {
            let all = fieldKeys[field] ?? []
            return keys.compactMap { k in all.firstIndex(of: k) }
        }
        for i in names.indices {
            var f = "<pivotField"
            if i == spec.rowField { f += " axis=\"axisRow\"" } else if i == spec.colField { f += " axis=\"axisCol\"" }
            if i == spec.valueField { f += " dataField=\"1\"" }
            f += " compact=\"0\" outline=\"0\" showAll=\"0\""
            if let keys = fieldKeys[i] {
                f += " defaultSubtotal=\"0\"><items count=\"\(keys.count)\">" + keys.indices.map { "<item x=\"\($0)\"/>" }.joined() + "</items></pivotField>"
            } else { f += "/>" }
            t += f
        }
        t += "</pivotFields>"
        func items(_ list: [Int]) -> String {
            list.map { $0 == 0 ? "<i><x/></i>" : "<i><x v=\"\($0)\"/></i>" }.joined() + "<i t=\"grand\"><x/></i>"
        }
        let rowIdx = index(rowKeys, spec.rowField)
        t += "<rowFields count=\"1\"><field x=\"\(spec.rowField)\"/></rowFields><rowItems count=\"\(rowIdx.count + 1)\">\(items(rowIdx))</rowItems>"
        if let cf = spec.colField {
            let colIdx = index(colKeys, cf)
            t += "<colFields count=\"1\"><field x=\"\(cf)\"/></colFields><colItems count=\"\(colIdx.count + 1)\">\(items(colIdx))</colItems>"
        } else {
            t += "<colItems count=\"1\"><i/></colItems>"
        }
        t += "<dataFields count=\"1\"><dataField name=\"\(xmlEscape(caption))\" fld=\"\(spec.valueField)\" subtotal=\"\(subtotals[spec.aggregate]!)\" baseField=\"0\" baseItem=\"0\"/></dataFields>"
        t += "<pivotTableStyleInfo name=\"PivotStyleLight16\" showRowHeaders=\"1\" showColHeaders=\"1\" showRowStripes=\"0\" showColStripes=\"0\" showLastColumn=\"1\"/></pivotTableDefinition>"

        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        zip["xl/pivotCache/pivotCacheDefinition\(n).xml"] = Data(cache.utf8)
        zip["xl/pivotTables/pivotTable\(n).xml"] = Data(t.utf8)
        zip["xl/pivotTables/_rels/pivotTable\(n).xml.rels"] = Data(relationships(["<Relationship Id=\"rId1\" Type=\"\(rel)/pivotCacheDefinition\" Target=\"../pivotCache/pivotCacheDefinition\(n).xml\"/>"]).utf8)
        // Add the pivot table to the sheet's relationships (written by writeExtras, if any).
        let sheetRels = "xl/worksheets/_rels/sheet\(sheetNumber).xml.rels"
        let entry = "<Relationship Id=\"rIdPivot\(n)\" Type=\"\(rel)/pivotTable\" Target=\"../pivotTables/pivotTable\(n).xml\"/>"
        if let existing = zip.string(sheetRels), let end = existing.range(of: "</Relationships>") {
            var s = existing
            s.insert(contentsOf: entry, at: end.lowerBound)
            zip[sheetRels] = Data(s.utf8)
        } else {
            zip[sheetRels] = Data(relationships([entry]).utf8)
        }
        let types = "<Override PartName=\"/xl/pivotCache/pivotCacheDefinition\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml\"/>"
            + "<Override PartName=\"/xl/pivotTables/pivotTable\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml\"/>"
        return XLSXPart(types: types, cacheEntry: "<pivotCache cacheId=\"\(n)\" r:id=\"rIdPivotCache\(n)\"/>",
                        workbookRel: "<Relationship Id=\"rIdPivotCache\(n)\" Type=\"\(rel)/pivotCacheDefinition\" Target=\"pivotCache/pivotCacheDefinition\(n).xml\"/>")
    }

    private static func relationships(_ items: [String]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + items.joined() + "</Relationships>"
    }

    // MARK: - .xlsx reading

    /// Reads the pivot tables of the sheets (`sheetPaths[i]` = part of `wb.sheets[i]`); the first one per sheet is kept.
    static func readXLSX(_ wb: inout Workbook, zip: ZipArchive, workbookXML: XMLElement, workbookRels: [String: String], sheetPaths: [String]) {
        func xml(_ path: String) -> XMLElement? { zip[path].flatMap { try? XMLDocument(data: $0) }?.rootElement() }
        var caches: [String: String] = [:]
        for c in workbookXML.child("pivotCaches")?.children("pivotCache") ?? [] {
            if let id = c.attr("cacheId"), let rid = c.attr("id"), let path = workbookRels[rid] { caches[id] = path }
        }
        guard !caches.isEmpty else { return }
        for (i, path) in sheetPaths.enumerated() where i < wb.sheets.count {
            let dir = (path as NSString).deletingLastPathComponent
            let rels = XLSX.relations(zip, dir + "/_rels/" + (path as NSString).lastPathComponent + ".rels", base: dir)
            for (_, (type, target)) in rels.sorted(by: { $0.key < $1.key }) where type.hasSuffix("/pivotTable") {
                guard let table = xml(target), let cacheId = table.attr("cacheId") else { continue }
                // The cache: by the table's own relationship, else by the workbook's cacheId.
                let tdir = (target as NSString).deletingLastPathComponent
                let trels = XLSX.relations(zip, tdir + "/_rels/" + (target as NSString).lastPathComponent + ".rels", base: tdir)
                let cachePath = trels.values.first { $0.0.hasSuffix("/pivotCacheDefinition") }?.1 ?? caches[cacheId]
                guard let cachePath, let cache = xml(cachePath),
                      var spec = spec(table: table, cache: cache, workbook: wb, sheet: wb.sheets[i].name) else { continue }
                // Keep the cells as they are; refresh rebuilds them in XLS42's layout.
                spec.location = table.child("location")?.attr("ref").flatMap(CellRange.init)
                wb.sheets[i].pivot = spec
                break
            }
        }
    }

    private static func spec(table: XMLElement, cache: XMLElement, workbook wb: Workbook, sheet: String) -> PivotSpec? {
        guard let ws = cache.child("cacheSource")?.child("worksheetSource") else { return nil }
        var sourceSheet = ws.attr("sheet")
        var ref = ws.attr("ref")
        if ref == nil, let name = ws.attr("name"), let def = wb.names[name] {
            let parts = def.split(separator: "!")
            if parts.count == 2 { sourceSheet = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            ref = String(parts.last ?? "")
        }
        guard let ref, let source = CellRange(ref.replacingOccurrences(of: "$", with: "")) else { return nil }
        let names = (cache.child("cacheFields")?.children("cacheField") ?? []).map { $0.attr("name") ?? "" }
        let rows = (table.child("rowFields")?.children("field") ?? []).compactMap { $0.attr("x").flatMap(Int.init) }.filter { $0 >= 0 }
        let cols = (table.child("colFields")?.children("field") ?? []).compactMap { $0.attr("x").flatMap(Int.init) }.filter { $0 >= 0 }
        guard let data = table.child("dataFields")?.children("dataField").first, let fld = data.attr("fld").flatMap(Int.init) else { return nil }
        guard let rowField = rows.first ?? cols.first else { return nil }
        let colField = rows.isEmpty ? cols.dropFirst().first : cols.first
        var spec = PivotSpec(sourceSheet: sourceSheet ?? sheet, source: source, rowField: rowField, colField: colField,
                             valueField: fld, aggregate: aggregate(data.attr("subtotal")))
        spec.name = table.attr("name") ?? "PivotTable1"
        spec.fieldNames = names
        if let loc = table.child("location")?.attr("ref").flatMap(CellRange.init) { spec.anchor = loc.start }
        return spec
    }

    // MARK: - .ods

    private static func odfName(_ sheet: String) -> String {
        sheet.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } ? sheet : "'" + sheet.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func odfAddress(_ sheet: String, _ r: CellRange) -> String {
        let s = odfName(sheet)
        return "\(s).\(r.start.a1):\(s).\(r.end.a1)"
    }

    /// `<table:data-pilot-tables>` for all pivot sheets ("" when there are none).
    static func odsXML(_ wb: Workbook) -> String {
        var out = ""
        for sheet in wb.sheets {
            guard let spec = sheet.pivot, let si = wb.sheetIndex(named: spec.sourceSheet) else { continue }
            let names = Pivot.headers(wb.sheets[si], spec.source)
            guard spec.rowField < names.count, spec.valueField < names.count, (spec.colField ?? 0) < names.count else { continue }
            let (rows, cols) = Pivot.axisKeys(spec, workbook: wb)
            let target = spec.location ?? location(spec, rows: rows.count, cols: cols.count)
            out += "<table:data-pilot-table table:name=\"\(xmlEscape(spec.name))\" table:target-range-address=\"\(xmlEscape(odfAddress(sheet.name, target)))\" table:buttons=\"\">"
            out += "<table:source-cell-range table:cell-range-address=\"\(xmlEscape(odfAddress(spec.sourceSheet, spec.source)))\"/>"
            out += "<table:data-pilot-field table:source-field-name=\"\(xmlEscape(names[spec.rowField]))\" table:orientation=\"row\" table:function=\"none\"/>"
            if let cf = spec.colField {
                out += "<table:data-pilot-field table:source-field-name=\"\(xmlEscape(names[cf]))\" table:orientation=\"column\" table:function=\"none\"/>"
            }
            out += "<table:data-pilot-field table:source-field-name=\"\(xmlEscape(names[spec.valueField]))\" table:orientation=\"data\" table:function=\"\(subtotals[spec.aggregate]!)\"/>"
            out += "</table:data-pilot-table>"
        }
        return out.isEmpty ? "" : "<table:data-pilot-tables>\(out)</table:data-pilot-tables>"
    }

    static func readODS(_ spreadsheet: XMLElement, _ wb: inout Workbook) {
        for dp in spreadsheet.child("data-pilot-tables")?.children("data-pilot-table") ?? [] {
            guard let target = dp.attr("target-range-address").flatMap(ODS.rangeFromODF),
                  let targetSheet = target.sheet.flatMap(wb.sheetIndex(named:)),
                  let targetRange = CellRange(target.range.replacingOccurrences(of: "$", with: "")),
                  wb.sheets[targetSheet].pivot == nil,
                  let src = dp.child("source-cell-range")?.attr("cell-range-address").flatMap(ODS.rangeFromODF),
                  let srcSheet = src.sheet.flatMap(wb.sheetIndex(named:)),
                  let source = CellRange(src.range.replacingOccurrences(of: "$", with: "")) else { continue }
            let names = Pivot.headers(wb.sheets[srcSheet], source)
            var row: Int?, col: Int?, data: (Int, PivotSpec.Aggregate)?
            for f in dp.children("data-pilot-field") where f.attr("is-data-layout-field") != "true" {
                guard let name = f.attr("source-field-name"), let i = names.firstIndex(of: name) else { continue }
                switch f.attr("orientation") {
                case "row": if row == nil { row = i }
                case "column": if col == nil { col = i }
                case "data": if data == nil { data = (i, aggregate(f.attr("function"))) }
                default: break
                }
            }
            guard let r = row ?? col, let (value, agg) = data else { continue }
            var spec = PivotSpec(sourceSheet: wb.sheets[srcSheet].name, source: source, rowField: r,
                                 colField: row == nil ? nil : col, valueField: value, aggregate: agg)
            spec.name = dp.attr("name") ?? "DataPilot1"
            spec.fieldNames = names
            spec.anchor = targetRange.start
            spec.location = targetRange
            wb.sheets[targetSheet].pivot = spec
        }
    }
}
