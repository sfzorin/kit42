import AppKit
import Kit42

/// OpenDocument charts: the embedded chart sub-document ("Object N/content.xml", chart: namespace) of a draw:object.
enum ChartODF {
    // MARK: Reading

    static func read(_ content: XMLElement) -> ChartModel? {
        guard let chart = content.descendants("chart").first(where: { $0.a("class") != nil }) else { return nil }
        var styles: [String: [String: String]] = [:]
        for s in content.child("automatic-styles")?.children("style") ?? [] {
            guard let n = s.a("name") else { continue }
            var d: [String: String] = [:]
            for p in s.elements { for a in p.attributes ?? [] { if let k = a.localName { d[k] = a.stringValue ?? "" } } }
            styles[n] = d
        }
        func st(_ e: XMLElement?) -> [String: String] { e?.a("style-name").flatMap { styles[$0] } ?? [:] }
        func color(_ s: String?) -> PColor? {
            guard let s, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
            return PColor(rgb: v)
        }
        func text(_ e: XMLElement?) -> String? {
            guard let e else { return nil }
            let t = e.children("p").map { $0.stringValue ?? "" }.joined(separator: "\n")
            return t.isEmpty ? nil : t
        }
        var m = ChartModel()
        let cls = (chart.a("class") ?? "chart:bar").components(separatedBy: ":").last ?? "bar"
        let plot = chart.child("plot-area")
        let ps = st(plot)
        switch cls {
        case "bar": m.kind = ps["vertical"] == "true" ? .bar : .column
        case "line", "radar", "filled-radar", "stock": m.kind = .line
        case "area": m.kind = .area
        case "circle": m.kind = .pie
        case "ring": m.kind = .doughnut
        case "scatter", "bubble": m.kind = .scatter
        default: m.kind = .column
        }
        if ps["percentage"] == "true" { m.grouping = .percentStacked } else if ps["stacked"] == "true" { m.grouping = .stacked }
        m.title = text(chart.child("title"))
        if let ts = st(chart.child("title"))["font-size"].flatMap(odfPoints) { m.titleSize = ts }
        if let lg = chart.child("legend") {
            switch lg.a("legend-position") ?? "end" {
            case "start": m.legend = "l"
            case "top": m.legend = "t"
            case "bottom": m.legend = "b"
            default: m.legend = "r"
            }
            if let fs = st(lg)["font-size"].flatMap(odfPoints) { m.textSize = fs }
        } else { m.legend = nil }
        // The local table: cells by row and column (header row included).
        var grid: [[(String, Double?)]] = []
        for row in chart.descendants("table-row") {
            var cells: [(String, Double?)] = []
            for c in row.elements where c.localName == "table-cell" || c.localName == "covered-table-cell" {
                let v = c.a("value").flatMap(Double.init)
                let t = c.children("p").map { $0.stringValue ?? "" }.joined(separator: " ")
                for _ in 0..<max(1, min(500, c.int("number-columns-repeated") ?? 1)) { cells.append((t, v)) }
            }
            grid.append(cells)
        }
        /// "local-table.$B$2:.$B$5" → (column, first row, last row), 0-based.
        func range(_ s: String?) -> (Int, Int, Int)? {
            guard let s else { return nil }
            let parts = s.split(separator: ":").map { String($0.split(separator: ".").last ?? "") }
            func cell(_ c: String) -> (Int, Int)? {
                let letters = c.filter { $0.isLetter }, digits = c.filter { $0.isNumber }
                guard !letters.isEmpty, let r = Int(digits) else { return nil }
                var col = 0
                for ch in letters.uppercased().unicodeScalars { col = col * 26 + Int(ch.value) - 64 }
                return (col - 1, r - 1)
            }
            guard let a = parts.first.flatMap(cell) else { return nil }
            let b = parts.count > 1 ? cell(parts[1]) ?? a : a
            return (a.0, a.1, b.1)
        }
        func values(_ r: (Int, Int, Int)?) -> [Double?] {
            guard let r else { return [] }
            return (r.1...max(r.1, r.2)).map { row in grid.indices.contains(row) && grid[row].indices.contains(r.0) ? grid[row][r.0].1 : nil }
        }
        func strings(_ r: (Int, Int, Int)?) -> [String] {
            guard let r else { return [] }
            return (r.1...max(r.1, r.2)).map { row in grid.indices.contains(row) && grid[row].indices.contains(r.0) ? grid[row][r.0].0 : "" }
        }
        for ax in plot?.children("axis") ?? [] {
            let t = text(ax.child("title"))
            if ax.a("dimension") == "x" {
                m.catAxisTitle = t
                if let c = ax.child("categories") { m.categories = strings(range(c.a("cell-range-address"))) }
            } else if ax.a("dimension") == "y" {
                m.valAxisTitle = t
                m.gridlines = ax.child("grid") != nil
            }
            if let fs = st(ax)["font-size"].flatMap(odfPoints) { m.textSize = fs }
        }
        for ser in plot?.children("series") ?? [] {
            let ss = st(ser)
            var s = ChartSeries(name: "", values: values(range(ser.a("values-cell-range-address"))))
            if let l = range(ser.a("label-cell-address")) { s.name = strings(l).first ?? "" }
            if s.name.isEmpty { s.name = L("Series %d", m.series.count + 1) }
            s.color = m.kind == .line ? color(ss["stroke-color"]) ?? color(ss["fill-color"]) : color(ss["fill-color"])
            if m.kind == .line || m.kind == .scatter {
                s.markers = ss["symbol-type"] != "none"
                if let w = ss["stroke-width"].flatMap(odfPoints), w > 0 { s.lineWidth = w }
                if m.kind == .scatter, ss["stroke"] == "none" { s.lineWidth = nil } else if m.kind == .scatter, s.lineWidth == nil, ss["stroke"] != nil { s.lineWidth = 2.25 }
            }
            switch ss["data-label-number"] {
            case "value": m.dataLabels = true
            case "percentage": m.percentLabels = true
            default: break
            }
            if let d = ser.child("domain") { s.xValues = values(range(d.a("cell-range-address"))) }
            var k = 0
            for dp in ser.children("data-point") {
                let n = max(1, dp.int("repeated") ?? 1)
                if let c = color(st(dp)["fill-color"]) { for j in k..<(k + n) { s.pointColors[j] = c } }
                k += n
            }
            m.series.append(s)
        }
        if m.categories.isEmpty, m.kind != .scatter, let n = m.series.map({ $0.values.count }).max() {
            m.categories = (0..<n).map { grid.indices.contains($0 + 1) ? grid[$0 + 1].first?.0 ?? "\($0 + 1)" : "\($0 + 1)" }
        }
        m.varyColors = m.kind == .pie || m.kind == .doughnut
        if m.kind == .pie || m.kind == .doughnut, m.series.count > 1 { m.series = [m.series[0]] }
        return m
    }

