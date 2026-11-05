import AppKit
import Kit42

/// Sheet parts beyond cells: autofilter, conditional formatting, comments, pictures and charts.
extension XLSX {
    struct Dxf { var fill: NSColor?; var text: NSColor?; var bold = false }

    // MARK: - Reading

    static func readDxfs(_ styles: XMLElement?, theme: [NSColor]) -> [Dxf] {
        (styles?.child("dxfs")?.children("dxf") ?? []).map { d in
            var x = Dxf()
            if let f = d.child("font") {
                x.text = f.child("color").flatMap { color($0, theme: theme) }
                x.bold = f.child("b").map { $0.attr("val") != "0" } ?? false
            }
            if let p = d.child("fill")?.child("patternFill") {
                x.fill = p.child("bgColor").flatMap { color($0, theme: theme) } ?? p.child("fgColor").flatMap { color($0, theme: theme) }
            }
            return x
        }
    }

    static func readExtras(_ sheet: inout Sheet, root: XMLElement, path: String, zip: ZipArchive, dxfs: [Dxf], theme: [NSColor]) {
        // Sheet protection
        if let p = root.child("sheetProtection"), p.attr("sheet") == "1" || p.attr("sheet") == "true" {
            var prot = SheetProtection(passwordHash: p.attr("password"))
            if p.attr("algorithmName") == "SHA-512" {
                prot.sha512Hash = p.attr("hashValue")
                prot.sha512Salt = p.attr("saltValue")
                prot.spinCount = p.attr("spinCount").flatMap(Int.init) ?? 100_000
            }
            sheet.protection = prot
        }
        // Data validation
        for dv in root.child("dataValidations")?.children("dataValidation") ?? [] {
            let ranges = (dv.attr("sqref") ?? "").split(separator: " ").compactMap { CellRange(String($0)) }
            guard !ranges.isEmpty, let type = dv.attr("type"), let kind = DataValidation.Kind(rawValue: type) else { continue }
            var v = DataValidation(ranges: ranges, kind: kind)
            v.op = dv.attr("operator") ?? "between"
            v.formula1 = dv.child("formula1")?.stringValue ?? ""
            v.formula2 = dv.child("formula2")?.stringValue ?? ""
            v.allowBlank = dv.attr("allowBlank") == "1" || dv.attr("allowBlank") == "true"
            v.showDropdown = !(dv.attr("showDropDown") == "1" || dv.attr("showDropDown") == "true")   // inverted in the file format
            v.errorStyle = dv.attr("errorStyle") ?? "stop"
            v.errorTitle = dv.attr("errorTitle") ?? ""
            v.errorMessage = dv.attr("error") ?? ""
            sheet.validations.append(v)
        }
        // AutoFilter
        if let af = root.child("autoFilter"), let range = af.attr("ref").flatMap(CellRange.init) {
            sheet.autoFilter = range
            for fc in af.children("filterColumn") {
                if let id = fc.attr("colId").flatMap(Int.init), let cf = readCustomFilter(fc) { sheet.customFilters[range.start.col + id] = cf; continue }
                guard let id = fc.attr("colId").flatMap(Int.init), let filters = fc.child("filters") else { continue }
                var values = Set(filters.children("filter").compactMap { $0.attr("val") })
                if filters.attr("blank") == "1" { values.insert("") }
                sheet.filterValues[range.start.col + id] = values
            }
            if range.end.row > range.start.row {
                for r in (range.start.row + 1)...range.end.row where sheet.rowHeights[r] == 0 {
                    sheet.rowHeights[r] = nil
                    sheet.filterHidden.insert(r)
                }
            }
        }
        // Conditional formatting
        for cf in root.children("conditionalFormatting") {
            let ranges = (cf.attr("sqref") ?? "").split(separator: " ").compactMap { CellRange(String($0)) }
            for rule in cf.children("cfRule") {
                let formulas = rule.children("formula").compactMap(\.stringValue)
                let kind: ConditionalFormat.Kind?
                switch rule.attr("type") {
                case "cellIs": kind = .cellIs(op: rule.attr("operator") ?? "equal", values: formulas)
                case "containsText": kind = .containsText(rule.attr("text") ?? "")
                case "expression": kind = formulas.first.map { .expression($0) }
                case "duplicateValues": kind = .duplicates
                case "colorScale":
                    let colors = (rule.child("colorScale")?.children("color") ?? []).compactMap { color($0, theme: theme) }
                    kind = colors.count >= 2 ? .colorScale(colors) : nil
                case "dataBar": kind = .dataBar(rule.child("dataBar")?.child("color").flatMap { color($0, theme: theme) } ?? .systemBlue)
                default: kind = nil
                }
                guard let kind else { continue }
                let dxf = rule.attr("dxfId").flatMap(Int.init).flatMap { $0 < dxfs.count ? dxfs[$0] : nil }
                for range in ranges {
                    sheet.conditionalFormats.append(ConditionalFormat(range: range, kind: kind, fill: dxf?.fill, textColor: dxf?.text, bold: dxf?.bold ?? false))
                }
            }
        }
        // Relationships of the sheet
        let dir = (path as NSString).deletingLastPathComponent
        let relsPath = dir + "/_rels/" + (path as NSString).lastPathComponent + ".rels"
        let rels = relations(zip, relsPath, base: dir)
        // Comments
        for (_, (type, target)) in rels where type.hasSuffix("/comments") {
            guard let data = zip[target], let c = (try? XMLDocument(data: data))?.rootElement() else { continue }
            for comment in c.child("commentList")?.children("comment") ?? [] {
                guard let ref = comment.attr("ref").flatMap(CellRef.init) else { continue }
                sheet.comments[ref] = comment.child("text")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Hyperlinks: external targets in the relationships, places in the workbook as location.
        if let links = root.child("hyperlinks") {
            let raw = rawRelations(zip, relsPath)
            for h in links.children("hyperlink") {
                guard let range = h.attr("ref").flatMap(CellRange.init) else { continue }
                var target: String?
                if let id = h.attr("id"), let t = raw[id] { target = t + (h.attr("location").map { "#" + $0 } ?? "") }
                else if let loc = h.attr("location") { target = "#" + loc }
                if let target { for ref in range.cells.prefix(1000) { sheet.hyperlinks[ref] = target } }
            }
        }
        if let breaks = root.child("rowBreaks") {
            for b in breaks.children("brk") { if let id = b.attr("id").flatMap(Int.init), id > 0 { sheet.rowBreaks.insert(id) } }
        }
        // Drawings: pictures and charts
        guard let drawingID = root.child("drawing")?.attr("id"), let (_, drawingPath) = rels[drawingID],
              let data = zip[drawingPath], let drawing = (try? XMLDocument(data: data))?.rootElement() else { return }
        let ddir = (drawingPath as NSString).deletingLastPathComponent
        let drels = relations(zip, ddir + "/_rels/" + (drawingPath as NSString).lastPathComponent + ".rels", base: ddir)
        for anchor in (drawing.children ?? []).compactMap({ $0 as? XMLElement }) {
            guard let from = anchor.child("from"),
                  let col = from.child("col")?.stringValue.flatMap(Int.init), let row = from.child("row")?.stringValue.flatMap(Int.init) else { continue }
            let colOff = CGFloat(from.child("colOff")?.stringValue.flatMap(Double.init) ?? 0) / 12700
            let rowOff = CGFloat(from.child("rowOff")?.stringValue.flatMap(Double.init) ?? 0) / 12700
            var size = CGSize(width: 300, height: 200)
            if let ext = anchor.child("ext") ?? anchor.child("pic")?.child("spPr")?.child("xfrm")?.child("ext")
                ?? anchor.child("graphicFrame")?.child("xfrm")?.child("ext"),
               let cx = ext.attr("cx").flatMap(Double.init), let cy = ext.attr("cy").flatMap(Double.init), cx > 0 {
                size = CGSize(width: cx / 12700, height: cy / 12700)
            }
            if anchor.localName == "twoCellAnchor", let to = anchor.child("to"),
               let c2 = to.child("col")?.stringValue.flatMap(Int.init), let r2 = to.child("row")?.stringValue.flatMap(Int.init) {
                let c2off = CGFloat(to.child("colOff")?.stringValue.flatMap(Double.init) ?? 0) / 12700
                let r2off = CGFloat(to.child("rowOff")?.stringValue.flatMap(Double.init) ?? 0) / 12700
                let w = (col..<max(col, c2)).reduce(0) { $0 + sheet.width($1) } - colOff + c2off
                let h = (row..<max(row, r2)).reduce(0) { $0 + sheet.height($1) } - rowOff + r2off
                if w > 0, h > 0 { size = CGSize(width: w, height: h) }
            }
            let anchorRef = CellRef(row: row, col: col)
            if let blip = anchor.child("pic")?.child("blipFill")?.child("blip"), let id = blip.attr("embed"),
               let (_, target) = drels[id], let png = zip[target] {
                sheet.images.append(SheetImage(anchor: anchorRef, offset: CGPoint(x: colOff, y: rowOff), size: size, data: png))
            } else if let chartRef = anchor.child("graphicFrame")?.child("graphic")?.child("graphicData")?.child("chart"),
                      let id = chartRef.attr("id"), let (_, target) = drels[id], let cdata = zip[target],
                      let chartXML = (try? XMLDocument(data: cdata))?.rootElement(), var chart = parseChart(chartXML) {
                chart.anchor = anchorRef
                chart.size = size
                sheet.charts.append(chart)
            }
        }
    }

    /// Relationship targets as written (external URLs aren't paths).
    static func rawRelations(_ zip: ZipArchive, _ path: String) -> [String: String] {
        guard let data = zip[path], let root = (try? XMLDocument(data: data))?.rootElement() else { return [:] }
        var out: [String: String] = [:]
        for r in root.children("Relationship") { if let id = r.attr("Id"), let t = r.attr("Target") { out[id] = t } }
        return out
    }

    static func relations(_ zip: ZipArchive, _ path: String, base: String) -> [String: (String, String)] {
        guard let data = zip[path], let root = (try? XMLDocument(data: data))?.rootElement() else { return [:] }
        var out: [String: (String, String)] = [:]
        for r in root.children("Relationship") {
            guard let id = r.attr("Id"), let type = r.attr("Type"), let target = r.attr("Target") else { continue }
            out[id] = (type, resolve(target, base: base))
        }
        return out
    }

    static func resolve(_ target: String, base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        for p in target.split(separator: "/") {
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }

    static func parseChart(_ root: XMLElement) -> SheetChart? {
        guard let chart = root.child("chart"), let plot = chart.child("plotArea") else { return nil }
        let title = chart.child("title")?.allText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let types: [(String, SheetChart.Kind)] = [("barChart", .column), ("bar3DChart", .column), ("lineChart", .line), ("line3DChart", .line),
                                                  ("pieChart", .pie), ("pie3DChart", .pie), ("doughnutChart", .pie), ("areaChart", .area),
                                                  ("scatterChart", .scatter)]
        for (name, kind) in types {
            guard let group = plot.child(name) else { continue }
            var k = kind
            if kind == .column, group.child("barDir")?.attr("val") == "bar" { k = .bar }
            let series: [SheetChart.Series] = group.children("ser").compactMap { ser in
                let values = (ser.child("val") ?? ser.child("yVal"))?.child("numRef")?.child("f")?.stringValue
                guard let values else { return nil }
                let cat = (ser.child("cat") ?? ser.child("xVal")).flatMap { $0.child("strRef")?.child("f")?.stringValue ?? $0.child("numRef")?.child("f")?.stringValue }
                let name = ser.child("tx")?.child("strRef")?.child("f")?.stringValue.map { "=" + $0 } ?? ser.child("tx")?.allText ?? ""
                return .init(name: name, categories: cat, values: values)
            }
            return SheetChart(kind: k, title: title, series: series, anchor: CellRef(row: 0, col: 0), size: .zero)
        }
        return nil
    }

    // MARK: - Writing

    struct Counters { var drawing = 0, chart = 0, image = 0, comments = 0 }

    /// Writes the sheet's extra parts into the package; returns XML for the worksheet and content-type overrides.
    /// AutoFilter conditions as Excel stores them: <customFilters> (wildcards for contains/begins/ends), <top10>, blanks.
    static func customFilterXML(_ f: ColumnFilter) -> String {
        if let c = f.conditions.first, [.top, .bottom, .topPercent, .bottomPercent].contains(c.op) {
            let top = c.op == .top || c.op == .topPercent, percent = c.op == .topPercent || c.op == .bottomPercent
            return "<top10\(top ? "" : " top=\"0\"")\(percent ? " percent=\"1\"" : "") val=\"\(xmlEscape(c.value))\"/>"
        }
        if f.conditions.count == 1, f.conditions[0].op == .empty { return "<filters blank=\"1\"/>" }
        var x = "<customFilters\(f.and && f.conditions.count > 1 ? " and=\"1\"" : "")>"
        for c in f.conditions.prefix(2) {
            let (op, val): (String, String)
            switch c.op {
            case .contains: (op, val) = ("equal", "*\(c.value)*")
            case .notContains: (op, val) = ("notEqual", "*\(c.value)*")
            case .beginsWith: (op, val) = ("equal", "\(c.value)*")
            case .endsWith: (op, val) = ("equal", "*\(c.value)")
            case .notEmpty: (op, val) = ("notEqual", " ")
            case .empty: (op, val) = ("equal", "")
            default: (op, val) = (c.op.rawValue, c.value)
            }
            x += "<customFilter\(op == "equal" ? "" : " operator=\"\(op)\"") val=\"\(xmlEscape(val))\"/>"
        }
        return x + "</customFilters>"
    }

