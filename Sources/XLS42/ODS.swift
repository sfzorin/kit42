import AppKit
import Kit42

/// OpenDocument Spreadsheet (.ods, LibreOffice/OpenOffice): reading and writing.
/// Values, formulas (OpenFormula ↔ Excel syntax), cell styles, number formats, column widths,
/// row heights, merges, freeze panes, comments, print ranges and named ranges.
enum ODS {
    // MARK: - Reading

    struct StyleInfo {
        var style = CellStyle()
        var columnWidth: CGFloat?
        var rowHeight: CGFloat?
        var dataStyle: String?
        var parent: String?
    }

    static func read(_ data: Data) throws -> Workbook {
        let zip = try ZipArchive(data: data)
        func xml(_ path: String) -> XMLElement? {
            guard let d = zip[path] else { return nil }
            return (try? XMLDocument(data: d, options: [.nodePreserveWhitespace]))?.rootElement()
        }
        guard let content = xml("content.xml"), let spreadsheet = content.child("body")?.child("spreadsheet") else { throw ZipError.corrupt }
        let stylesRoot = xml("styles.xml")

        // Styles: common (styles.xml) then automatic (content.xml); number styles from both.
        var numberFormats: [String: String] = [:]
        var styles: [String: StyleInfo] = [:]
        for container in [stylesRoot?.child("styles"), stylesRoot?.child("automatic-styles"), content.child("automatic-styles")] {
            guard let container else { continue }
            for e in (container.children ?? []).compactMap({ $0 as? XMLElement }) {
                if let name = e.attr("name"), let code = numberFormat(e) { numberFormats[name] = code }
                if e.localName == "style", let name = e.attr("name") { styles[name] = styleInfo(e) }
                if e.localName == "default-style", e.attr("family") == "table-cell" { styles["__default"] = styleInfo(e) }
            }
        }
        func resolved(_ name: String?) -> CellStyle {
            var chain: [StyleInfo] = []
            var n = name
            var seen = Set<String>()
            while let k = n, let s = styles[k], !seen.contains(k) { seen.insert(k); chain.insert(s, at: 0); n = s.parent }
            var out = styles["__default"]?.style ?? CellStyle()
            for s in chain { out = merge(out, s.style) }
            if let ds = chain.last(where: { $0.dataStyle != nil })?.dataStyle, let code = numberFormats[ds] { out.numberFormat = code }
            return out
        }
        var styleCache: [String: CellStyle] = [:]
        func cellStyle(_ name: String?) -> CellStyle {
            let key = name ?? ""
            if let s = styleCache[key] { return s }
            let s = resolved(name)
            styleCache[key] = s
            return s
        }

        var wb = Workbook()
        wb.sheets = []
        let validationRules = readValidations(spreadsheet)
        for table in spreadsheet.children("table") {
            var sheet = Sheet(name: table.attr("name") ?? "Sheet\(wb.sheets.count + 1)")
            if table.attr("protected") == "true" {
                // LibreOffice may chain two digests (legacy Excel hash, then SHA-1).
                let digests = [table.attr("protection-key-digest-algorithm") ?? sha1Digest, table.attr("protection-key-digest-algorithm-2")]
                sheet.protection = SheetProtection(odsKey: table.attr("protection-key"), odsDigest: digests.compactMap { $0 }.joined(separator: " "))
                if digests[1] == nil, digests[0] == legacyExcelDigest, let raw = table.attr("protection-key").flatMap({ Data(base64Encoded: $0) }), raw.count == 2 {
                    sheet.protection?.passwordHash = String(format: "%02X%02X", raw[0], raw[1])
                }
            }
            var validationCells: [String: [CellRef]] = [:]
            var matrixRanges: [CellRange] = []
            var col = 0
            var columnDefault: [Int: String] = [:]
            for (c, level) in outlined(table, "table-column", group: "table-column-group") {
                let n = min(Int(c.attr("number-columns-repeated") ?? "1") ?? 1, 1024)
                let w = c.attr("style-name").flatMap { styles[$0]?.columnWidth }
                let hidden = c.attr("visibility") == "collapse"
                let defaultStyle = c.attr("default-cell-style-name").flatMap { $0 == "Default" ? nil : $0 }
                for k in 0..<n where col + k < 1024 {
                    if level > 0 { sheet.colLevels[col + k] = min(level, Sheet.maxOutlineLevel) }
                    if hidden && level > 0 {
                        sheet.outlineHiddenCols.insert(col + k)
                        if let w, abs(w - sheet.defaultColumnWidth) > 0.5 { sheet.columnWidths[col + k] = w }
                    }
                    else if hidden { sheet.columnWidths[col + k] = 0 }
                    else if let w, abs(w - sheet.defaultColumnWidth) > 0.5, n < 1024 { sheet.columnWidths[col + k] = w }
                    if let defaultStyle { columnDefault[col + k] = defaultStyle }
                }
                col += n
            }
            var row = 0
            for (r, level) in outlined(table, "table-row", group: "table-row-group") {
                let repeatRows = Int(r.attr("number-rows-repeated") ?? "1") ?? 1
                let cells = r.children ?? []
                let rowHeight = r.attr("style-name").flatMap { styles[$0]?.rowHeight }
                let collapsed = r.attr("visibility") == "collapse"
                if level > 0 {
                    for k in 0..<min(repeatRows, 1000) {
                        sheet.rowLevels[row + k] = min(level, Sheet.maxOutlineLevel)
                        if collapsed { sheet.outlineHiddenRows.insert(row + k) }
                    }
                }
                let hasContent = cells.contains { ($0 as? XMLElement).map {
                    $0.attr("value-type") != nil || $0.attr("formula") != nil || $0.attr("content-validation-name") != nil || !($0.children ?? []).isEmpty } ?? false }
                if !hasContent {
                    if collapsed && level == 0 { for k in 0..<min(repeatRows, 1000) { sheet.rowHeights[row + k] = 0 } }
                    row += repeatRows
                    continue
                }
                for k in 0..<min(repeatRows, 1000) {
                    let rr = row + k
                    if collapsed && level == 0 { sheet.rowHeights[rr] = 0 }
                    else if let rowHeight, abs(rowHeight - sheet.defaultRowHeight) > 0.6 { sheet.rowHeights[rr] = rowHeight }
                    var c = 0
                    for case let cellXML as XMLElement in cells {
                        let repeatCols = Int(cellXML.attr("number-columns-repeated") ?? "1") ?? 1
                        guard cellXML.localName == "table-cell" else { c += repeatCols; continue }
                        if let name = cellXML.attr("content-validation-name"), validationRules[name] != nil {
                            for kc in 0..<min(repeatCols, 1024) { validationCells[name, default: []].append(CellRef(row: rr, col: c + kc)) }
                        }
                        let (value, formula) = cellValue(cellXML)
                        let comment = cellXML.child("annotation").map { a in
                            a.children("p").map(\.allTextODF).joined(separator: "\n")
                        }
                        let explicit = cellXML.attr("style-name") ?? r.attr("default-cell-style-name")
                        // Empty cells only matter when their style is visible (fill or borders).
                        let isEmpty = value.isEmpty && formula == nil && comment == nil
                        if isEmpty {
                            let st = cellStyle(explicit ?? columnDefault[c])
                            if st.fill == nil && st.left == nil && st.right == nil && st.top == nil && st.bottom == nil { c += repeatCols; continue }
                        }
                        for kc in 0..<min(repeatCols, isEmpty ? 256 : 1024) {
                            let ref = CellRef(row: rr, col: c + kc)
                            let style = cellStyle(explicit ?? columnDefault[c + kc])
                            var cell = Cell()
                            cell.style = style
                            cell.value = value
                            if let formula {
                                cell.input = formula
                                if let cs = cellXML.attr("number-matrix-columns-spanned").flatMap(Int.init),
                                   let rs = cellXML.attr("number-matrix-rows-spanned").flatMap(Int.init) {
                                    cell.array = true
                                    if cs * rs > 1 { matrixRanges.append(CellRange(ref, CellRef(row: ref.row + rs - 1, col: ref.col + cs - 1))) }
                                }
                            } else {
                                cell.input = XLSX.inputText(for: value, style: style)
                                if case .string(let s) = value, XLSX.constant(s) != .string(s) || s.hasPrefix("=") { cell.input = "'" + s }
                            }
                            sheet[ref] = cell
                            if let comment { sheet.comments[ref] = comment }
                        }
                        let colSpan = Int(cellXML.attr("number-columns-spanned") ?? "1") ?? 1
                        let rowSpan = Int(cellXML.attr("number-rows-spanned") ?? "1") ?? 1
                        if colSpan > 1 || rowSpan > 1 {
                            sheet.merges.append(CellRange(CellRef(row: rr, col: c), CellRef(row: rr + rowSpan - 1, col: c + colSpan - 1)))
                        }
                        c += repeatCols
                    }
                }
                row += repeatRows
            }
            for r in matrixRanges {
                for ref in r.cells where ref != r.start {
                    if var c = sheet.cells[ref], !c.isFormula { c.input = ""; sheet.cells[ref] = c }
                }
            }
            matrixRanges = []
            for (name, refs) in validationCells.sorted(by: { $0.key < $1.key }) {
                guard var v = validationRules[name] else { continue }
                v.ranges = ranges(refs)
                sheet.validations.append(v)
            }
            if let ranges = table.attr("print-ranges") {
                sheet.printArea = rangeFromODF(String(ranges.split(separator: " ").first ?? "")).flatMap { CellRange($0.range.replacingOccurrences(of: "$", with: "")) }
            }
            wb.sheets.append(sheet)
        }
        // Named ranges
        for n in spreadsheet.child("named-expressions")?.children("named-range") ?? [] {
            if let name = n.attr("name"), let addr = n.attr("cell-range-address"), let r = rangeFromODF(addr) {
                wb.names[name] = (r.sheet.map { Formula.sheetPrefix($0) } ?? "") + r.range
            }
        }
        PivotFiles.readODS(spreadsheet, &wb)
        // Freeze panes and gridlines from settings.xml
        if let settings = xml("settings.xml") {
            for map in descendantsNamed(settings, "config-item-map-named") where map.attr("name") == "Tables" {
                for entry in map.children("config-item-map-entry") {
                    guard let name = entry.attr("name"), let i = wb.sheetIndex(named: name) else { continue }
                    var items: [String: String] = [:]
                    for item in entry.children("config-item") { if let k = item.attr("name") { items[k] = item.stringValue } }
                    if items["HorizontalSplitMode"] == "2" { wb.sheets[i].frozenCols = Int(items["HorizontalSplitPosition"] ?? "0") ?? 0 }
                    if items["VerticalSplitMode"] == "2" { wb.sheets[i].frozenRows = Int(items["VerticalSplitPosition"] ?? "0") ?? 0 }
                    if items["ShowGrid"] == "false" { wb.sheets[i].showGridlines = false }
                }
            }
        }
        if wb.sheets.isEmpty { wb.sheets = [Sheet(name: "Sheet1")] }
        return wb
    }

