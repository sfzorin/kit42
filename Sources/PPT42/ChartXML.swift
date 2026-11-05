import AppKit
import Kit42

/// DrawingML charts (c:chartSpace): reading the model from a chart part, writing new chart parts with data caches
/// and an embedded workbook.
enum ChartXML {
    static let nsC = "http://schemas.openxmlformats.org/drawingml/2006/chart"
    static let types = ["barChart", "bar3DChart", "lineChart", "line3DChart", "pieChart", "pie3DChart", "doughnutChart", "ofPieChart",
                        "areaChart", "area3DChart", "scatterChart", "bubbleChart", "radarChart", "stockChart", "surfaceChart"]

    // MARK: Reading

    static func read(_ root: XMLElement, color: (XMLElement?) -> PColor?) -> ChartModel {
        var m = ChartModel()
        m.legend = nil
        if let sz = root.child("txPr")?.descendants("defRPr").first?.num("sz") { m.textSize = sz / 100 }
        if let c = color(root.child("txPr")?.descendants("defRPr").first?.child("solidFill")) { m.textColor = c }
        guard let chart = root.child("chart") else { return m }
        if let t = chart.child("title") {
            m.title = titleText(t)
            if let sz = t.descendants("defRPr").first?.num("sz") ?? t.descendants("rPr").first?.num("sz") { m.titleSize = sz / 100 }
            if let b = t.descendants("rPr").first?.bool("b") ?? t.descendants("defRPr").first?.bool("b") { m.titleBold = b }
        }
        let autoDeleted = chart.child("autoTitleDeleted")?.bool("val") ?? false
        if let lg = chart.child("legend") { m.legend = lg.child("legendPos")?.a("val") ?? "r"; if m.legend == "tr" { m.legend = "r" } }
        guard let plot = chart.child("plotArea") else { return m }
        let charts = plot.elements.filter { types.contains($0.localName ?? "") }
        guard let first = charts.first else { return m }
        switch first.localName ?? "" {
        case "barChart", "bar3DChart": m.kind = first.child("barDir")?.a("val") == "bar" ? .bar : .column
        case "lineChart", "line3DChart", "stockChart", "radarChart": m.kind = .line
        case "pieChart", "pie3DChart", "ofPieChart": m.kind = .pie
        case "doughnutChart": m.kind = .doughnut
        case "areaChart", "area3DChart", "surfaceChart": m.kind = .area
        case "scatterChart", "bubbleChart": m.kind = .scatter
        default: m.kind = .column
        }
        switch first.child("grouping")?.a("val") {
        case "stacked": m.grouping = .stacked
        case "percentStacked": m.grouping = .percentStacked
        default: m.grouping = .clustered
        }
        m.varyColors = first.child("varyColors")?.bool("val") ?? (m.kind == .pie || m.kind == .doughnut)
        if let g = first.child("gapWidth")?.int("val") { m.gapWidth = g }
        if let o = first.child("overlap")?.int("val") { m.overlap = o }
        if let h = first.child("holeSize")?.int("val") { m.holeSize = h }
        func labels(_ d: XMLElement?) {
            guard let d, d.child("delete")?.bool("val") != true else { return }
            if d.child("showVal")?.bool("val") == true { m.dataLabels = true }
            if d.child("showPercent")?.bool("val") == true { m.percentLabels = true }
            if let f = d.child("numFmt")?.a("formatCode"), f != "General" { m.numberFormat = f }
        }
        for c in charts {
            labels(c.child("dLbls"))
            let scatterLines = c.child("scatterStyle").map { ($0.a("val") ?? "").contains("line") || ($0.a("val") ?? "").contains("smooth") } ?? false
            for ser in c.children("ser") {
                var s = ChartSeries(name: "", values: [])
                s.name = ser.child("tx").map { strings($0).first ?? "" } ?? ""
                if s.name.isEmpty { s.name = L("Series %d", m.series.count + 1) }
                if let sp = ser.child("spPr") {
                    s.color = color(sp.child("solidFill")) ?? (sp.child("ln").flatMap { color($0.child("solidFill")) })
                    if m.kind == .line || m.kind == .scatter, let ln = sp.child("ln") {
                        if let w = ln.num("w") { s.lineWidth = w / emuPerPoint }
                        if ln.child("noFill") != nil { s.lineWidth = nil }
                        if let c = color(ln.child("solidFill")) { s.color = c }
                    } else if m.kind == .scatter, sp.child("ln") == nil, !scatterLines {
                        s.lineWidth = nil
                    }
                }
                if m.kind == .scatter, scatterLines, ser.child("spPr")?.child("ln")?.child("noFill") == nil, s.lineWidth == nil { s.lineWidth = 2.25 }
                if let sym = ser.child("marker")?.child("symbol")?.a("val") {
                    if sym == "none" { s.markers = false } else if sym != "auto" { s.symbol = sym }
                }
                if m.kind == .line, c.child("marker")?.bool("val") == false { s.markers = false }
                s.smooth = ser.child("smooth")?.bool("val") ?? false
                for dp in ser.children("dPt") {
                    if let i = dp.child("idx")?.int("val"), let c = color(dp.child("spPr")?.child("solidFill")) { s.pointColors[i] = c }
                }
                labels(ser.child("dLbls"))
                if m.kind == .scatter {
                    s.xValues = numbers(ser.child("xVal"))
                    s.values = numbers(ser.child("yVal"))
                    if s.xValues.isEmpty, let xs = ser.child("xVal") { s.xValues = strings(xs).map { Double($0) } }
                } else {
                    s.values = numbers(ser.child("val"))
                    if m.categories.isEmpty, let cat = ser.child("cat") {
                        m.categories = strings(cat)
                        if m.categories.isEmpty { m.categories = numbers(cat).map { $0.map { ChartRenderer.format($0) } ?? "" } }
                    }
                }
                m.series.append(s)
            }
        }
        for ax in plot.elements where ["catAx", "dateAx", "valAx", "serAx"].contains(ax.localName ?? "") {
            let t = ax.child("title").map(titleText)
            let isValue = ax.localName == "valAx" && !(m.kind == .scatter && (ax.child("axPos")?.a("val") == "b" || ax.child("axPos")?.a("val") == "t"))
            if isValue {
                m.valAxisTitle = t ?? m.valAxisTitle
                m.gridlines = ax.child("majorGridlines") != nil
                if m.numberFormat == nil, let f = ax.child("numFmt")?.a("formatCode"), f != "General", ax.child("numFmt")?.bool("sourceLinked") != true { m.numberFormat = f }
            } else {
                m.catAxisTitle = t ?? m.catAxisTitle
                if ax.child("scaling")?.child("orientation")?.a("val") == "maxMin" { m.reverseCategories = true }
            }
        }
        // A title element without text shows the series name (single-series charts).
        if m.title == "", m.series.count == 1 { m.title = m.series[0].name }
        if m.title == "" { m.title = nil }
        if autoDeleted && chart.child("title") == nil { m.title = nil }
        // No title and not deleted: a single series shows its name (as LibreOffice and PowerPoint do).
        if chart.child("title") == nil, !autoDeleted, m.series.count == 1, chart.child("autoTitleDeleted") != nil { m.title = m.series[0].name }
        if m.kind == .pie || m.kind == .doughnut, m.series.count > 1 { m.series = [m.series[0]] }
        return m
    }