    static func readCustomFilter(_ fc: XMLElement) -> ColumnFilter? {
        if let t = fc.child("top10") {
            let top = t.attr("top") != "0", percent = t.attr("percent") == "1"
            let op: FilterCondition.Op = top ? (percent ? .topPercent : .top) : (percent ? .bottomPercent : .bottom)
            return ColumnFilter(conditions: [FilterCondition(op: op, value: t.attr("val") ?? "10")])
        }
        guard let cfs = fc.child("customFilters") else { return nil }
        var conditions: [FilterCondition] = []
        for c in cfs.children("customFilter") {
            let op = c.attr("operator") ?? "equal", val = c.attr("val") ?? ""
            let inner = val.count >= 2 ? String(val.dropFirst().dropLast()) : ""
            if op == "notEqual", val == " " { conditions.append(.init(op: .notEmpty)); continue }
            if op == "equal" || op == "notEqual" {
                let eq = op == "equal"
                if val.hasPrefix("*"), val.hasSuffix("*"), val.count >= 2, !inner.contains("*") { conditions.append(.init(op: eq ? .contains : .notContains, value: inner)); continue }
                if eq, val.hasSuffix("*"), !val.dropLast().contains("*") { conditions.append(.init(op: .beginsWith, value: String(val.dropLast()))); continue }
                if eq, val.hasPrefix("*"), !val.dropFirst().contains("*") { conditions.append(.init(op: .endsWith, value: String(val.dropFirst()))); continue }
            }
            guard let o = FilterCondition.Op(rawValue: op) else { continue }
            conditions.append(.init(op: o, value: val))
        }
        guard !conditions.isEmpty else { return nil }
        return ColumnFilter(conditions: conditions, and: cfs.attr("and") == "1" || cfs.attr("and") == "true")
    }

