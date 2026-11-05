import AppKit
import Kit42

/// Reads and writes .xlsx (Office Open XML SpreadsheetML).
enum XLSX {
    /// XML normalizes literal CR in text and all whitespace in attributes.
    /// Character references preserve the exact cell text and formula literals.
    static func xmlEscape(_ text: String) -> String {
        Kit42.xmlEscape(text).replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\t", with: "&#9;")
    }

    // MARK: - Reading

    static func read(_ data: Data) throws -> Workbook {
        let zip = try ZipArchive(data: data)
        func xml(_ path: String) -> XMLElement? {
            guard let d = zip[path] else { return nil }
            return (try? XMLDocument(data: d, options: [.nodePreserveWhitespace]))?.rootElement()
        }
        guard let workbookXML = xml("xl/workbook.xml"), workbookXML.localName == "workbook",
              workbookXML.child("sheets") != nil else { throw ZipError.corrupt }
        var wb = Workbook()
        wb.sheets = []
        wb.date1904 = workbookXML.child("workbookPr")?.attr("date1904").map { $0 == "1" || $0 == "true" } ?? false
        wb.structureProtected = workbookXML.child("workbookProtection")?.attr("lockStructure").map { $0 == "1" || $0 == "true" } ?? false

        // Relationships: rId → target path
        var rels: [String: String] = [:]
        for r in xml("xl/_rels/workbook.xml.rels")?.children("Relationship") ?? [] {
            if let id = r.attr("Id"), var target = r.attr("Target") {
                if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
                rels[id] = target
            }
        }

        let theme = themeColors(xml("xl/theme/theme1.xml"))
        let (styles, namedStyles) = readStyles(xml("xl/styles.xml"), theme: theme)
        wb.cellStyles = namedStyles
        let dxfs = readDxfs(xml("xl/styles.xml"), theme: theme)
        let shared = (xml("xl/sharedStrings.xml")?.children("si") ?? []).map(\.allText)

        var sheetPaths: [String] = []
        for s in workbookXML.child("sheets")?.children("sheet") ?? [] {
            let name = s.attr("name") ?? "Sheet\(wb.sheets.count + 1)"
            guard let rid = s.attr("id"), let path = rels[rid], let root = xml(path) else { continue }
            var sheet = readSheet(root, name: name, styles: styles, shared: shared, date1904: wb.date1904)
            sheet.hidden = s.attr("state") == "hidden" || s.attr("state") == "veryHidden"
            if let tab = root.child("sheetPr")?.child("tabColor") { sheet.tabColor = color(tab, theme: theme) }
            readExtras(&sheet, root: root, path: path, zip: zip, dxfs: dxfs, theme: theme)
            wb.sheets.append(sheet)
            sheetPaths.append(path)
        }
        guard !wb.sheets.isEmpty else { throw ZipError.corrupt }
        var solverNames: [Int: [String: String]] = [:]
        for d in workbookXML.child("definedNames")?.children("definedName") ?? [] {
            guard let name = d.attr("name"), let text = d.stringValue, !text.isEmpty else { continue }
            if SolverFiles.isSolverName(name) {
                // Sheet-scoped (Excel, LibreOffice); a workbook-level model belongs to the sheet of its objective.
                solverNames[d.attr("localSheetId").flatMap(Int.init) ?? -1, default: [:]][name] = text
                continue
            }
            if name == "_xlnm.Print_Area", let i = d.attr("localSheetId").flatMap(Int.init), i >= 0, i < wb.sheets.count {
                // Commas inside a quoted sheet name are not area separators.
                var quoted = false
                let first = String(text.prefix { character in
                    if character == "'" { quoted.toggle() }
                    return character != "," || quoted
                })
                let refPart = first.split(separator: "!").last.map(String.init) ?? first
                wb.sheets[i].printArea = CellRange(refPart.replacingOccurrences(of: "$", with: ""))
            } else if !name.hasPrefix("_xlnm.") {
                wb.names[name] = text
            }
        }
        for (i, names) in solverNames.sorted(by: { $0.key < $1.key }) {
            var si = i
            if si < 0, let opt = names.first(where: { $0.key.lowercased() == "solver_opt" })?.value, let bang = opt.lastIndex(of: "!") {
                var sheet = String(opt[..<bang])
                if sheet.hasPrefix("=") { sheet.removeFirst() }
                if sheet.hasPrefix("'") { sheet = String(sheet.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
                si = wb.sheetIndex(named: sheet) ?? -1
            }
            guard si >= 0, si < wb.sheets.count, wb.sheets[si].solver == nil else { continue }
            wb.sheets[si].solver = SolverFiles.model(names, sheet: wb.sheets[si].name)
        }
        PivotFiles.readXLSX(&wb, zip: zip, workbookXML: workbookXML, workbookRels: rels, sheetPaths: sheetPaths)
        return wb
    }

    private static func readSheet(_ root: XMLElement, name: String, styles: [CellStyle], shared: [String], date1904: Bool) -> Sheet {
        var sheet = Sheet(name: name)
        if let fmt = root.child("sheetFormatPr") {
            if let h = fmt.attr("defaultRowHeight").flatMap(Double.init) { sheet.defaultRowHeight = CGFloat(h) }
            if let w = fmt.attr("defaultColWidth").flatMap(Double.init) { sheet.defaultColumnWidth = columnPoints(w) }
            else if let b = fmt.attr("baseColWidth").flatMap(Double.init) { sheet.defaultColumnWidth = columnPoints(b + 0.71) }
        }
        if let view = root.child("sheetViews")?.child("sheetView") {
            sheet.showGridlines = view.attr("showGridLines") != "0"
            if let pane = view.child("pane"), pane.attr("state") == "frozen" || pane.attr("state") == "frozenSplit" {
                sheet.frozenCols = boundedCount(pane.attr("xSplit"), maximum: 16_384)
                sheet.frozenRows = boundedCount(pane.attr("ySplit"), maximum: 1_048_576)
            } else if let pane = view.child("pane") {
                // Split window (state="split", the default): positions in twips, measured with the headers.
                sheet.split = SheetSplit.fromTwips(x: pane.attr("xSplit").flatMap(Double.init) ?? 0, y: pane.attr("ySplit").flatMap(Double.init) ?? 0,
                                                   topLeft: view.attr("topLeftCell").flatMap(CellRef.init), paneTopLeft: pane.attr("topLeftCell").flatMap(CellRef.init),
                                                   activePane: pane.attr("activePane"))
            }
        }
        for col in root.child("cols")?.children("col") ?? [] {
            guard let min = col.attr("min").flatMap(Int.init), let max = col.attr("max").flatMap(Int.init),
                  min >= 1, min <= max, max <= 16_384 else { continue }
            let hidden = col.attr("hidden") == "1" || col.attr("hidden") == "true"
            let level = col.attr("outlineLevel").flatMap(Int.init) ?? 0
            // Columns hidden by a collapsed group keep their width.
            let w = hidden && level == 0 ? 0 : columnPoints(col.attr("width").flatMap(Double.init) ?? 8.43)
            for c in min...max {
                if col.attr("width") != nil || hidden { sheet.columnWidths[c - 1] = w }
                if level > 0 { sheet.colLevels[c - 1] = Swift.min(level, Sheet.maxOutlineLevel) }
                if level > 0 && hidden { sheet.outlineHiddenCols.insert(c - 1) }
            }
        }

        var sharedFormulas: [String: (String, CellRef)] = [:]
        var arrayRanges: [CellRange] = []
        for row in root.child("sheetData")?.children("row") ?? [] {
            let rowNumber = row.attr("r").flatMap(Int.init) ?? 1
            guard (1...1_048_576).contains(rowNumber) else { continue }
            let r = rowNumber - 1
            let level = row.attr("outlineLevel").flatMap(Int.init) ?? 0
            if level > 0 { sheet.rowLevels[r] = min(level, Sheet.maxOutlineLevel) }
            if row.attr("hidden") == "1" || row.attr("hidden") == "true" {
                if level > 0 {
                    sheet.outlineHiddenRows.insert(r)
                    if row.attr("customHeight") == "1", let ht = row.attr("ht").flatMap(Double.init), ht > 0 { sheet.rowHeights[r] = CGFloat(ht) }
                } else { sheet.rowHeights[r] = 0 }
            }
            else if row.attr("customHeight") == "1" || row.attr("ht") != nil, let ht = row.attr("ht").flatMap(Double.init) {
                sheet.rowHeights[r] = CGFloat(ht)
            }
            var nextCol = 0
            for c in row.children("c") {
                let ref = c.attr("r").flatMap(CellRef.init) ?? CellRef(row: r, col: nextCol)
                nextCol = ref.col + 1
                var cell = Cell()
                if let s = c.attr("s").flatMap(Int.init), s >= 0, s < styles.count { cell.style = styles[s] }
                let t = c.attr("t") ?? "n"
                let v = c.child("v")?.stringValue
                switch t {
                case "s": cell.value = .string(v.flatMap(Int.init).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil } ?? "")
                case "inlineStr": cell.value = .string(c.child("is")?.allText ?? "")
                case "str": cell.value = .string(v ?? "")
                case "b": cell.value = .bool(v == "1")
                case "e": cell.value = .error(v ?? "#VALUE!")
                default: cell.value = v.flatMap(Double.init).map(Value.number) ?? .empty
                }
                if let f = c.child("f") {
                    let text = f.stringValue ?? ""
                    if f.attr("t") == "shared", let si = f.attr("si") {
                        if !text.isEmpty { sharedFormulas[si] = (text, ref) }
                        if let (master, origin) = sharedFormulas[si] {
                            cell.input = text.isEmpty
                                ? Formula.shifted("=" + master, rows: ref.row - origin.row, cols: ref.col - origin.col)
                                : "=" + text
                        }
                    } else if !text.isEmpty {
                        cell.input = "=" + text
                        // Array formula (CSE or dynamic array): the other cells of its range hold the results.
                        if f.attr("t") == "array" {
                            cell.array = true
                            if let r = f.attr("ref").flatMap(CellRange.init) {
                                if r.count > 1 { arrayRanges.append(r) }
                                // Without Excel 365's dynamic-array mark (cm) it's a Ctrl+Shift+Enter formula over a fixed range.
                                if c.attr("cm") == nil { sheet.arrays[ref] = CellRange(ref, r.end) }
                            }
                        }
                    }
                }
                if cell.input.isEmpty {
                    cell.input = inputText(for: cell.value, style: cell.style, date1904: date1904)
                    // String constants must not become formulas or change type when edited.
                    if case .string(let text) = cell.value, constant(text) != .string(text) || text.hasPrefix("=") {
                        cell.input = "'" + text
                    }
                }
                sheet[ref] = cell
            }
        }
        for r in arrayRanges {
            for ref in sheet.cells.keys.filter({ $0 != r.start && r.contains($0) }) {
                if var c = sheet.cells[ref], !c.isFormula { c.input = ""; sheet.cells[ref] = c }
            }
        }
        for m in root.child("mergeCells")?.children("mergeCell") ?? [] {
            if let range = m.attr("ref").flatMap(CellRange.init) { sheet.merges.append(range) }
        }
        // Rows without an explicit height grow with their largest font, as in Excel.
        var tallest: [Int: CGFloat] = [:]
        for (ref, cell) in sheet.cells where sheet.rowHeights[ref.row] == nil && cell.style.fontSize > 11 && !cell.value.isEmpty {
            tallest[ref.row] = max(tallest[ref.row] ?? 0, cell.style.fontSize)
        }
        for (row, size) in tallest { sheet.rowHeights[row] = max(sheet.defaultRowHeight, ceil(size * 1.32)) }
        return sheet
    }

    /// Edit text of a constant (dates shown as dates, not serials).
    static func inputText(for value: Value, style: CellStyle, date1904: Bool = false) -> String {
        if case .number(let d) = value, NumberFormat.isDateFormat(style.numberFormat) {
            let hasTime = d != floor(d)
            return NumberFormat.format(value, hasTime ? "dd.mm.yyyy hh:mm" : "dd.mm.yyyy", date1904: date1904).text
        }
        if case .number(let d) = value { return Value.numberLiteral(d) }
        if case .bool(let b) = value { return b ? "TRUE" : "FALSE" }
        if case .string(let text) = value, constant(text) != .string(text) || text.hasPrefix("=") { return "'" + text }
        return value.plain
    }

    private static func boundedCount(_ text: String?, maximum: Int) -> Int {
        guard let value = text.flatMap(Double.init), value.isFinite, value > 0 else { return 0 }
        return Int(min(value, Double(maximum)))
    }

    /// Excel column width (characters) → points at 100 %.
    static func columnPoints(_ chars: Double) -> CGFloat {
        let px = (chars * 7 + 5).rounded(.down)
        return CGFloat(max(0, px) * 0.75)
    }

    static func columnChars(_ points: CGFloat) -> Double {
        let px = Double(points) / 0.75
        return max(0, ((px - 5) / 7 * 100).rounded() / 100)
    }

    // MARK: Styles

    /// Cell formats (cellXfs) and the named cell styles (cellStyles over cellStyleXfs, Normal left out).
    private static func readStyles(_ root: XMLElement?, theme: [NSColor]) -> ([CellStyle], [String: CellStyle]) {
        guard let root else { return ([], [:]) }
        var formats = NumberFormat.builtin
        for f in root.child("numFmts")?.children("numFmt") ?? [] {
            if let id = f.attr("numFmtId").flatMap(Int.init), let code = f.attr("formatCode") { formats[id] = code }
        }
        let fonts: [CellStyle] = (root.child("fonts")?.children("font") ?? []).map { f in
            var s = CellStyle()
            s.bold = f.child("b").map { $0.attr("val") != "0" } ?? false
            s.italic = f.child("i").map { $0.attr("val") != "0" } ?? false
            s.underline = f.child("u").map { $0.attr("val") != "none" } ?? false
            s.doubleUnderline = f.child("u").map { $0.attr("val") == "double" || $0.attr("val") == "doubleAccounting" } ?? false
            s.strike = f.child("strike").map { $0.attr("val") != "0" } ?? false
            if let sz = f.child("sz")?.attr("val").flatMap(Double.init) { s.fontSize = CGFloat(sz) }
            s.fontName = f.child("name")?.attr("val")
            s.textColor = f.child("color").flatMap { color($0, theme: theme) }
            return s
        }
        let fills: [NSColor?] = (root.child("fills")?.children("fill") ?? []).map { f in
            guard let p = f.child("patternFill"), let type = p.attr("patternType"), type != "none" else { return nil }
            if type == "solid" { return p.child("fgColor").flatMap { color($0, theme: theme) } ?? p.child("bgColor").flatMap { color($0, theme: theme) } }
            return p.child("fgColor").flatMap { color($0, theme: theme) }?.withAlphaComponent(0.5)
        }
        let borders: [[BorderSide?]] = (root.child("borders")?.children("border") ?? []).map { b in
            ["left", "right", "top", "bottom"].map { side in
                guard let e = b.child(side), let style = e.attr("style"), style != "none" else { return nil }
                return BorderSide(style: style, color: e.child("color").flatMap { color($0, theme: theme) } ?? .black)
            }
        }
        // Named cell styles: cellStyleXfs index → name.
        var styleNames: [Int: String] = [:]
        for cs in root.child("cellStyles")?.children("cellStyle") ?? [] {
            if let id = cs.attr("xfId").flatMap(Int.init), let name = cs.attr("name"), id > 0, cs.attr("builtinId") != "0", name != "Normal" {
                styleNames[id] = CellStyles.internalName(name)
            }
        }
        let cellXfs = (root.child("cellXfs")?.children("xf") ?? []).map { xf -> CellStyle in
            var s = format(xf)
            s.styleName = xf.attr("xfId").flatMap(Int.init).flatMap { styleNames[$0] }
            return s
        }
        var named: [String: CellStyle] = [:]
        let styleXfs = root.child("cellStyleXfs")?.children("xf") ?? []
        for (id, name) in styleNames where id < styleXfs.count && named[name] == nil {
            var s = format(styleXfs[id])
            s.styleName = name
            named[name] = s
        }
        return (cellXfs, named)

        func format(_ xf: XMLElement) -> CellStyle {
            var s = xf.attr("fontId").flatMap(Int.init).flatMap { $0 >= 0 && $0 < fonts.count ? fonts[$0] : nil } ?? CellStyle()
            if let id = xf.attr("fillId").flatMap(Int.init), id >= 0, id < fills.count { s.fill = fills[id] }
            if let id = xf.attr("borderId").flatMap(Int.init), id >= 0, id < borders.count {
                (s.left, s.right, s.top, s.bottom) = (borders[id][0], borders[id][1], borders[id][2], borders[id][3])
            }
            if let id = xf.attr("numFmtId").flatMap(Int.init) { s.numberFormat = formats[id] ?? "General" }
            if let p = xf.child("protection"), p.attr("locked") == "0" || p.attr("locked") == "false" { s.locked = false }
            if let p = xf.child("protection"), p.attr("hidden") == "1" || p.attr("hidden") == "true" { s.hiddenFormula = true }
            if let a = xf.child("alignment") {
                s.hAlign = a.attr("horizontal")
                if let v = a.attr("vertical") { s.vAlign = v }
                s.wrap = a.attr("wrapText") == "1" || a.attr("wrapText") == "true"
                s.indent = a.attr("indent").flatMap(Int.init) ?? 0
                if let r = a.attr("textRotation").flatMap(Int.init) { s.rotation = r > 90 && r <= 180 ? 90 - r : r }
                s.shrink = a.attr("shrinkToFit") == "1" || a.attr("shrinkToFit") == "true"
            }
            return s
        }
    }

    private static func themeColors(_ root: XMLElement?) -> [NSColor] {
        guard let scheme = root?.child("themeElements")?.child("clrScheme") else { return [] }
        let order = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"]
        return order.map { key in
            guard let e = scheme.child(key) else { return .black }
            if let hex = e.child("srgbClr")?.attr("val") { return hexColor(hex) ?? .black }
            if let hex = e.child("sysClr")?.attr("lastClr") { return hexColor(hex) ?? .black }
            return .black
        }
    }

    static func color(_ e: XMLElement, theme: [NSColor]) -> NSColor? {
        var c: NSColor?
        if let rgb = e.attr("rgb") { c = hexColor(rgb) }
        else if let t = e.attr("theme").flatMap(Int.init), t >= 0, t < theme.count { c = theme[t] }
        else if let i = e.attr("indexed").flatMap(Int.init) {
            if i == 64 || i == 65 { return nil }   // system foreground/background
            c = i >= 0 && i < indexedColors.count ? hexColor(indexedColors[i]) : nil
        }
        guard let base = c else { return nil }
        if let tint = e.attr("tint").flatMap(Double.init), tint != 0 { return tinted(base, tint) }
        return base
    }

    static func hexColor(_ s: String) -> NSColor? {
        let hex = s.count == 8 ? String(s.suffix(6)) : s
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func tinted(_ c: NSColor, _ tint: Double) -> NSColor {
        guard let rgb = c.usingColorSpace(.sRGB) else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Convert HSB → HSL, apply Excel tint to luminance, back.
        var l = b * (1 - s / 2)
        var sl = (l == 0 || l == 1) ? 0 : (b - l) / min(l, 1 - l)
        l = tint < 0 ? l * (1 + CGFloat(tint)) : l * (1 - CGFloat(tint)) + CGFloat(tint)
        let nb = l + sl * min(l, 1 - l)
        sl = nb == 0 ? 0 : 2 * (1 - l / nb)
        return NSColor(hue: h, saturation: sl, brightness: nb, alpha: a)
    }

    static let indexedColors = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
    ]

    // MARK: - Writing

    static func write(_ wb: Workbook) -> Data {
        var zip = ZipArchive()
        let sheetCount = wb.sheets.count

        // Styles: dedupe cell styles into xfs
        var styleIndex: [CellStyle: Int] = [CellStyle.default: 0]
        var styleList: [CellStyle] = [CellStyle.default]
        for sheet in wb.sheets {
            for cell in sheet.cells.values where styleIndex[cell.style] == nil {
                styleIndex[cell.style] = styleList.count
                styleList.append(cell.style)
            }
        }

        var ct = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        """
        ct += "<Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"vml\" ContentType=\"application/vnd.openxmlformats-officedocument.vmlDrawing\"/>"
        for i in 1...sheetCount {
            ct += "<Override PartName=\"/xl/worksheets/sheet\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }

        zip["_rels/.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """.utf8)
        zip["docProps/app.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>XLS42</Application></Properties>
        """.utf8)

        var counters = Counters()
        var dxfs: [Dxf] = []
        var workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <workbookPr\(wb.date1904 ? " date1904=\"1\"" : "")/>\(wb.structureProtected ? "<workbookProtection lockStructure=\"1\"/>" : "")<bookViews><workbookView/></bookViews><sheets>
        """
        var wbRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        var pivotCaches: [String] = [], pivotRels = ""
        let firstVisible = wb.sheets.firstIndex { !$0.hidden } ?? 0
        for (i, sheet) in wb.sheets.enumerated() {
            workbook += "<sheet name=\"\(xmlEscape(sheet.name))\" sheetId=\"\(i + 1)\"\(sheet.hidden ? " state=\"hidden\"" : "") r:id=\"rId\(i + 1)\"/>"
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
            let extras = writeExtras(sheet, sheetNumber: i + 1, zip: &zip, counters: &counters, dxfs: &dxfs)
            ct += extras.types
            zip["xl/worksheets/sheet\(i + 1).xml"] = Data(sheetXML(sheet, styleIndex: styleIndex, selected: i == firstVisible, extras: extras).utf8)
            if let spec = sheet.pivot,
               let part = PivotFiles.writeXLSX(spec, workbook: wb, sheetNumber: i + 1, n: pivotCaches.count + 1, zip: &zip) {
                ct += part.types
                pivotCaches.append(part.cacheEntry)
                pivotRels += part.workbookRel
            }
        }
        let dynamicArrays = wb.sheets.contains { s in s.spills.keys.contains { s.cells[$0].map { !$0.array } ?? false } }
        if dynamicArrays {
            ct += "<Override PartName=\"/xl/metadata.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheetMetadata+xml\"/>"
            zip["xl/metadata.xml"] = Data(dynamicArrayMetadata.utf8)
            pivotRels += "<Relationship Id=\"rIdMeta1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sheetMetadata\" Target=\"metadata.xml\"/>"
        }
        ct += "</Types>"
        zip["[Content_Types].xml"] = Data(ct.utf8)
        workbook += "</sheets>"
        if firstVisible > 0 { workbook = workbook.replacingOccurrences(of: "<bookViews><workbookView/>", with: "<bookViews><workbookView activeTab=\"\(firstVisible)\" firstSheet=\"\(firstVisible)\"/>") }
        var defined: [String] = wb.names.sorted { $0.key < $1.key }.map { "<definedName name=\"\(xmlEscape($0.key))\">\(xmlEscape($0.value))</definedName>" }
        for (i, sheet) in wb.sheets.enumerated() {
            func absolute(_ r: CellRange) -> String {
                "\(Formula.sheetPrefix(sheet.name))$\(CellRef.columnName(r.start.col))$\(r.start.row + 1):$\(CellRef.columnName(r.end.col))$\(r.end.row + 1)"
            }
            if let area = sheet.printArea {
                defined.append("<definedName name=\"_xlnm.Print_Area\" localSheetId=\"\(i)\">\(xmlEscape(absolute(area)))</definedName>")
            }
            if let f = sheet.autoFilter {
                defined.append("<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">\(xmlEscape(absolute(f)))</definedName>")
            }
            if let m = sheet.solver { defined += SolverFiles.xlsxNames(m, sheet: sheet.name, index: i) }
        }
        if !defined.isEmpty { workbook += "<definedNames>" + defined.joined() + "</definedNames>" }
        workbook += "<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/>"
        if !pivotCaches.isEmpty { workbook += "<pivotCaches>" + pivotCaches.joined() + "</pivotCaches>" }
        workbook += "</workbook>"
        wbRels += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" + pivotRels + "</Relationships>"
        zip["xl/workbook.xml"] = Data(workbook.utf8)
        zip["xl/_rels/workbook.xml.rels"] = Data(wbRels.utf8)
        zip["xl/styles.xml"] = Data(stylesXML(styleList, dxfs: dxfs, named: CellStyles.definitions(wb)).utf8)
        return zip.data()
    }

    /// Cell metadata Excel 365 uses to mark dynamic-array formulas (cm="1").
    static let dynamicArrayMetadata = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <metadata xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:xda="http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray">\
    <metadataTypes count="1"><metadataType name="XLDAPR" minSupportedVersion="120000" copy="1" pasteAll="1" pasteValues="1" merge="1" \
    splitFirst="1" rowColShift="1" clearFormats="1" clearComments="1" assign="1" coerce="1" cellMeta="1"/></metadataTypes>\
    <futureMetadata name="XLDAPR" count="1"><bk><extLst><ext uri="{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}">\
    <xda:dynamicArrayProperties fDynamic="1" fCollapsed="0"/></ext></extLst></bk></futureMetadata>\
    <cellMetadata count="1"><bk><rc t="1" v="0"/></bk></cellMetadata></metadata>
    """

    private static func sheetXML(_ sheet: Sheet, styleIndex: [CellStyle: Int], selected: Bool,
                                 extras: (filter: String, conditional: String, tail: String, types: String)) -> String {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        """
        if let tab = sheet.tabColor { x += "<sheetPr><tabColor rgb=\"\(argb(tab))\"/></sheetPr>" }
        if let used = sheet.usedRange { x += "<dimension ref=\"A1:\(used.end.a1)\"/>" }
        let split = sheet.frozenRows == 0 && sheet.frozenCols == 0 ? sheet.split.flatMap { $0.x > 0 || $0.y > 0 ? $0 : nil } : nil
        let viewTopLeft = split.map { $0.topLeft != CellRef(row: 0, col: 0) ? " topLeftCell=\"\($0.topLeft.a1)\"" : "" } ?? ""
        x += "<sheetViews><sheetView workbookViewId=\"0\"\(sheet.showGridlines ? "" : " showGridLines=\"0\"")\(selected ? " tabSelected=\"1\"" : "")\(viewTopLeft)>"
        if let s = split {
            let t = s.twips
            x += "<pane\(t.x > 0 ? " xSplit=\"\(t.x)\"" : "")\(t.y > 0 ? " ySplit=\"\(t.y)\"" : "") topLeftCell=\"\(s.paneTopLeft.a1)\" activePane=\"\(s.normalizedPane)\" state=\"split\"/>"
            x += "<selection pane=\"\(s.normalizedPane)\"/>"
        } else if sheet.frozenRows > 0 || sheet.frozenCols > 0 {
            let top = CellRef(row: sheet.frozenRows, col: sheet.frozenCols).a1
            x += "<pane\(sheet.frozenCols > 0 ? " xSplit=\"\(sheet.frozenCols)\"" : "")\(sheet.frozenRows > 0 ? " ySplit=\"\(sheet.frozenRows)\"" : "") topLeftCell=\"\(top)\" activePane=\"bottomRight\" state=\"frozen\"/>"
        }
        x += "</sheetView></sheetViews>"
        x += "<sheetFormatPr defaultRowHeight=\"\(fmt(sheet.defaultRowHeight))\" defaultColWidth=\"\(columnChars(sheet.defaultColumnWidth))\""
        if sheet.maxRowLevel > 0 { x += " outlineLevelRow=\"\(sheet.maxRowLevel)\"" }
        if sheet.maxColLevel > 0 { x += " outlineLevelCol=\"\(sheet.maxColLevel)\"" }
        x += "/>"
        // A summary row/column right after a collapsed group carries collapsed="1".
        func collapsed(_ i: Int, rows: Bool) -> Bool {
            i > 0 && sheet.isOutlineHidden(i - 1, rows: rows) && !sheet.isOutlineHidden(i, rows: rows) && sheet.level(i - 1, rows: rows) > sheet.level(i, rows: rows)
        }
        let colKeys = Set(sheet.columnWidths.keys).union(sheet.colLevels.keys).union(sheet.outlineHiddenCols)
            .union(sheet.outlineHiddenCols.map { $0 + 1 }.filter { collapsed($0, rows: false) })
        if !colKeys.isEmpty {
            x += "<cols>"
            for col in colKeys.sorted() {
                let w = sheet.columnWidths[col] ?? sheet.defaultColumnWidth
                let hidden = w == 0 || sheet.outlineHiddenCols.contains(col)
                x += "<col min=\"\(col + 1)\" max=\"\(col + 1)\" width=\"\(columnChars(w))\"\(sheet.columnWidths[col] != nil ? " customWidth=\"1\"" : "")"
                if hidden { x += " hidden=\"1\"" }
                if let l = sheet.colLevels[col] { x += " outlineLevel=\"\(l)\"" }
                if collapsed(col, rows: false) { x += " collapsed=\"1\"" }
                x += "/>"
            }
            x += "</cols>"
        }
        x += "<sheetData>"
        let byRow = Dictionary(grouping: sheet.cells.keys, by: \.row)
        let rows = Set(byRow.keys).union(sheet.rowHeights.keys).union(sheet.filterHidden).union(sheet.rowLevels.keys)
            .union(sheet.outlineHiddenRows).union(sheet.outlineHiddenRows.map { $0 + 1 }.filter { collapsed($0, rows: true) }).sorted()
        for r in rows {
            x += "<row r=\"\(r + 1)\""
            if sheet.filterHidden.contains(r) || sheet.outlineHiddenRows.contains(r) { x += " hidden=\"1\"" }
            if let h = sheet.rowHeights[r] { x += h == 0 ? (sheet.filterHidden.contains(r) || sheet.outlineHiddenRows.contains(r) ? "" : " hidden=\"1\"") : " ht=\"\(fmt(h))\" customHeight=\"1\"" }
            if let l = sheet.rowLevels[r] { x += " outlineLevel=\"\(l)\"" }
            if collapsed(r, rows: true) { x += " collapsed=\"1\"" }
            x += ">"
            for ref in (byRow[r] ?? []).sorted() {
                let cell = sheet.cells[ref]!
                let s = styleIndex[cell.style] ?? 0
                let sAttr = s == 0 ? "" : " s=\"\(s)\""
                if cell.isFormula {
                    let text = Calculator.expression(cell.input).map { Formula.serialize($0, forFile: true) } ?? String(cell.input.dropFirst())
                    // Spilling results are written as an array formula over their range (dynamic arrays marked with cm="1").
                    var fOpen = "<f>"
                    if let spill = sheet.arrays[ref] ?? sheet.spills[ref] {
                        fOpen = "<f t=\"array\" ref=\"\(spill.a1)\">"
                    } else if cell.array {
                        fOpen = "<f t=\"array\" ref=\"\(ref.a1)\">"
                    }
                    let cm = !cell.array && sheet.spills[ref] != nil ? " cm=\"1\"" : ""
                    let f = fOpen + xmlEscape(text) + "</f>"
                    let attrs = "r=\"\(ref.a1)\"\(sAttr)\(cm)"
                    switch cell.value {
                    case .string(let str): x += "<c \(attrs) t=\"str\">\(f)<v>\(xmlEscape(str))</v></c>"
                    case .bool(let b): x += "<c \(attrs) t=\"b\">\(f)<v>\(b ? 1 : 0)</v></c>"
                    case .error(let e): x += "<c \(attrs) t=\"e\">\(f)<v>\(xmlEscape(e))</v></c>"
                    case .number(let d): x += "<c \(attrs)>\(f)<v>\(numberText(d))</v></c>"
                    case .empty: x += "<c \(attrs)>\(f)</c>"
                    }
                    continue
                }
                switch cell.value {
                case .empty: x += "<c r=\"\(ref.a1)\"\(sAttr)/>"
                case .number(let d): x += "<c r=\"\(ref.a1)\"\(sAttr)><v>\(numberText(d))</v></c>"
                case .string(let str):
                    let space = str.hasPrefix(" ") || str.hasSuffix(" ") || str.contains("\n") ? " xml:space=\"preserve\"" : ""
                    x += "<c r=\"\(ref.a1)\"\(sAttr) t=\"inlineStr\"><is><t\(space)>\(xmlEscape(str))</t></is></c>"
                case .bool(let b): x += "<c r=\"\(ref.a1)\"\(sAttr) t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .error(let e): x += "<c r=\"\(ref.a1)\"\(sAttr) t=\"e\"><v>\(xmlEscape(e))</v></c>"
                }
            }
            x += "</row>"
        }
        x += "</sheetData>"
        if let p = sheet.protection {
            x += "<sheetProtection"
            if let h = p.passwordHash { x += " password=\"\(h)\"" }
            if let h = p.sha512Hash, let salt = p.sha512Salt {
                x += " algorithmName=\"SHA-512\" hashValue=\"\(h)\" saltValue=\"\(salt)\" spinCount=\"\(p.spinCount)\""
            }
            x += " sheet=\"1\" objects=\"1\" scenarios=\"1\"/>"
        }
        x += extras.filter
        if !sheet.merges.isEmpty {
            x += "<mergeCells count=\"\(sheet.merges.count)\">" + sheet.merges.map { "<mergeCell ref=\"\($0.a1)\"/>" }.joined() + "</mergeCells>"
        }
        x += extras.conditional
        x += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>" + extras.tail + "</worksheet>"
        return x
    }

    private static func stylesXML(_ styles: [CellStyle], dxfs: [Dxf], named definitions: [(name: String, style: CellStyle)]) -> String {
        var fonts: [String] = [], fills: [String] = ["<fill><patternFill patternType=\"none\"/></fill>", "<fill><patternFill patternType=\"gray125\"/></fill>"]
        var borders: [String] = ["<border><left/><right/><top/><bottom/><diagonal/></border>"]
        var numFmts: [String: Int] = [:]
        var xfs: [String] = []
        var namedStyles: [(name: String, xf: String)] = []
        func index(_ list: inout [String], _ item: String) -> Int {
            if let i = list.firstIndex(of: item) { return i }
            list.append(item)
            return list.count - 1
        }
        let builtinByCode = Dictionary(NumberFormat.builtin.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        func ids(_ s: CellStyle) -> (numFmt: Int, font: Int, fill: Int, border: Int) {
            var font = "<font>"
            if s.bold { font += "<b/>" }
            if s.italic { font += "<i/>" }
            if s.strike { font += "<strike/>" }
            if s.doubleUnderline { font += "<u val=\"double\"/>" } else if s.underline { font += "<u/>" }
            font += "<sz val=\"\(fmt(s.fontSize))\"/>"
            if let c = s.textColor { font += "<color rgb=\"\(argb(c))\"/>" }
            font += "<name val=\"\(xmlEscape(s.fontName ?? "Calibri"))\"/></font>"
            let fontId = index(&fonts, font)
            let fillId = s.fill.map { index(&fills, "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(argb($0))\"/><bgColor indexed=\"64\"/></patternFill></fill>") } ?? 0
            var border = "<border>"
            for (name, side) in [("left", s.left), ("right", s.right), ("top", s.top), ("bottom", s.bottom)] {
                if let side { border += "<\(name) style=\"\(side.style)\"><color rgb=\"\(argb(side.color))\"/></\(name)>" } else { border += "<\(name)/>" }
            }
            border += "<diagonal/></border>"
            let borderId = index(&borders, border)
            let numFmtId: Int
            if let id = builtinByCode[s.numberFormat] { numFmtId = id }
            else if let id = numFmts[s.numberFormat] { numFmtId = id }
            else { numFmtId = 164 + numFmts.count; numFmts[s.numberFormat] = numFmtId }
            return (numFmtId, fontId, fillId, borderId)
        }
        // Named styles (cellStyleXfs): the document's definitions, then presets, then the first cell using the name.
        for d in definitions {
            let i = ids(d.style)
            namedStyles.append((d.name, "<xf numFmtId=\"\(i.numFmt)\" fontId=\"\(i.font)\" fillId=\"\(i.fill)\" borderId=\"\(i.border)\"/>"))
        }
        for s in styles {
            let (numFmtId, fontId, fillId, borderId) = ids(s)
            let xfId = s.styleName.map { name -> Int in
                if let i = namedStyles.firstIndex(where: { $0.name == name }) { return i + 1 }
                namedStyles.append((name, "<xf numFmtId=\"\(numFmtId)\" fontId=\"\(fontId)\" fillId=\"\(fillId)\" borderId=\"\(borderId)\"/>"))
                return namedStyles.count
            } ?? 0
            var xf = "<xf numFmtId=\"\(numFmtId)\" fontId=\"\(fontId)\" fillId=\"\(fillId)\" borderId=\"\(borderId)\" xfId=\"\(xfId)\""
            xf += numFmtId != 0 ? " applyNumberFormat=\"1\"" : ""
            xf += fontId != 0 ? " applyFont=\"1\"" : ""
            xf += fillId != 0 ? " applyFill=\"1\"" : ""
            xf += borderId != 0 ? " applyBorder=\"1\"" : ""
            let hasAlign = s.hAlign != nil || s.vAlign != "bottom" || s.wrap || s.indent > 0 || s.rotation != 0 || s.shrink
            let hasProtection = !s.locked || s.hiddenFormula
            if hasAlign { xf += " applyAlignment=\"1\"" }
            if hasProtection { xf += " applyProtection=\"1\"" }
            if hasAlign || hasProtection {
                xf += ">"
                if hasAlign {
                    xf += "<alignment"
                    if let h = s.hAlign { xf += " horizontal=\"\(h)\"" }
                    if s.vAlign != "bottom" { xf += " vertical=\"\(s.vAlign)\"" }
                    if s.wrap { xf += " wrapText=\"1\"" }
                    if s.indent > 0 { xf += " indent=\"\(s.indent)\"" }
                    if s.rotation != 0 { xf += " textRotation=\"\(s.rotation < 0 ? 90 - s.rotation : s.rotation)\"" }
                    if s.shrink { xf += " shrinkToFit=\"1\"" }
                    xf += "/>"
                }
                if hasProtection { xf += "<protection\(s.locked ? "" : " locked=\"0\"")\(s.hiddenFormula ? " hidden=\"1\"" : "")/>" }
                xf += "</xf>"
            } else { xf += "/>" }
            xfs.append(xf)
        }
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !numFmts.isEmpty {
            x += "<numFmts count=\"\(numFmts.count)\">"
            for (code, id) in numFmts.sorted(by: { $0.value < $1.value }) { x += "<numFmt numFmtId=\"\(id)\" formatCode=\"\(xmlEscape(code))\"/>" }
            x += "</numFmts>"
        }
        x += "<fonts count=\"\(fonts.count)\">" + fonts.joined() + "</fonts>"
        x += "<fills count=\"\(fills.count)\">" + fills.joined() + "</fills>"
        x += "<borders count=\"\(borders.count)\">" + borders.joined() + "</borders>"
        x += "<cellStyleXfs count=\"\(namedStyles.count + 1)\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>" + namedStyles.map(\.xf).joined() + "</cellStyleXfs>"
        x += "<cellXfs count=\"\(xfs.count)\">" + xfs.joined() + "</cellXfs>"
        x += "<cellStyles count=\"\(namedStyles.count + 1)\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/>"
        for (i, n) in namedStyles.enumerated() {
            let builtin = CellStyles.builtinIds[n.name].map { " builtinId=\"\($0)\"" } ?? " customBuiltin=\"1\""
            x += "<cellStyle name=\"\(xmlEscape(n.name))\" xfId=\"\(i + 1)\"\(builtin)/>"
        }
        x += "</cellStyles>" + dxfsXML(dxfs) + "</styleSheet>"
        return x
    }

    private static func fmt(_ v: CGFloat) -> String { Value.formatGeneral(Double(v)) }

    private static func numberText(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.17g", d)
    }

    static func argb(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(format: "FF%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    // MARK: - CSV

    /// CSV/TSV text: encoding by BOM or validity (UTF-8, UTF-16, Windows-1251), delimiter detected
    /// from the first lines (outside quotes), RFC 4180 quoting with line breaks inside quotes.
    static func readCSV(_ data: Data) -> Workbook {
        let text = decodeText(data)
        let delimiter = detectDelimiter(text)
        var sheet = Sheet(name: "Sheet1")
        var row = 0, col = 0, field = "", quoted = false, wasQuoted = false
        func commit() {
            if !field.isEmpty {
                var cell = Cell()
                cell.input = field.hasPrefix("=") ? "'" + field : field
                cell.value = constant(field)
                sheet[CellRef(row: row, col: col)] = cell
            }
            field = ""
            wasQuoted = false
        }
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(ch) }
            } else if ch == "\"", field.isEmpty {
                quoted = true
                wasQuoted = true
            } else if Character(ch) == delimiter {
                commit(); col += 1
            } else if ch == "\n" || ch == "\r" {
                if ch == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                commit(); row += 1; col = 0
            } else {
                field.unicodeScalars.append(ch)
            }
            i += 1
        }
        commit()
        var wb = Workbook()
        wb.sheets = [sheet]
        return wb
    }

    static func decodeText(_ data: Data) -> String { TextDecoding.decode(data).text }

    /// The candidate that splits the first lines most consistently (quotes respected).
    static func detectDelimiter(_ text: String) -> Character {
        var lines: [[Character: Int]] = []
        var counts: [Character: Int] = [:]
        var quoted = false
        for ch in text.prefix(20_000) {
            if ch == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                if !counts.isEmpty { lines.append(counts) }
                counts = [:]
                if lines.count >= 20 { break }
                continue
            }
            if ";,\t|".contains(ch) { counts[ch, default: 0] += 1 }
        }
        if !counts.isEmpty { lines.append(counts) }
        guard !lines.isEmpty else { return "," }
        let candidates: [Character] = [";", "\t", ",", "|"]
        func score(_ c: Character) -> (Int, Int) {
            let n = lines.map { $0[c] ?? 0 }
            guard let first = n.first, first > 0 else { return (0, 0) }
            return (n.filter { $0 == first }.count, first)
        }
        return candidates.max { score($0) < score($1) } ?? ","
    }

    static func writeCSV(_ sheet: Sheet, date1904: Bool = false) throws -> Data {
        try SheetExport.validateCSVSize(sheet)
        guard let used = sheet.usedRange else { return Data() }
        var lines: [String] = []
        for r in 0...used.end.row {
            var fields: [String] = []
            for c in 0...used.end.col {
                let cell = sheet[CellRef(row: r, col: c)]
                var s = NumberFormat.format(cell.value, cell.style.numberFormat, date1904: date1904).text
                if case .number(let d) = cell.value, cell.style.numberFormat == "General" { s = Value.numberLiteral(d) }
                if s.contains(where: { ",;\"\n\r".contains($0) }) { s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                fields.append(s)
            }
            lines.append(fields.joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Value of typed text: number, percent, date, boolean or text ("'" forces text).
    static func constant(_ input: String, date1904: Bool = false) -> Value {
        if input.isEmpty { return .empty }
        if input.hasPrefix("'") { return .string(String(input.dropFirst())) }
        let t = input.trimmingCharacters(in: .whitespaces)
        switch t.uppercased() {
        case "TRUE", "ИСТИНА", "DOĞRU": return .bool(true)
        case "FALSE", "ЛОЖЬ", "YANLIŞ": return .bool(false)
        default: break
        }
        let normalized = t.replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: " ", with: "")
        if let d = Double(normalized) { return .number(d) }
        if NumberFormat.decimal == ",", let d = Double(normalized.replacingOccurrences(of: ",", with: ".")) { return .number(d) }
        if normalized.hasSuffix("%"), case .number(let d) = constant(String(normalized.dropLast())) { return .number(d / 100) }
        if let d = DateMath.parse(t, date1904: date1904) { return .number(d) }
        return .string(input)
    }
}