    static func titleText(_ t: XMLElement) -> String {
        if let rich = t.child("tx")?.child("rich") {
            return rich.children("p").map { p in p.descendants("t").map { $0.stringValue ?? "" }.joined() }.joined(separator: "\n")
        }
        if let tx = t.child("tx") { return strings(tx).first ?? "" }
        return ""
    }

    /// String points of a strRef/strLit/multiLvlStrRef/v.
    static func strings(_ e: XMLElement) -> [String] {
        if let v = e.child("v")?.stringValue { return [v] }
        let cache = e.child("strRef")?.child("strCache") ?? e.child("strLit") ?? e.child("multiLvlStrRef")?.child("multiLvlStrCache")?.children("lvl").first
            ?? e.child("numRef")?.child("numCache") ?? e.child("numLit")
        guard let cache else { return [] }
        return points(cache).map { $0 ?? "" }
    }

    static func numbers(_ e: XMLElement?) -> [Double?] {
        guard let e, let cache = e.child("numRef")?.child("numCache") ?? e.child("numLit") ?? e.child("strRef")?.child("strCache") else { return [] }
        return points(cache).map { $0.flatMap { Double($0) } }
    }

    static func points(_ cache: XMLElement) -> [String?] {
        let n = cache.child("ptCount")?.int("val") ?? 0
        var out = [String?](repeating: nil, count: n)
        for pt in cache.children("pt") {
            guard let i = pt.int("idx"), i >= 0, i < 100000 else { continue }
            if i >= out.count { out += [String?](repeating: nil, count: i - out.count + 1) }
            out[i] = pt.child("v")?.stringValue
        }
        return out
    }

    // MARK: Writing