    private static func descendantsNamed(_ e: XMLElement, _ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for case let c as XMLElement in e.children ?? [] {
            if c.localName == name { out.append(c) }
            // rows/columns may be grouped in table-header-rows, table-row-group, table-columns…
            else if c.localName != "table-cell" && c.localName != "table-row" { out += descendantsNamed(c, name) }
        }
        return out
    }

    static func cellValue(_ c: XMLElement) -> (Value, String?) {
        var formula: String? = nil
        if let f = c.attr("formula") { formula = excelFormula(f) }
        let text = c.children("p").map(\.allTextODF).joined(separator: "\n")
        switch c.attr("value-type") {
        case "float", "percentage", "currency":
            return (.number(Double(c.attr("value") ?? "") ?? 0), formula)
        case "date":
            let s = c.attr("date-value") ?? ""
            let parts = s.split(separator: "T")
            let d = parts.first.map(String.init) ?? ""
            let nums = d.split(separator: "-").compactMap { Int($0) }
            var serial = nums.count == 3 ? DateMath.serial(year: nums[0], month: nums[1], day: nums[2]) ?? 0 : 0
            if parts.count > 1, let t = DateMath.parseTime(String(parts[1].prefix(8))) { serial += t }
            return (.number(serial), formula)
        case "time":
            return (.number(duration(c.attr("time-value") ?? "")), formula)
        case "boolean":
            return (.bool(c.attr("boolean-value") == "true"), formula)
        case "string":
            return (.string(c.attr("string-value") ?? text), formula)
        default:
            return (text.isEmpty ? .empty : .string(text), formula)
        }
    }