    // MARK: Writing

    static let ns = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
    xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" \
    xmlns:chart="urn:oasis:names:tc:opendocument:xmlns:chart:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" \
    xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" office:version="1.3"
    """

    /// content.xml of the chart sub-document. `hex` flattens a colour with the deck's theme.
    static func content(_ m: ChartModel, size: CGSize, font: String, hex: (PColor) -> String) -> String {
        var styles = ""
        func style(_ name: String, _ body: String) -> String {
            styles += "<style:style style:name=\"\(name)\" style:family=\"chart\">\(body)</style:style>"
            return name
        }
        let ink = hex(m.textColor ?? PColor(rgb: 0))
        func textProps(_ size: CGFloat) -> String { "<style:text-properties fo:font-size=\"\(String(format: "%.1f", size))pt\" fo:color=\"\(ink)\" fo:font-family=\"'\(xmlEscape(font))'\" style:font-size-asian=\"\(String(format: "%.1f", size))pt\" style:font-size-complex=\"\(String(format: "%.1f", size))pt\"/>" }
        let rows = max(m.categories.count, m.series.map { $0.values.count }.max() ?? 0)
        let cls: String
        switch m.kind {
        case .column, .bar: cls = "chart:bar"
        case .line: cls = "chart:line"
        case .area: cls = "chart:area"
        case .pie: cls = "chart:circle"
        case .doughnut: cls = "chart:ring"
        case .scatter: cls = "chart:scatter"
        }
        let area = style("ch1", "<style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/>" + textProps(m.textSize))
        var x = "<chart:chart svg:width=\"\(odfLength(size.width))\" svg:height=\"\(odfLength(size.height))\" chart:class=\"\(cls)\" chart:style-name=\"\(area)\">"
        if let t = m.title {
            let ts = style("chT", textProps(m.titleSize ?? m.textSize * 1.3).replacingOccurrences(of: "/>", with: " fo:font-weight=\"\(m.titleBold ? "bold" : "normal")\"/>"))
            x += "<chart:title chart:style-name=\"\(ts)\">" + t.components(separatedBy: "\n").map { "<text:p>\(xmlEscape($0))</text:p>" }.joined() + "</chart:title>"
        }
        if let l = m.legend {
            let pos = ["l": "start", "t": "top", "b": "bottom"][l] ?? "end"
            let ls = style("chL", "<style:chart-properties chart:auto-position=\"true\"/><style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/>" + textProps(m.textSize))
            x += "<chart:legend chart:legend-position=\"\(pos)\" style:legend-expansion=\"high\" chart:style-name=\"\(ls)\"/>"
        }
        var plotProps = "chart:three-dimensional=\"false\" chart:right-angled-axes=\"true\""
        if m.kind == .bar { plotProps += " chart:vertical=\"true\"" }
        if m.grouping == .stacked { plotProps += " chart:stacked=\"true\"" }
        if m.grouping == .percentStacked { plotProps += " chart:percentage=\"true\"" }
        if m.kind == .column || m.kind == .bar { plotProps += " chart:gap-width=\"\(m.gapWidth)\" chart:overlap=\"\(m.grouping == .clustered ? m.overlap : 100)\"" }
        let plotStyle = style("chP", "<style:chart-properties \(plotProps)/>")
        let last = ChartXML.colLetter(m.series.count)
        x += "<chart:plot-area chart:style-name=\"\(plotStyle)\" table:cell-range-address=\"local-table.$A$1:.$\(last)$\(rows + 1)\" chart:data-source-has-labels=\"both\">"
        if m.kind.hasAxes {
            let axStyle = style("chAx", "<style:chart-properties chart:display-label=\"true\" chart:reverse-direction=\"\(m.kind == .bar && m.reverseCategories)\"\(m.kind == .line ? " loext:major-origin=\"0.5\"" : "")/><style:graphic-properties svg:stroke-color=\"#bfbfbf\"/>" + textProps(m.textSize))
            let vaStyle = style("chAy", "<style:chart-properties chart:display-label=\"true\"\(m.grouping == .percentStacked ? "" : "")/><style:graphic-properties draw:stroke=\"none\"/>" + textProps(m.textSize))
            let gridStyle = style("chG", "<style:graphic-properties svg:stroke-color=\"#d9d9d9\"/>")
            let tStyle = style("chAT", textProps(m.textSize * 1.1))
            x += "<chart:axis chart:dimension=\"x\" chart:name=\"primary-x\" chart:style-name=\"\(axStyle)\">"
            if let t = m.catAxisTitle { x += "<chart:title chart:style-name=\"\(tStyle)\"><text:p>\(xmlEscape(t))</text:p></chart:title>" }
            if m.kind != .scatter { x += "<chart:categories table:cell-range-address=\"local-table.$A$2:.$A$\(rows + 1)\"/>" }
            x += "</chart:axis><chart:axis chart:dimension=\"y\" chart:name=\"primary-y\" chart:style-name=\"\(vaStyle)\">"
            if let t = m.valAxisTitle { x += "<chart:title chart:style-name=\"\(tStyle)\"><text:p>\(xmlEscape(t))</text:p></chart:title>" }
            if m.gridlines { x += "<chart:grid chart:style-name=\"\(gridStyle)\" chart:class=\"major\"/>" }
            x += "</chart:axis>"
        } else {
            // Pies run clockwise from the top, as in PowerPoint.
            let hidden = style("chAxH", "<style:chart-properties chart:visible=\"false\" chart:reverse-direction=\"false\"/>")
            let rev = style("chAyH", "<style:chart-properties chart:visible=\"false\" chart:reverse-direction=\"true\"/>")
            x += "<chart:axis chart:dimension=\"x\" chart:name=\"primary-x\" chart:style-name=\"\(hidden)\"><chart:categories table:cell-range-address=\"local-table.$A$2:.$A$\(rows + 1)\"/></chart:axis>"
            x += "<chart:axis chart:dimension=\"y\" chart:name=\"primary-y\" chart:style-name=\"\(rev)\"/>"
        }
        let labels = m.percentLabels ? "percentage" : m.dataLabels ? "value" : "none"
        for (i, s) in m.series.enumerated() {
            let col = ChartXML.colLetter(i + 1)
            let c = hex(ChartRenderer.seriesColor(i, s))
            var props = "<style:chart-properties chart:data-label-number=\"\(labels)\""
            switch m.kind {
            case .line: props += " chart:symbol-type=\"\(s.markers ? "automatic" : "none")\"/><style:graphic-properties draw:stroke=\"solid\" svg:stroke-width=\"\(odfLength(s.lineWidth ?? 2.25))\" svg:stroke-color=\"\(c)\" draw:fill-color=\"\(c)\"/>"
            case .scatter:
                props += " chart:symbol-type=\"automatic\"/><style:graphic-properties draw:stroke=\"\(s.lineWidth == nil ? "none" : "solid")\" svg:stroke-width=\"\(odfLength(s.lineWidth ?? 2.25))\" svg:stroke-color=\"\(c)\" draw:fill-color=\"\(c)\"/>"
            case .pie, .doughnut: props += "/><style:graphic-properties draw:stroke=\"solid\" svg:stroke-color=\"#ffffff\" svg:stroke-width=\"0.035cm\"/>"
            default: props += "/><style:graphic-properties draw:stroke=\"none\" draw:fill=\"solid\" draw:fill-color=\"\(c)\"/>"
            }
            let ss = style("chS\(i + 1)", props + textProps(m.textSize))
            x += "<chart:series chart:style-name=\"\(ss)\" chart:values-cell-range-address=\"local-table.$\(col)$2:.$\(col)$\(rows + 1)\" chart:label-cell-address=\"local-table.$\(col)$1\" chart:class=\"\(cls)\">"
            if m.kind == .scatter { x += "<chart:domain table:cell-range-address=\"local-table.$A$2:.$A$\(rows + 1)\"/>" }
            if m.kind == .pie || m.kind == .doughnut || (m.varyColors && m.series.count == 1) {
                for k in 0..<rows {
                    let ps = style("chD\(i + 1)_\(k + 1)", "<style:graphic-properties draw:fill=\"solid\" draw:fill-color=\"\(hex(ChartRenderer.pointColor(s, k, m)))\"/>")
                    x += "<chart:data-point chart:style-name=\"\(ps)\"/>"
                }
            } else if rows > 0 {
                x += "<chart:data-point chart:repeated=\"\(rows)\"/>"
            }
            x += "</chart:series>"
        }
        let wall = style("chW", "<style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\"/>")
        x += "<chart:wall chart:style-name=\"\(wall)\"/><chart:floor/></chart:plot-area>"
        // Local data table.
        func str(_ s: String) -> String { "<table:table-cell office:value-type=\"string\"><text:p>\(xmlEscape(s))</text:p></table:table-cell>" }
        func num(_ v: Double?) -> String {
            guard let v else { return "<table:table-cell/>" }
            return "<table:table-cell office:value-type=\"float\" office:value=\"\(v)\"><text:p>\(v)</text:p></table:table-cell>"
        }
        x += "<table:table table:name=\"local-table\"><table:table-header-columns><table:table-column/></table:table-header-columns>"
        x += "<table:table-columns><table:table-column table:number-columns-repeated=\"\(max(1, m.series.count))\"/></table:table-columns>"
        x += "<table:table-header-rows><table:table-row><table:table-cell><text:p/></table:table-cell>" + m.series.map { str($0.name) }.joined() + "</table:table-row></table:table-header-rows><table:table-rows>"
        for r in 0..<rows {
            x += "<table:table-row>"
            if m.kind == .scatter {
                let xv = m.series.first.flatMap { r < $0.xValues.count ? $0.xValues[r] : Double(r + 1) } ?? Double(r + 1)
                x += num(xv)
            } else {
                x += str(r < m.categories.count ? m.categories[r] : "")
            }
            for s in m.series { x += num(r < s.values.count ? s.values[r] : nil) }
            x += "</table:table-row>"
        }
        x += "</table:table-rows></table:table></chart:chart>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content \(ns)><office:automatic-styles>\(styles)</office:automatic-styles><office:body><office:chart>\(x)</office:chart></office:body></office:document-content>"
    }

    static func styles() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles \(ns)><office:styles/></office:document-styles>"
    }
}