    static func colLetter(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    /// chartN.xml for a model. `color` writes a colour element (a:schemeClr / a:srgbClr).
    static func write(_ m: ChartModel, color: (PColor) -> String, workbookRel: String?) -> String {
        func esc(_ s: String) -> String { xmlEscape(s) }
        let rows = max(m.categories.count, m.series.map { $0.values.count }.max() ?? 0)
        func strRef(_ f: String, _ vals: [String]) -> String {
            "<c:strRef><c:f>\(f)</c:f><c:strCache><c:ptCount val=\"\(vals.count)\"/>" + vals.enumerated().map { "<c:pt idx=\"\($0.offset)\"><c:v>\(esc($0.element))</c:v></c:pt>" }.joined() + "</c:strCache></c:strRef>"
        }
        func numRef(_ f: String, _ vals: [Double?]) -> String {
            "<c:numRef><c:f>\(f)</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val=\"\(vals.count)\"/>"
                + vals.enumerated().compactMap { k, v in v.map { "<c:pt idx=\"\(k)\"><c:v>\($0)</c:v></c:pt>" } }.joined() + "</c:numCache></c:numRef>"
        }
        func rich(_ s: String, size: CGFloat, bold: Bool = false) -> String {
            let b = bold ? 1 : 0
            let paras = s.components(separatedBy: "\n").map { "<a:p><a:pPr><a:defRPr sz=\"\(Int(size * 100))\" b=\"\(b)\"/></a:pPr><a:r><a:rPr lang=\"en-US\" sz=\"\(Int(size * 100))\" b=\"\(b)\"/><a:t>\(esc($0))</a:t></a:r></a:p>" }.joined()
            return "<c:tx><c:rich><a:bodyPr/><a:lstStyle/>\(paras)</c:rich></c:tx><c:overlay val=\"0\"/>"
        }
        func dLbls() -> String {
            guard m.dataLabels || m.percentLabels else { return "" }
            let fmt = m.numberFormat.map { "<c:numFmt formatCode=\"\(esc($0))\" sourceLinked=\"0\"/>" } ?? ""
            return "<c:dLbls>\(fmt)<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr><c:showLegendKey val=\"0\"/><c:showVal val=\"\(m.dataLabels ? 1 : 0)\"/><c:showCatName val=\"0\"/><c:showSerName val=\"0\"/><c:showPercent val=\"\(m.percentLabels ? 1 : 0)\"/><c:showBubbleSize val=\"0\"/></c:dLbls>"
        }
        let catRange = "Sheet1!$A$2:$A$\(rows + 1)"
        var sers = ""
        for (i, s) in m.series.enumerated() {
            let col = colLetter(i + 1)
            let c = ChartRenderer.seriesColor(i, s)
            sers += "<c:ser><c:idx val=\"\(i)\"/><c:order val=\"\(i)\"/><c:tx>\(strRef("Sheet1!$\(col)$1", [s.name]))</c:tx>"
            switch m.kind {
            case .line, .scatter:
                let w = Int((s.lineWidth ?? 2.25) * emuPerPoint)
                let line = m.kind == .scatter && s.lineWidth == nil ? "<a:ln w=\"19050\"><a:noFill/></a:ln>" : "<a:ln w=\"\(w)\" cap=\"rnd\"><a:solidFill>\(color(c))</a:solidFill><a:round/></a:ln>"
                sers += "<c:spPr>\(line)</c:spPr>"
                sers += s.markers || m.kind == .scatter ? "<c:marker><c:symbol val=\"\(s.symbol ?? ChartRenderer.symbols[i % ChartRenderer.symbols.count].replacingOccurrences(of: "triangleDown", with: "triangle"))\"/><c:size val=\"5\"/><c:spPr><a:solidFill>\(color(c))</a:solidFill><a:ln><a:noFill/></a:ln></c:spPr></c:marker>" : "<c:marker><c:symbol val=\"none\"/></c:marker>"
            case .pie, .doughnut:
                sers += "<c:spPr><a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"lt1\"/></a:solidFill></a:ln></c:spPr>"
            default:
                sers += "<c:spPr><a:solidFill>\(color(c))</a:solidFill><a:ln><a:noFill/></a:ln></c:spPr>"
                if m.kind == .column || m.kind == .bar { sers += "<c:invertIfNegative val=\"0\"/>" }
            }
            if m.kind == .pie || m.kind == .doughnut || (m.varyColors && m.series.count == 1 && m.kind != .line && m.kind != .scatter) {
                for k in 0..<rows {
                    let pc = ChartRenderer.pointColor(s, k, m)
                    sers += "<c:dPt><c:idx val=\"\(k)\"/>\(m.kind == .column || m.kind == .bar ? "<c:invertIfNegative val=\"0\"/>" : "")<c:bubble3D val=\"0\"/><c:spPr><a:solidFill>\(color(pc))</a:solidFill>\(m.kind == .pie || m.kind == .doughnut ? "<a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"lt1\"/></a:solidFill></a:ln>" : "")</c:spPr></c:dPt>"
                }
            }
            if m.kind == .scatter {
                let xs = s.xValues.isEmpty ? (1...max(1, s.values.count)).map { Double?(Double($0)) } : s.xValues
                sers += "<c:xVal>\(numRef("Sheet1!$A$2:$A$\(rows + 1)", xs))</c:xVal><c:yVal>\(numRef("Sheet1!$\(col)$2:$\(col)$\(rows + 1)", s.values))</c:yVal><c:smooth val=\"\(s.smooth ? 1 : 0)\"/>"
            } else {
                let cats = (0..<rows).map { $0 < m.categories.count ? m.categories[$0] : "" }
                sers += "<c:cat>\(strRef(catRange, cats))</c:cat><c:val>\(numRef("Sheet1!$\(col)$2:$\(col)$\(rows + 1)", s.values))</c:val>"
                if m.kind == .line { sers += "<c:smooth val=\"\(s.smooth ? 1 : 0)\"/>" }
            }
            sers += "</c:ser>"
        }
        let grouping = m.grouping == .clustered ? (m.kind == .line || m.kind == .area ? "standard" : "clustered") : m.grouping.rawValue
        let vary = "<c:varyColors val=\"\(m.varyColors || m.kind == .pie || m.kind == .doughnut ? 1 : 0)\"/>"
        let axIds = "<c:axId val=\"500000001\"/><c:axId val=\"500000002\"/>"
        var plot = "<c:plotArea><c:layout/>"
        switch m.kind {
        case .column, .bar:
            plot += "<c:barChart><c:barDir val=\"\(m.kind == .bar ? "bar" : "col")\"/><c:grouping val=\"\(grouping)\"/>\(vary)\(sers)\(dLbls())<c:gapWidth val=\"\(m.gapWidth)\"/>"
            if m.grouping != .clustered { plot += "<c:overlap val=\"100\"/>" } else if m.overlap != 0 { plot += "<c:overlap val=\"\(m.overlap)\"/>" }
            plot += "\(axIds)</c:barChart>"
        case .line: plot += "<c:lineChart><c:grouping val=\"\(grouping)\"/>\(vary)\(sers)\(dLbls())<c:marker val=\"1\"/>\(axIds)</c:lineChart>"
        case .area: plot += "<c:areaChart><c:grouping val=\"\(grouping)\"/>\(vary)\(sers)\(dLbls())\(axIds)</c:areaChart>"
        case .scatter:
            let style = m.series.contains { $0.lineWidth != nil } ? "lineMarker" : "lineMarker"
            plot += "<c:scatterChart><c:scatterStyle val=\"\(style)\"/>\(vary)\(sers)\(dLbls())\(axIds)</c:scatterChart>"
        case .pie: plot += "<c:pieChart>\(vary)\(sers)\(dLbls())<c:firstSliceAng val=\"0\"/></c:pieChart>"
        case .doughnut: plot += "<c:doughnutChart>\(vary)\(sers)\(dLbls())<c:firstSliceAng val=\"0\"/><c:holeSize val=\"\(m.holeSize)\"/></c:doughnutChart>"
        }
        if m.kind.hasAxes {
            let catPos = m.kind == .bar ? "l" : "b", valPos = m.kind == .bar ? "b" : "l"
            let tick = "<c:majorTickMark val=\"none\"/><c:minorTickMark val=\"none\"/><c:tickLblPos val=\"nextTo\"/>"
            let axLine = "<c:spPr><a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"tx1\"><a:lumMod val=\"25000\"/><a:lumOff val=\"75000\"/></a:schemeClr></a:solidFill></a:ln></c:spPr>"
            let catTitle = m.catAxisTitle.map { "<c:title>\(rich($0, size: m.textSize * 1.1))</c:title>" } ?? ""
            let valTitle = m.valAxisTitle.map { "<c:title>\(rich($0, size: m.textSize * 1.1))</c:title>" } ?? ""
            let grid = m.gridlines ? "<c:majorGridlines><c:spPr><a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"tx1\"><a:lumMod val=\"15000\"/><a:lumOff val=\"85000\"/></a:schemeClr></a:solidFill></a:ln></c:spPr></c:majorGridlines>" : ""
            let fmt = m.grouping == .percentStacked ? "0%" : (m.numberFormat ?? "General")
            if m.kind == .scatter {
                plot += "<c:valAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"b\"/>\(catTitle)<c:numFmt formatCode=\"General\" sourceLinked=\"1\"/>\(tick)\(axLine)<c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/><c:crossBetween val=\"midCat\"/></c:valAx>"
            } else {
                plot += "<c:catAx><c:axId val=\"500000001\"/><c:scaling><c:orientation val=\"\(m.reverseCategories ? "maxMin" : "minMax")\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(catPos)\"/>\(catTitle)<c:numFmt formatCode=\"General\" sourceLinked=\"1\"/>\(tick)\(axLine)<c:crossAx val=\"500000002\"/><c:crosses val=\"autoZero\"/><c:auto val=\"1\"/><c:lblAlgn val=\"ctr\"/><c:lblOffset val=\"100\"/><c:noMultiLvlLbl val=\"0\"/></c:catAx>"
            }
            plot += "<c:valAx><c:axId val=\"500000002\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling><c:delete val=\"0\"/><c:axPos val=\"\(valPos)\"/>\(grid)\(valTitle)<c:numFmt formatCode=\"\(esc(fmt))\" sourceLinked=\"0\"/>\(tick)<c:spPr><a:ln><a:noFill/></a:ln></c:spPr><c:crossAx val=\"500000001\"/><c:crosses val=\"\(m.kind == .bar && m.reverseCategories ? "max" : "autoZero")\"/><c:crossBetween val=\"\(m.kind == .area || m.kind == .scatter ? "midCat" : "between")\"/></c:valAx>"
        }
        plot += "<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr></c:plotArea>"
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<c:chartSpace xmlns:c=\"\(nsC)\" xmlns:a=\"\(PPTXWriter.nsA)\" xmlns:r=\"\(PPTXWriter.nsR)\">"
        x += "<c:date1904 val=\"0\"/><c:lang val=\"en-US\"/><c:roundedCorners val=\"0\"/><c:chart>"
        if let t = m.title { x += "<c:title>\(rich(t, size: m.titleSize ?? m.textSize * 1.3, bold: m.titleBold))</c:title><c:autoTitleDeleted val=\"0\"/>" } else { x += "<c:autoTitleDeleted val=\"1\"/>" }
        x += plot
        if let l = m.legend { x += "<c:legend><c:legendPos val=\"\(l)\"/><c:overlay val=\"0\"/></c:legend>" }
        x += "<c:plotVisOnly val=\"1\"/><c:dispBlanksAs val=\"gap\"/></c:chart>"
        x += "<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>"
        x += "<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz=\"\(Int(m.textSize * 100))\"><a:solidFill>\(color(m.textColor ?? PColor(rgb: 0)))</a:solidFill></a:defRPr></a:pPr><a:endParaRPr lang=\"en-US\"/></a:p></c:txPr>"
        if let r = workbookRel { x += "<c:externalData r:id=\"\(r)\"><c:autoUpdate val=\"0\"/></c:externalData>" }
        return x + "</c:chartSpace>"
    }

    /// The chart's data as a minimal .xlsx (categories in column A, one column per series), so PowerPoint can edit it.
    static func workbook(_ m: ChartModel) -> Data {
        var zip = ZipArchive()
        func put(_ n: String, _ s: String) { zip[n] = Data(s.utf8) }
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        put("[Content_Types].xml", head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        put("_rels/.rels", head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        put("xl/workbook.xml", head + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        put("xl/_rels/workbook.xml.rels", head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
        let rows = max(m.categories.count, m.series.map { $0.values.count }.max() ?? 0)
        func str(_ ref: String, _ s: String) -> String { "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(xmlEscape(s))</t></is></c>" }
        var sheet = "<row r=\"1\">" + str("A1", "")
        for (i, s) in m.series.enumerated() { sheet += str("\(colLetter(i + 1))1", s.name) }
        sheet += "</row>"
        for r in 0..<rows {
            sheet += "<row r=\"\(r + 2)\">"
            if m.kind == .scatter {
                let x = m.series.first.flatMap { r < $0.xValues.count ? $0.xValues[r] : Double(r + 1) } ?? Double(r + 1)
                sheet += "<c r=\"A\(r + 2)\"><v>\(x)</v></c>"
            } else {
                sheet += str("A\(r + 2)", r < m.categories.count ? m.categories[r] : "")
            }
            for (i, s) in m.series.enumerated() {
                if r < s.values.count, let v = s.values[r] { sheet += "<c r=\"\(colLetter(i + 1))\(r + 2)\"><v>\(v)</v></c>" }
            }
            sheet += "</row>"
        }
        put("xl/worksheets/sheet1.xml", head + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(sheet)</sheetData></worksheet>")
        return zip.data()
    }
}