    /// "PT10H30M00S" → fraction of a day.
    static func duration(_ s: String) -> Double {
        var total = 0.0, num = ""
        for ch in s.dropFirst(2) {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            let v = Double(num) ?? 0
            switch ch { case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: break }
            num = ""
        }
        return total / 86400
    }

    /// OpenFormula "of:=SUM([.A1:.B2];['Лист 1'.C3])" → Excel "=SUM(A1:B2;'Лист 1'!C3)".
    static func excelFormula(_ f: String) -> String {
        var s = f
        for prefix in ["of:", "oooc:", "msoxl:"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if !s.hasPrefix("=") { s = "=" + s }
        var out = ""
        var inString = false, braces = 0
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\"" { inString.toggle(); out.append(ch); i = s.index(after: i); continue }
            // Inline arrays: {1;2|3;4} (columns ";", rows "|") → {1,2;3,4}.
            if !inString {
                if ch == "{" { braces += 1 } else if ch == "}" { braces = max(0, braces - 1) }
                if braces > 0, ch == ";" || ch == "|" { out.append(ch == ";" ? "," : ";"); i = s.index(after: i); continue }
            }
            if !inString, ch == "[", let close = s[i...].firstIndex(of: "]") {
                let inner = String(s[s.index(after: i)..<close])
                if let r = rangeFromODF(inner) { out += (r.sheet.map { Formula.sheetPrefix($0) } ?? "") + r.range } else { out += "#REF!" }
                i = s.index(after: close)
                continue
            }
            out.append(ch)
            i = s.index(after: i)
        }
        // ODF names with Excel meanings: FDIST/FINV are the left-tailed F.DIST/F.INV, LEGACY.… the Excel originals.
        for (odf, excel) in [("FDIST", "F.DIST"), ("FINV", "F.INV"), ("SKEWP", "SKEW.P")] {
            out = out.replacingOccurrences(of: "(?<![A-Za-z0-9._])\(odf)\\(", with: excel + "(", options: [.regularExpression, .caseInsensitive])
        }
        for prefix in ["COM.MICROSOFT.", "ORG.OPENOFFICE.", "ORG.LIBREOFFICE.", "LEGACY.", "_xlfn."] { out = out.replacingOccurrences(of: prefix, with: "") }
        return out
    }