    static func writeExtras(_ sheet: Sheet, sheetNumber: Int, zip: inout ZipArchive, counters: inout Counters, dxfs: inout [Dxf])
        -> (filter: String, conditional: String, tail: String, types: String) {
        var filter = "", conditional = "", tail = "", types = ""
        if let f = sheet.autoFilter {
            filter = "<autoFilter ref=\"\(f.a1)\">"
            for (col, cf) in sheet.customFilters.sorted(by: { $0.key < $1.key }) where f.cols.contains(col) {
                filter += "<filterColumn colId=\"\(col - f.start.col)\">" + customFilterXML(cf) + "</filterColumn>"
            }
            for (col, values) in sheet.filterValues.sorted(by: { $0.key < $1.key }) where sheet.customFilters[col] == nil {
                filter += "<filterColumn colId=\"\(col - f.start.col)\"><filters\(values.contains("") ? " blank=\"1\"" : "")>"
                filter += values.filter { !$0.isEmpty }.sorted().map { "<filter val=\"\(xmlEscape($0))\"/>" }.joined()
                filter += "</filters></filterColumn>"
            }
            filter += "</autoFilter>"
        }
        var priority = 1
        for rule in sheet.conditionalFormats {
            var dxfAttr = ""
            if rule.fill != nil || rule.textColor != nil || rule.bold {
                dxfs.append(Dxf(fill: rule.fill, text: rule.textColor, bold: rule.bold))
                dxfAttr = " dxfId=\"\(dxfs.count - 1)\""
            }
            let first = rule.range.start.a1
            var body: String
            switch rule.kind {
            case .cellIs(let op, let values):
                body = "<cfRule type=\"cellIs\"\(dxfAttr) priority=\"\(priority)\" operator=\"\(op)\">" + values.map { "<formula>\(xmlEscape(formulaText($0)))</formula>" }.joined() + "</cfRule>"
            case .containsText(let t):
                body = "<cfRule type=\"containsText\"\(dxfAttr) priority=\"\(priority)\" operator=\"containsText\" text=\"\(xmlEscape(t))\"><formula>NOT(ISERROR(SEARCH(\(xmlEscape("\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"")),\(first))))</formula></cfRule>"
            case .expression(let f):
                body = "<cfRule type=\"expression\"\(dxfAttr) priority=\"\(priority)\"><formula>\(xmlEscape(formulaText(f)))</formula></cfRule>"
            case .duplicates:
                body = "<cfRule type=\"duplicateValues\"\(dxfAttr) priority=\"\(priority)\"/>"
            case .colorScale(let colors):
                let cfvo = colors.count == 3 ? "<cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>" : "<cfvo type=\"min\"/><cfvo type=\"max\"/>"
                body = "<cfRule type=\"colorScale\" priority=\"\(priority)\"><colorScale>\(cfvo)" + colors.map { "<color rgb=\"\(argb($0))\"/>" }.joined() + "</colorScale></cfRule>"
            case .dataBar(let c):
                body = "<cfRule type=\"dataBar\" priority=\"\(priority)\"><dataBar><cfvo type=\"min\"/><cfvo type=\"max\"/><color rgb=\"\(argb(c))\"/></dataBar></cfRule>"
            }
            conditional += "<conditionalFormatting sqref=\"\(rule.range.a1)\">\(body)</conditionalFormatting>"
            priority += 1
        }
        if !sheet.validations.isEmpty {
            conditional += "<dataValidations count=\"\(sheet.validations.count)\">"
            for v in sheet.validations {
                conditional += "<dataValidation type=\"\(v.kind.rawValue)\""
                if v.kind != .list && v.kind != .custom && v.op != "between" { conditional += " operator=\"\(v.op)\"" }
                conditional += " errorStyle=\"\(v.errorStyle)\""
                if v.allowBlank { conditional += " allowBlank=\"1\"" }
                if v.kind == .list && !v.showDropdown { conditional += " showDropDown=\"1\"" }
                conditional += " showErrorMessage=\"1\""
                if !v.errorTitle.isEmpty { conditional += " errorTitle=\"\(xmlEscape(v.errorTitle))\"" }
                if !v.errorMessage.isEmpty { conditional += " error=\"\(xmlEscape(v.errorMessage))\"" }
                conditional += " sqref=\"\(v.ranges.map(\.a1).joined(separator: " "))\">"
                conditional += "<formula1>\(xmlEscape(v.formula1))</formula1>"
                if v.usesSecondValue && v.kind != .list && v.kind != .custom && !v.formula2.isEmpty { conditional += "<formula2>\(xmlEscape(v.formula2))</formula2>" }
                conditional += "</dataValidation>"
            }
            conditional += "</dataValidations>"
        }

        var rels: [String] = []
        // Pictures and charts → one drawing part
        if !sheet.images.isEmpty || !sheet.charts.isEmpty {
            counters.drawing += 1
            let d = counters.drawing
            var drawing = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">
            """
            var drels: [String] = []
            var id = 1
            func from(_ a: CellRef, _ off: CGPoint) -> String {
                "<xdr:from><xdr:col>\(a.col)</xdr:col><xdr:colOff>\(Int(off.x * 12700))</xdr:colOff><xdr:row>\(a.row)</xdr:row><xdr:rowOff>\(Int(off.y * 12700))</xdr:rowOff></xdr:from>"
            }
            for img in sheet.images {
                counters.image += 1
                zip["xl/media/image\(counters.image).png"] = pngData(img.data)
                drels.append("<Relationship Id=\"rId\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"../media/image\(counters.image).png\"/>")
                drawing += "<xdr:oneCellAnchor>\(from(img.anchor, img.offset))<xdr:ext cx=\"\(Int(img.size.width * 12700))\" cy=\"\(Int(img.size.height * 12700))\"/>"
                drawing += "<xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"\(id + 1)\" name=\"Picture \(id)\"/><xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr>"
                drawing += "<xdr:blipFill><a:blip r:embed=\"rId\(id)\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>"
                drawing += "<xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(Int(img.size.width * 12700))\" cy=\"\(Int(img.size.height * 12700))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>"
                id += 1
            }
            for ch in sheet.charts {
                counters.chart += 1
                zip["xl/charts/chart\(counters.chart).xml"] = Data(chartXML(ch).utf8)
                types += "<Override PartName=\"/xl/charts/chart\(counters.chart).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawingml.chart+xml\"/>"
                drels.append("<Relationship Id=\"rId\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart\" Target=\"../charts/chart\(counters.chart).xml\"/>")
                drawing += "<xdr:oneCellAnchor>\(from(ch.anchor, .zero))<xdr:ext cx=\"\(Int(ch.size.width * 12700))\" cy=\"\(Int(ch.size.height * 12700))\"/>"
                drawing += "<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr><xdr:cNvPr id=\"\(id + 1)\" name=\"Chart \(id)\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>"
                drawing += "<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">"
                drawing += "<c:chart r:id=\"rId\(id)\"/></a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:oneCellAnchor>"
                id += 1
            }
            drawing += "</xdr:wsDr>"
            zip["xl/drawings/drawing\(d).xml"] = Data(drawing.utf8)
            zip["xl/drawings/_rels/drawing\(d).xml.rels"] = Data(relsXML(drels).utf8)
            types += "<Override PartName=\"/xl/drawings/drawing\(d).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>"
            rels.append("<Relationship Id=\"rIdDrawing\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\" Target=\"../drawings/drawing\(d).xml\"/>")
            tail += "<drawing r:id=\"rIdDrawing\"/>"
        }
        // Comments (+ legacy VML so Excel shows them)
        if !sheet.comments.isEmpty {
            counters.comments += 1
            let n = counters.comments
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<comments xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><authors><author>XLS42</author></authors><commentList>"
            var vml = """
            <xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel">\
            <o:shapelayout v:ext="edit"><o:idmap v:ext="edit" data="\(n)"/></o:shapelayout>\
            <v:shapetype id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe"><v:stroke joinstyle="miter"/>\
            <v:path gradientshapeok="t" o:connecttype="rect"/></v:shapetype>
            """
            for (k, (ref, text)) in sheet.comments.sorted(by: { $0.key < $1.key }).enumerated() {
                xml += "<comment ref=\"\(ref.a1)\" authorId=\"0\"><text><r><t xml:space=\"preserve\">\(xmlEscape(text))</t></r></text></comment>"
                vml += """
                <v:shape id="_x0000_s\(n * 1024 + k + 1)" type="#_x0000_t202" style="position:absolute;margin-left:80pt;margin-top:2pt;width:120pt;height:60pt;z-index:\(k + 1);visibility:hidden" \
                fillcolor="#ffffe1" o:insetmode="auto"><v:fill color2="#ffffe1"/><v:shadow on="t" color="black" obscured="t"/><v:path o:connecttype="none"/>\
                <v:textbox style="mso-direction-alt:auto"><div style="text-align:left"></div></v:textbox><x:ClientData ObjectType="Note"><x:MoveWithCells/><x:SizeWithCells/>\
                <x:Anchor>\(ref.col + 1), 15, \(ref.row), 2, \(ref.col + 3), 15, \(ref.row + 4), 4</x:Anchor><x:AutoFill>False</x:AutoFill><x:Row>\(ref.row)</x:Row><x:Column>\(ref.col)</x:Column></x:ClientData></v:shape>
                """
            }
            xml += "</commentList></comments>"
            vml += "</xml>"
            zip["xl/comments\(n).xml"] = Data(xml.utf8)
            zip["xl/drawings/vmlDrawing\(n).vml"] = Data(vml.utf8)
            types += "<Override PartName=\"/xl/comments\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml\"/>"
            rels.append("<Relationship Id=\"rIdComments\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments\" Target=\"../comments\(n).xml\"/>")
            rels.append("<Relationship Id=\"rIdVml\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing\" Target=\"../drawings/vmlDrawing\(n).vml\"/>")
            tail += "<legacyDrawing r:id=\"rIdVml\"/>"
        }
        if !sheet.hyperlinks.isEmpty {
            conditional += "<hyperlinks>"
            for (k, (ref, target)) in sheet.hyperlinks.sorted(by: { $0.key < $1.key }).enumerated() {
                if target.hasPrefix("#") {
                    conditional += "<hyperlink ref=\"\(ref.a1)\" location=\"\(xmlEscape(String(target.dropFirst())))\"/>"
                } else {
                    rels.append("<Relationship Id=\"rIdLink\(k + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(target))\" TargetMode=\"External\"/>")
                    conditional += "<hyperlink ref=\"\(ref.a1)\" r:id=\"rIdLink\(k + 1)\"/>"
                }
            }
            conditional += "</hyperlinks>"
        }
        if !sheet.rowBreaks.isEmpty {
            let breaks = sheet.rowBreaks.sorted()
            tail = "<rowBreaks count=\"\(breaks.count)\" manualBreakCount=\"\(breaks.count)\">" + breaks.map { "<brk id=\"\($0)\" max=\"16383\" man=\"1\"/>" }.joined() + "</rowBreaks>" + tail
        }
        if !rels.isEmpty { zip["xl/worksheets/_rels/sheet\(sheetNumber).xml.rels"] = Data(relsXML(rels).utf8) }
        return (filter, conditional, tail, types)
    }

    private static func formulaText(_ s: String) -> String { s.hasPrefix("=") ? String(s.dropFirst()) : s }

    private static func relsXML(_ items: [String]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + items.joined() + "</Relationships>"
    }

    private static func pngData(_ data: Data) -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let img = NSImage(data: data), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return data }
        return png
    }

    static func chartXML(_ chart: SheetChart) -> String {
        let kind = chart.kind
        var plot = ""
        func series() -> String {
            chart.series.enumerated().map { i, s in
                var x = "<c:ser><c:idx val=\"\(i)\"/><c:order val=\"\(i)\"/>"
                if s.name.hasPrefix("=") { x += "<c:tx><c:strRef><c:f>\(xmlEscape(String(s.name.dropFirst())))</c:f></c:strRef></c:tx>" }
                else if !s.name.isEmpty { x += "<c:tx><c:v>\(xmlEscape(s.name))</c:v></c:tx>" }
                if kind == .line { x += "<c:marker><c:symbol val=\"circle\"/></c:marker>" }
                if kind == .scatter {
                    if let c = s.categories { x += "<c:xVal><c:numRef><c:f>\(xmlEscape(c))</c:f></c:numRef></c:xVal>" }
                    x += "<c:yVal><c:numRef><c:f>\(xmlEscape(s.values))</c:f></c:numRef></c:yVal>"
                } else {
                    if let c = s.categories { x += "<c:cat><c:strRef><c:f>\(xmlEscape(c))</c:f></c:strRef></c:cat>" }
                    x += "<c:val><c:numRef><c:f>\(xmlEscape(s.values))</c:f></c:numRef></c:val>"
                }
                return x + "</c:ser>"
            }.joined()
        }
        let axes = "<c:axId val=\"111\"/><c:axId val=\"222\"/>"
        switch kind {
        case .column, .bar:
            plot = "<c:barChart><c:barDir val=\"\(kind == .bar ? "bar" : "col")\"/><c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>\(series())<c:gapWidth val=\"150\"/>\(axes)</c:barChart>"
        case .line:
            plot = "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(series())<c:marker val=\"1\"/>\(axes)</c:lineChart>"
        case .area:
            plot = "<c:areaChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>\(series())\(axes)</c:areaChart>"
        case .scatter:
            plot = "<c:scatterChart><c:scatterStyle val=\"lineMarker\"/><c:varyColors val=\"0\"/>\(series())\(axes)</c:scatterChart>"
        case .pie:
            plot = "<c:pieChart><c:varyColors val=\"1\"/>\(series())<c:firstSliceAng val=\"0\"/></c:pieChart>"
        }
        if kind != .pie {
            let catAx = kind == .scatter ? "<c:valAx><c:axId val=\"111\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"b\"/><c:crossAx val=\"222\"/></c:valAx>"
                : "<c:catAx><c:axId val=\"111\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(kind == .bar ? "l" : "b")\"/><c:crossAx val=\"222\"/></c:catAx>"
            plot += catAx + "<c:valAx><c:axId val=\"222\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(kind == .bar ? "b" : "l")\"/><c:majorGridlines/><c:crossAx val=\"111\"/></c:valAx>"
        }
        let title = chart.title.isEmpty ? "<c:autoTitleDeleted val=\"1\"/>"
            : "<c:title><c:tx><c:rich><a:bodyPr/><a:p><a:r><a:t>\(xmlEscape(chart.title))</a:t></a:r></a:p></c:rich></c:tx><c:overlay val=\"0\"/></c:title><c:autoTitleDeleted val=\"0\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><c:chart>\(title)<c:plotArea><c:layout/>\(plot)</c:plotArea>\
        <c:legend><c:legendPos val="b"/><c:overlay val="0"/></c:legend><c:plotVisOnly val="1"/></c:chart></c:chartSpace>
        """
    }

    static func dxfsXML(_ dxfs: [Dxf]) -> String {
        guard !dxfs.isEmpty else { return "" }
        return "<dxfs count=\"\(dxfs.count)\">" + dxfs.map { d in
            var x = "<dxf>"
            if d.bold || d.text != nil { x += "<font>\(d.bold ? "<b/>" : "")\(d.text.map { "<color rgb=\"\(argb($0))\"/>" } ?? "")</font>" }
            if let f = d.fill { x += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"\(argb(f))\"/><bgColor rgb=\"\(argb(f))\"/></patternFill></fill>" }
            return x + "</dxf>"
        }.joined() + "</dxfs>"
    }
}