    /// ".A1:.B2", "$'Лист 1'.$A$1", "Sheet1.A1:Sheet1.C6" → (sheet, "A1:B2").
    static func rangeFromODF(_ s: String) -> (sheet: String?, range: String)? {
        func part(_ p: Substring) -> (String?, String) {
            var p = p
            var sheet: String? = nil
            if let dot = p.lastIndex(of: ".") {
                var name = String(p[..<dot])
                if name.hasPrefix("$") { name.removeFirst() }
                if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                    name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
                }
                if !name.isEmpty { sheet = name }
                p = p[p.index(after: dot)...]
            }
            return (sheet, String(p))
        }
        let pieces = s.split(separator: ":", maxSplits: 1)
        guard let first = pieces.first else { return nil }
        let (sheet, a) = part(first)
        guard !a.isEmpty else { return nil }
        if pieces.count > 1 {
            let (_, b) = part(pieces[1])
            return (sheet, a + ":" + b)
        }
        return (sheet, a)
    }

    private static func length(_ s: String?) -> CGFloat? {
        guard let s else { return nil }
        let units: [(String, CGFloat)] = [("cm", 28.3465), ("mm", 2.83465), ("in", 72), ("pt", 1), ("pc", 12), ("px", 0.75)]
        for (u, k) in units where s.hasSuffix(u) {
            if let v = Double(s.dropLast(u.count)) { return CGFloat(v) * k }
        }
        return Double(s).map { CGFloat($0) }
    }

    private static func color(_ s: String?) -> NSColor? {
        guard let s, s.hasPrefix("#") else { return nil }
        return XLSX.hexColor(String(s.dropFirst()))
    }

    private static func border(_ s: String?) -> BorderSide? {
        guard let s, s != "none" else { return nil }
        let parts = s.split(separator: " ")
        let width = parts.first.flatMap { length(String($0)) } ?? 0.75
        let style = parts.contains("dashed") ? "dashed" : parts.contains("dotted") ? "dotted" : parts.contains("double") ? "double"
            : width >= 2 ? "thick" : width >= 1.2 ? "medium" : "thin"
        return BorderSide(style: style, color: parts.last.flatMap { color(String($0)) } ?? .black)
    }

    static func styleInfo(_ e: XMLElement) -> StyleInfo {
        var info = StyleInfo()
        info.parent = e.attr("parent-style-name")
        info.dataStyle = e.attr("data-style-name")
        if let t = e.child("text-properties") {
            if let w = t.attr("font-weight") { info.style.bold = w == "bold" || (Int(w) ?? 400) >= 600 }
            if let i = t.attr("font-style") { info.style.italic = i == "italic" || i == "oblique" }
            if let c = color(t.attr("color")) { info.style.textColor = c }
            if let size = length(t.attr("font-size")) { info.style.fontSize = size }
            if let name = t.attr("font-name") ?? t.attr("font-family") { info.style.fontName = name.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            if let u = t.attr("text-underline-style"), u != "none" { info.style.underline = true }
            if let l = t.attr("text-line-through-style"), l != "none" { info.style.strike = true }
        }
        if let p = e.child("table-cell-properties") {
            if let bg = color(p.attr("background-color")) { info.style.fill = bg }
            if let all = border(p.attr("border")) { (info.style.left, info.style.right, info.style.top, info.style.bottom) = (all, all, all, all) }
            if let b = p.attr("border-left") { info.style.left = border(b) }
            if let b = p.attr("border-right") { info.style.right = border(b) }
            if let b = p.attr("border-top") { info.style.top = border(b) }
            if let b = p.attr("border-bottom") { info.style.bottom = border(b) }
            switch p.attr("vertical-align") { case "top": info.style.vAlign = "top"; case "middle": info.style.vAlign = "center"; default: break }
            if p.attr("wrap-option") == "wrap" { info.style.wrap = true }
            if let protect = p.attr("cell-protect") { info.style.locked = protect != "none" && protect != "hidden-and-printable" }
        }
        if let p = e.child("paragraph-properties") {
            switch p.attr("text-align") {
            case "center": info.style.hAlign = "center"
            case "end", "right": info.style.hAlign = "right"
            case "start", "left": info.style.hAlign = "left"
            case "justify": info.style.hAlign = "justify"
            default: break
            }
        }
        if let c = e.child("table-column-properties") { info.columnWidth = length(c.attr("column-width")) }
        if let r = e.child("table-row-properties") { info.rowHeight = length(r.attr("row-height")) }
        return info
    }

    /// Only properties set in `b` override `a`.
    static func merge(_ a: CellStyle, _ b: CellStyle) -> CellStyle {
        var s = a
        let d = CellStyle.default
        if b.fontName != d.fontName { s.fontName = b.fontName }
        if b.fontSize != d.fontSize { s.fontSize = b.fontSize }
        if b.bold != d.bold { s.bold = b.bold }
        if b.italic != d.italic { s.italic = b.italic }
        if b.underline != d.underline { s.underline = b.underline }
        if b.strike != d.strike { s.strike = b.strike }
        if b.textColor != nil { s.textColor = b.textColor }
        if b.fill != nil { s.fill = b.fill }
        if b.hAlign != nil { s.hAlign = b.hAlign }
        if b.vAlign != d.vAlign { s.vAlign = b.vAlign }
        if b.wrap { s.wrap = true }
        if b.locked != d.locked { s.locked = b.locked }
        for (k, v) in [(\CellStyle.left, b.left), (\CellStyle.right, b.right), (\CellStyle.top, b.top), (\CellStyle.bottom, b.bottom)] where v != nil {
            s[keyPath: k] = v
        }
        return s
    }

    /// number:number-style / percentage / currency / date / time → Excel format code.
    static func numberFormat(_ e: XMLElement) -> String? {
        guard let kind = e.localName, kind.hasSuffix("-style"), e.prefix == "number" || e.uri?.contains("datastyle") == true else { return nil }
        var code = ""
        for case let p as XMLElement in e.children ?? [] {
            switch p.localName {
            case "number":
                let decimals = Int(p.attr("decimal-places") ?? "0") ?? 0
                let minInt = max(1, Int(p.attr("min-integer-digits") ?? "1") ?? 1)
                var n = p.attr("grouping") == "true" ? "#,##" + String(repeating: "0", count: minInt) : String(repeating: "0", count: minInt)
                if p.attr("grouping") == "true", minInt > 1 { n = "#,##0" }
                if decimals > 0 { n += "." + String(repeating: "0", count: decimals) }
                code += n
            case "scientific-number":
                let decimals = Int(p.attr("decimal-places") ?? "2") ?? 2
                code += "0." + String(repeating: "0", count: decimals) + "E+00"
            case "fraction": code += "# ?/?"
            case "text":
                // Whitespace-only text nodes can be dropped by the XML parser: an empty <number:text/> is a space.
                var t = p.stringValue ?? ""
                if t.isEmpty { t = " " }
                code += t == "%" ? "%" : t.isEmpty ? "" : (t.allSatisfy { " ./-:,".contains($0) } ? t : "\"" + t + "\"")
            case "currency-symbol": code += "\"" + (p.stringValue ?? "") + "\""
            case "day": code += p.attr("style") == "long" ? "dd" : "d"
            case "month": code += p.attr("textual") == "true" ? (p.attr("style") == "long" ? "mmmm" : "mmm") : (p.attr("style") == "long" ? "mm" : "m")
            case "year": code += p.attr("style") == "long" ? "yyyy" : "yy"
            case "day-of-week": code += p.attr("style") == "long" ? "dddd" : "ddd"
            case "hours": code += p.attr("style") == "long" ? "hh" : "h"
            case "minutes": code += "mm"
            case "seconds": code += "ss"
            case "am-pm": code += "AM/PM"
            case "text-content": code += "@"
            case "boolean": code += "General"
            default: break
            }
        }
        if kind == "text-style" { return "@" }
        return code.isEmpty ? nil : code
    }

    // MARK: - Writing

    static func write(_ wb: Workbook) -> Data {
        var cellStyles: [CellStyle: String] = [:]
        var dataStyles: [String: String] = [:]   // Excel code → ODS style name
        var columnStyles: [CGFloat: String] = [:]
        var rowStyles: [CGFloat: String] = [:]
        var auto = ""
        func dataStyle(_ code: String) -> String? {
            guard code != "General" else { return nil }
            if let n = dataStyles[code] { return n }
            let name = "N\(dataStyles.count + 100)"
            guard let xml = odfNumberStyle(code, name: name) else { return nil }
            dataStyles[code] = name
            auto += xml
            return name
        }
        func styleName(_ s: CellStyle) -> String? {
            guard s != .default else { return nil }
            if let n = cellStyles[s] { return n }
            let name = "ce\(cellStyles.count + 1)"
            cellStyles[s] = name
            var x = "<style:style style:name=\"\(name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\""
            if let ds = dataStyle(s.numberFormat) { x += " style:data-style-name=\"\(ds)\"" }
            x += "><style:table-cell-properties"
            if let f = s.fill { x += " fo:background-color=\"#\(hex(f))\"" }
            func b(_ side: BorderSide?) -> String { side.map { "\($0.width * 0.75)pt \($0.style == "double" ? "double" : "solid") #\(hex($0.color))" } ?? "none" }
            if s.left != nil || s.right != nil || s.top != nil || s.bottom != nil {
                x += " fo:border-left=\"\(b(s.left))\" fo:border-right=\"\(b(s.right))\" fo:border-top=\"\(b(s.top))\" fo:border-bottom=\"\(b(s.bottom))\""
            }
            if s.wrap { x += " fo:wrap-option=\"wrap\"" }
            if !s.locked { x += " style:cell-protect=\"none\"" }
            x += " style:vertical-align=\"\(s.vAlign == "center" ? "middle" : s.vAlign == "top" ? "top" : "bottom")\"/>"
            if let h = s.hAlign { x += "<style:paragraph-properties fo:text-align=\"\(h == "center" ? "center" : h == "right" ? "end" : h == "justify" ? "justify" : "start")\"/>" }
            x += "<style:text-properties fo:font-size=\"\(Value.formatGeneral(Double(s.fontSize)))pt\""
            if let fn = s.fontName { x += " style:font-name=\"\(xmlEscape(fn))\" fo:font-family=\"\(xmlEscape(fn))\"" }
            if s.bold { x += " fo:font-weight=\"bold\"" }
            if s.italic { x += " fo:font-style=\"italic\"" }
            if s.underline { x += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"" }
            if s.strike { x += " style:text-line-through-style=\"solid\"" }
            if let c = s.textColor { x += " fo:color=\"#\(hex(c))\"" }
            x += "/></style:style>"
            auto += x
            return name
        }
        func colStyle(_ w: CGFloat) -> String {
            if let n = columnStyles[w] { return n }
            let name = "co\(columnStyles.count + 1)"
            columnStyles[w] = name
            auto += "<style:style style:name=\"\(name)\" style:family=\"table-column\"><style:table-column-properties style:column-width=\"\(String(format: "%.3f", w / 28.3465))cm\"/></style:style>"
            return name
        }
        func rowStyle(_ h: CGFloat) -> String {
            if let n = rowStyles[h] { return n }
            let name = "ro\(rowStyles.count + 1)"
            rowStyles[h] = name
            auto += "<style:style style:name=\"\(name)\" style:family=\"table-row\"><style:table-row-properties style:row-height=\"\(String(format: "%.3f", h / 28.3465))cm\" style:use-optimal-row-height=\"false\"/></style:style>"
            return name
        }

        var body = ""
        var validations = ""
        for (si, sheet) in wb.sheets.enumerated() {
            var t = "<table:table table:name=\"\(xmlEscape(sheet.name))\""
            if let area = sheet.printArea { t += " table:print-ranges=\"\(xmlEscape(odfRange(sheet.name, area)))\"" }
            if let p = sheet.protection {
                t += " table:protected=\"true\""
                if let key = p.odsKey {
                    let digests = (p.odsDigest ?? sha1Digest).split(separator: " ")
                    t += " table:protection-key=\"\(key)\" table:protection-key-digest-algorithm=\"\(digests[0])\""
                    if digests.count > 1 { t += " loext:protection-key-digest-algorithm-2=\"\(digests[1])\"" }
                } else if let h = p.passwordHash, let key = legacyProtectionKey(h) {
                    // From .xlsx: LibreOffice's encoding of the Excel hash keeps the password working.
                    t += " table:protection-key=\"\(key)\" table:protection-key-digest-algorithm=\"\(legacyExcelDigest)\" loext:protection-key-digest-algorithm-2=\"\(sha1Digest)\""
                }
            }
            t += ">"
            // Validation rules, clipped to a sane size (whole-column rules would mean a million rows).
            var validationAt: [CellRef: String] = [:]
            for (vi, v) in sheet.validations.enumerated() {
                let name = "val\(si + 1)_\(vi + 1)"
                validations += validationXML(v, name: name, sheet: sheet.name)
                for range in v.ranges {
                    let clipped = CellRange(range.start, CellRef(row: min(range.end.row, range.start.row + 9_999), col: min(range.end.col, range.start.col + 255)))
                    for ref in clipped.cells { validationAt[ref] = name }
                }
            }
            let used = sheet.usedRange
            let lastCol = max(used?.end.col ?? 0, sheet.columnWidths.keys.max() ?? 0, sheet.colLevels.keys.max() ?? 0, validationAt.keys.map(\.col).max() ?? 0)
            var openCols = 0
            for c in 0...lastCol {
                t += groupTags(sheet, c, rows: false, open: &openCols)
                let w = sheet.width(c)
                let style = colStyle(w == 0 ? (sheet.columnWidths[c].flatMap { $0 > 0 ? $0 : nil } ?? sheet.defaultColumnWidth) : w)
                t += "<table:table-column table:style-name=\"\(style)\"\(w == 0 ? " table:visibility=\"collapse\"" : "")/>"
            }
            t += String(repeating: "</table:table-column-group>", count: openCols)
            let merged = Set(sheet.merges.flatMap { m in m.cells.filter { $0 != m.start } })
            let lastRow = max(used?.end.row ?? 0, sheet.rowHeights.keys.max() ?? 0, sheet.rowLevels.keys.max() ?? 0, validationAt.keys.map(\.row).max() ?? 0)
            var openRows = 0
            for r in 0...lastRow {
                t += groupTags(sheet, r, rows: true, open: &openRows)
                let h = sheet.height(r)
                let styleHeight = h == 0 ? (sheet.rowHeights[r].flatMap { $0 > 0 ? $0 : nil } ?? sheet.defaultRowHeight) : h
                t += "<table:table-row table:style-name=\"\(rowStyle(styleHeight))\"\(h == 0 ? " table:visibility=\"collapse\"" : "")>"
                var empty = 0
                func flushEmpty() { if empty > 0 { t += "<table:table-cell\(empty > 1 ? " table:number-columns-repeated=\"\(empty)\"" : "")/>"; empty = 0 } }
                for c in 0...lastCol {
                    let ref = CellRef(row: r, col: c)
                    if merged.contains(ref) { flushEmpty(); t += "<table:covered-table-cell/>"; continue }
                    guard let cell = sheet.cells[ref] else {
                        if let v = validationAt[ref] { flushEmpty(); t += "<table:table-cell table:content-validation-name=\"\(v)\"/>" } else { empty += 1 }
                        continue
                    }
                    flushEmpty()
                    t += cellXML(cell, ref: ref, sheet: sheet, style: styleName(cell.style), validation: validationAt[ref])
                }
                t += "</table:table-row>"
            }
            t += String(repeating: "</table:table-row-group>", count: openRows)
            t += "</table:table>"
            body += t
        }
        if !validations.isEmpty { body = "<table:content-validations>\(validations)</table:content-validations>" + body }
        if !wb.names.isEmpty {
            body += "<table:named-expressions>"
            for (name, def) in wb.names.sorted(by: { $0.key < $1.key }) {
                if let e = try? Formula.parse("=" + def), case .range(let s, let a, let b) = e {
                    body += "<table:named-range table:name=\"\(xmlEscape(name))\" table:cell-range-address=\"\(xmlEscape(odfRef(s, a, b, absoluteSheet: true)))\"/>"
                } else if let e = try? Formula.parse("=" + def), case .ref(let s, let a) = e {
                    body += "<table:named-range table:name=\"\(xmlEscape(name))\" table:cell-range-address=\"\(xmlEscape(odfRef(s, a, nil, absoluteSheet: true)))\"/>"
                }
            }
            body += "</table:named-expressions>"
        }
        body += PivotFiles.odsXML(wb)

        let ns = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" \
        xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0" \
        xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" office:version="1.3"
        """
        let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content \(ns)><office:automatic-styles>\(auto)</office:automatic-styles><office:body><office:spreadsheet><table:calculation-settings table:case-sensitive=\"false\" table:use-regular-expressions=\"false\" table:use-wildcards=\"true\"/>\(body)</office:spreadsheet></office:body></office:document-content>"
        let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles \(ns)><office:styles><style:default-style style:family=\"table-cell\"><style:text-properties fo:font-size=\"11pt\" style:font-name=\"Calibri\" fo:font-family=\"Calibri\"/></style:default-style><style:style style:name=\"Default\" style:family=\"table-cell\"/></office:styles></office:document-styles>"
        var tables = ""
        for s in wb.sheets {
            tables += "<config:config-item-map-entry config:name=\"\(xmlEscape(s.name))\">"
            if s.frozenCols > 0 { tables += "<config:config-item config:name=\"HorizontalSplitMode\" config:type=\"short\">2</config:config-item><config:config-item config:name=\"HorizontalSplitPosition\" config:type=\"int\">\(s.frozenCols)</config:config-item><config:config-item config:name=\"PositionRight\" config:type=\"int\">\(s.frozenCols)</config:config-item>" }
            if s.frozenRows > 0 { tables += "<config:config-item config:name=\"VerticalSplitMode\" config:type=\"short\">2</config:config-item><config:config-item config:name=\"VerticalSplitPosition\" config:type=\"int\">\(s.frozenRows)</config:config-item><config:config-item config:name=\"PositionBottom\" config:type=\"int\">\(s.frozenRows)</config:config-item>" }
            tables += "<config:config-item config:name=\"ShowGrid\" config:type=\"boolean\">\(s.showGridlines)</config:config-item></config:config-item-map-entry>"
        }
        let settings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-settings \(ns)><office:settings><config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\"><config:config-item-map-entry><config:config-item-map-named config:name=\"Tables\">\(tables)</config:config-item-map-named></config:config-item-map-entry></config:config-item-map-indexed></config:config-item-set></office:settings></office:document-settings>"
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
        <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
        <manifest:file-entry manifest:full-path="settings.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """
        var zip = ZipArchive()
        zip.storedUncompressed.insert("mimetype")
        zip["mimetype"] = Data("application/vnd.oasis.opendocument.spreadsheet".utf8)
        zip["content.xml"] = Data(content.utf8)
        zip["styles.xml"] = Data(styles.utf8)
        zip["settings.xml"] = Data(settings.utf8)
        zip["META-INF/manifest.xml"] = Data(manifest.utf8)
        return zip.data()
    }

    private static func cellXML(_ cell: Cell, ref: CellRef, sheet: Sheet, style: String?, validation: String? = nil) -> String {
        var x = "<table:table-cell"
        if let style { x += " table:style-name=\"\(style)\"" }
        if let validation { x += " table:content-validation-name=\"\(validation)\"" }
        if let m = sheet.merges.first(where: { $0.start == ref }) {
            x += " table:number-columns-spanned=\"\(m.cols.count)\" table:number-rows-spanned=\"\(m.rows.count)\""
        }
        if cell.isFormula, let e = Calculator.expression(cell.input) {
            x += " table:formula=\"\(xmlEscape("of:=" + odfFormula(e)))\""
            if let spill = sheet.spills[ref] {
                x += " table:number-matrix-columns-spanned=\"\(spill.cols.count)\" table:number-matrix-rows-spanned=\"\(spill.rows.count)\""
            } else if cell.array {
                x += " table:number-matrix-columns-spanned=\"1\" table:number-matrix-rows-spanned=\"1\""
            }
        }
        var text = NumberFormat.format(cell.value, cell.style.numberFormat).text
        switch cell.value {
        case .number(let d):
            if NumberFormat.isDateFormat(cell.style.numberFormat) {
                let date = DateMath.date(d)
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = d == floor(d) ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ss"
                x += " office:value-type=\"date\" office:date-value=\"\(f.string(from: date))\""
            } else if cell.style.numberFormat.contains("%") {
                x += " office:value-type=\"percentage\" office:value=\"\(String(format: "%.15g", d))\""
            } else {
                x += " office:value-type=\"float\" office:value=\"\(String(format: "%.15g", d))\""
            }
        case .bool(let b): x += " office:value-type=\"boolean\" office:boolean-value=\"\(b)\""; text = b ? "TRUE" : "FALSE"
        case .string: x += " office:value-type=\"string\""
        case .error: x += " office:value-type=\"string\""
        case .empty: break
        }
        x += ">"
        if let comment = sheet.comments[ref] {
            x += "<office:annotation>" + comment.split(separator: "\n", omittingEmptySubsequences: false).map { "<text:p>\(xmlEscape(String($0)))</text:p>" }.joined() + "</office:annotation>"
        }
        if !text.isEmpty { x += text.split(separator: "\n", omittingEmptySubsequences: false).map { "<text:p>\(xmlEscape(String($0)))</text:p>" }.joined() }
        return x + "</table:table-cell>"
    }

    private static func hex(_ c: NSColor) -> String { String(XLSX.argb(c).dropFirst(2)) }

    private static func odfSheet(_ name: String, absolute: Bool) -> String {
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return (absolute ? "$" : "") + (plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'")
    }

    static func odfRef(_ sheet: String?, _ a: RefPart, _ b: RefPart?, absoluteSheet: Bool = false) -> String {
        let prefix = sheet.map { odfSheet($0, absolute: absoluteSheet) } ?? ""
        var s = prefix + "." + a.text
        if let b { s += ":" + (sheet.map { _ in prefix } ?? "") + "." + b.text }
        return s
    }

    static func odfRange(_ sheet: String, _ r: CellRange) -> String {
        "\(odfSheet(sheet, absolute: true)).$\(CellRef.columnName(r.start.col))$\(r.start.row + 1):\(odfSheet(sheet, absolute: true)).$\(CellRef.columnName(r.end.col))$\(r.end.row + 1)"
    }

    /// OpenFormula names LibreOffice uses for Excel functions (COM.MICROSOFT.…, LEGACY.…, native equivalents).
    static func odfName(_ n: String) -> String {
        switch n {
        case "F.DIST": return "FDIST"
        case "F.INV": return "FINV"
        case "SKEW.P": return "SKEWP"
        case "FDIST", "FINV", "NORMSDIST", "NORMSINV", "TDIST", "CHIDIST", "CHIINV": return "LEGACY." + n
        case "REGEX": return "ORG.LIBREOFFICE.REGEX"
        case "ERROR.TYPE": return n
        default:
            return n.contains(".") || microsoftNames.contains(n) ? "COM.MICROSOFT." + n : n
        }
    }

    static let microsoftNames: Set<String> = [
        "MAXIFS", "MINIFS", "IFS", "SWITCH", "XLOOKUP", "XMATCH", "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY",
        "LET", "CONCAT", "TEXTJOIN", "CEILING", "FLOOR", "AGGREGATE", "VSTACK", "HSTACK", "TOCOL", "TOROW", "CHOOSECOLS",
        "CHOOSEROWS", "TAKE", "DROP", "EXPAND", "WRAPROWS", "WRAPCOLS", "TEXTBEFORE", "TEXTAFTER", "TEXTSPLIT", "REGEXTEST",
        "REGEXEXTRACT", "REGEXREPLACE", "LAMBDA",
    ]

    /// Expression → OpenFormula text (references in brackets, ";" between arguments).
    static func odfFormula(_ e: Expr) -> String {
        func s(_ e: Expr, _ parent: Int) -> String {
            switch e {
            case .ref(let sh, let p): return "[" + odfRef(sh, p, nil) + "]"
            case .range(let sh, let a, let b): return "[" + odfRef(sh, a, b) + "]"
            case .call(let n, let args): return odfName(n) + "(" + args.map { s($0, 0) }.joined(separator: ";") + ")"
            case .binary(let o, let l, let r):
                let prec = Formula.precedence(o)
                let text = s(l, prec) + o + s(r, prec + 1)
                return prec < parent ? "(" + text + ")" : text
            case .unary(let o, let x): return o + s(x, 6)
            case .percent(let x): return s(x, 7) + "%"
            case .array(let m): return Formula.arrayText(m, col: ";", row: "|")
            default: return Formula.serialize(e)
            }
        }
        return s(e, 0)
    }

    /// Excel format code → <number:…-style>, for the common formats.
    static func odfNumberStyle(_ code: String, name: String) -> String? {
        let ns = "number:"
        if code == "@" { return "<\(ns)text-style style:name=\"\(name)\"><\(ns)text-content/></\(ns)text-style>" }
        if NumberFormat.isDateFormat(code) {
            var parts = ""
            var afterHours = false   // "m" right after hours (h:mm) means minutes
            var i = code.startIndex
            let lower = code.lowercased()
            while i < lower.endIndex {
                let rest = lower[i...]
                let tokens: [(String, String, Bool)] = [
                    ("yyyy", "<\(ns)year \(ns)style=\"long\"/>", false), ("yy", "<\(ns)year/>", false),
                    ("mmmm", "<\(ns)month \(ns)style=\"long\" \(ns)textual=\"true\"/>", false), ("mmm", "<\(ns)month \(ns)textual=\"true\"/>", false),
                    ("dd", "<\(ns)day \(ns)style=\"long\"/>", false), ("d", "<\(ns)day/>", false),
                    ("hh", "<\(ns)hours \(ns)style=\"long\"/>", true), ("h", "<\(ns)hours/>", true),
                    ("ss", "<\(ns)seconds \(ns)style=\"long\"/>", false), ("s", "<\(ns)seconds/>", false),
                ]
                if let t = tokens.first(where: { rest.hasPrefix($0.0) }) {
                    parts += t.1
                    afterHours = t.2
                    i = lower.index(i, offsetBy: t.0.count)
                    continue
                }
                if rest.hasPrefix("m") {
                    let n = rest.hasPrefix("mm") ? 2 : 1
                    let nextIsSeconds = lower[lower.index(i, offsetBy: n)...].drop { !$0.isLetter }.first == "s"
                    if afterHours || nextIsSeconds { parts += "<\(ns)minutes \(ns)style=\"long\"/>" }
                    else { parts += n == 2 ? "<\(ns)month \(ns)style=\"long\"/>" : "<\(ns)month/>" }
                    afterHours = false
                    i = lower.index(i, offsetBy: n)
                    continue
                }
                parts += "<\(ns)text>\(xmlEscape(String(code[i])))</\(ns)text>"
                if code[i] != ":" { afterHours = false }
                i = lower.index(after: i)
            }
            return "<\(ns)date-style style:name=\"\(name)\">\(parts)</\(ns)date-style>"
        }
        let section = String(NumberFormat.splitSections(code).first ?? "")
        let stripped = NumberFormat.strip(section)
        let percent = stripped.contains("%")
        let decimals = stripped.split(separator: ".").dropFirst().first.map { $0.filter { $0 == "0" || $0 == "#" }.count } ?? 0
        let grouping = stripped.contains(",")
        var literal = ""
        if let q1 = section.firstIndex(of: "\""), let q2 = section[section.index(after: q1)...].firstIndex(of: "\"") {
            literal = String(section[section.index(after: q1)..<q2])
        }
        let number = "<\(ns)number \(ns)decimal-places=\"\(decimals)\" \(ns)min-decimal-places=\"\(decimals)\" \(ns)min-integer-digits=\"1\"\(grouping ? " \(ns)grouping=\"true\"" : "")/>"
        if percent { return "<\(ns)percentage-style style:name=\"\(name)\">\(number)<\(ns)text>%</\(ns)text></\(ns)percentage-style>" }
        if !literal.isEmpty {
            let before = section.hasPrefix("\"")
            let sym = "<\(ns)currency-symbol>\(xmlEscape(literal.trimmingCharacters(in: .whitespaces)))</\(ns)currency-symbol>"
            return "<\(ns)currency-style style:name=\"\(name)\">" + (before ? sym + number : number + "<\(ns)text> </\(ns)text>" + sym) + "</\(ns)currency-style>"
        }
        return "<\(ns)number-style style:name=\"\(name)\">\(number)</\(ns)number-style>"
    }
}

extension XMLElement {
    /// Text of an ODF paragraph: spans, <text:s/> spaces, tabs and line breaks.
    var allTextODF: String {
        var out = ""
        for node in children ?? [] {
            if node.kind == .text { out += node.stringValue ?? ""; continue }
            guard let e = node as? XMLElement else { continue }
            switch e.localName {
            case "s": out += String(repeating: " ", count: Int(e.attr("c") ?? "1") ?? 1)
            case "tab": out += "\t"
            case "line-break": out += "\n"
            case "annotation": break
            default: out += e.allTextODF
            }
        }
        return out
    }
}
