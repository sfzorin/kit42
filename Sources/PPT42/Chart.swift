import AppKit
import Kit42

// Charts: model, package parts kept for round trips, and the native renderer.

// MARK: - Package parts (kept verbatim)

/// A part of the source package with its own relationships (chart XML and its workbook, diagram parts, media).
final class PackagePart: Equatable {
    let name: String
    let data: Data
    let contentType: String
    let rels: [PackageRel]

    init(name: String, data: Data, contentType: String, rels: [PackageRel]) {
        self.name = name
        self.data = data
        self.contentType = contentType
        self.rels = rels
    }

    static func == (a: PackagePart, b: PackagePart) -> Bool { a === b || (a.data == b.data && a.rels == b.rels) }

    /// File name without folders ("chart3.xml").
    var fileName: String { (name as NSString).lastPathComponent }
}

struct PackageRel: Equatable {
    var id: String
    var type: String
    /// External target (a URL) or nil when `part` is set.
    var external: String?
    var part: PackagePart?
}

// MARK: - Model

enum ChartKind: String, CaseIterable {
    case column, bar, line, area, pie, doughnut, scatter

    var name: String {
        switch self {
        case .column: return L("Column")
        case .bar: return L("Bar")
        case .line: return L("Line")
        case .area: return L("Area")
        case .pie: return L("Pie")
        case .doughnut: return L("Doughnut")
        case .scatter: return L("Scatter")
        }
    }

    var symbol: String {
        switch self {
        case .column: return "chart.bar"
        case .bar: return "chart.bar.xaxis"
        case .line: return "chart.xyaxis.line"
        case .area: return "chart.line.uptrend.xyaxis"
        case .pie: return "chart.pie"
        case .doughnut: return "circle.circle"
        case .scatter: return "chart.dots.scatter"
        }
    }

    var hasAxes: Bool { self != .pie && self != .doughnut }
}

enum ChartGrouping: String, CaseIterable {
    case clustered, stacked, percentStacked
}

struct ChartSeries: Equatable {
    var name: String
    var values: [Double?]
    /// Scatter: x values (categories are ignored).
    var xValues: [Double?] = []
    var color: PColor?
    /// Pie and doughnut slices (vary colours by point).
    var pointColors: [Int: PColor] = [:]
    var lineWidth: CGFloat?
    var markers = true
    /// Marker symbol (circle, square, diamond, triangle…); nil = automatic by series.
    var symbol: String?
    var smooth = false
}

struct ChartModel: Equatable {
    var kind: ChartKind = .column
    var grouping: ChartGrouping = .clustered
    var categories: [String] = []
    var series: [ChartSeries] = []
    /// nil = no title.
    var title: String?
    /// Legend position r, b, t, l; nil = no legend.
    var legend: String? = "r"
    var dataLabels = false
    var percentLabels = false
    var catAxisTitle: String?
    var valAxisTitle: String?
    var gridlines = true
    var holeSize = 50
    var gapWidth = 150
    var overlap = 0
    var varyColors = false
    /// Base text size (c:txPr), points.
    var textSize: CGFloat = 10
    var titleSize: CGFloat?
    /// Number format of value labels ("0%", "#,##0.00"…), kept for writing.
    var numberFormat: String?
    /// Bar charts: first category at the top (c:orientation maxMin).
    var reverseCategories = false
    var titleBold = true
    /// Text colour (c:txPr); nil = black as LibreOffice shows charts without text properties.
    var textColor: PColor?
    /// The part and model as read: written back untouched while the model is unchanged.
    var original: ChartOriginal?

    static func == (a: ChartModel, b: ChartModel) -> Bool {
        a.kind == b.kind && a.grouping == b.grouping && a.categories == b.categories && a.series == b.series && a.title == b.title
            && a.legend == b.legend && a.dataLabels == b.dataLabels && a.percentLabels == b.percentLabels && a.catAxisTitle == b.catAxisTitle
            && a.valAxisTitle == b.valAxisTitle && a.gridlines == b.gridlines && a.holeSize == b.holeSize && a.gapWidth == b.gapWidth
            && a.overlap == b.overlap && a.varyColors == b.varyColors && a.textSize == b.textSize && a.titleSize == b.titleSize
            && a.numberFormat == b.numberFormat && a.reverseCategories == b.reverseCategories && a.titleBold == b.titleBold && a.textColor == b.textColor
    }

    /// The source part when nothing was edited.
    var untouchedPart: PackagePart? {
        guard let o = original, o.model == self else { return nil }
        return o.part
    }

    /// ODF source sub-document (files of "Object N/"), when nothing was edited.
    var untouchedODF: [String: Data]? {
        guard let o = original, o.model == self else { return nil }
        return o.odf
    }

    static func sample(_ kind: ChartKind = .column) -> ChartModel {
        var m = ChartModel()
        m.kind = kind
        m.categories = [L("Category 1"), L("Category 2"), L("Category 3"), L("Category 4")]
        m.series = [
            ChartSeries(name: L("Series 1"), values: [4.3, 2.5, 3.5, 4.5]),
            ChartSeries(name: L("Series 2"), values: [2.4, 4.4, 1.8, 2.8]),
            ChartSeries(name: L("Series 3"), values: [2, 2, 3, 5]),
        ]
        if kind == .scatter { for i in m.series.indices { m.series[i].xValues = [1, 2, 3, 4] } }
        if kind == .pie || kind == .doughnut { m.series = [m.series[0]]; m.varyColors = true }
        return m
    }
}

final class ChartOriginal {
    let model: ChartModel
    let part: PackagePart?
    let odf: [String: Data]?

    init(model: ChartModel, part: PackagePart?, odf: [String: Data]? = nil) {
        var m = model
        m.original = nil
        self.model = m
        self.part = part
        self.odf = odf
    }
}

// MARK: - Rendering

enum ChartRenderer {
    static func seriesColor(_ i: Int, _ s: ChartSeries?) -> PColor {
        if let c = s?.color { return c }
        let accent = "accent\(i % 6 + 1)"
        let round = i / 6
        if round == 0 { return PColor(scheme: accent) }
        return PColor(scheme: accent, mods: [.init(name: "lumMod", val: round % 2 == 1 ? 60000 : 80000), .init(name: "lumOff", val: round % 2 == 1 ? 0 : 20000)])
    }

    static func pointColor(_ s: ChartSeries, _ k: Int, _ m: ChartModel) -> PColor {
        if let c = s.pointColors[k] { return c }
        return m.varyColors || m.kind == .pie || m.kind == .doughnut ? seriesColor(k, nil) : seriesColor(0, s)
    }

    static func format(_ v: Double, percent: Bool = false, format: String? = nil) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = abs(v) >= 10000
        let fmt = format ?? ""
        if percent || fmt.hasSuffix("%") {
            f.numberStyle = .percent
            f.maximumFractionDigits = fmt.contains(".0") ? 1 : 0
            return f.string(from: NSNumber(value: v)) ?? "\(v)"
        }
        if let dot = fmt.firstIndex(of: ".") {
            let digits = fmt[fmt.index(after: dot)...].prefix { $0 == "0" }.count
            f.minimumFractionDigits = digits; f.maximumFractionDigits = digits
        } else {
            f.maximumFractionDigits = abs(v) < 1 && v != 0 ? 3 : 2
        }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Round axis bounds and step.
    static func niceScale(_ lo: Double, _ hi: Double, ticks: Int = 5, headroom: Bool = true) -> (Double, Double, Double) {
        var lo = lo, hi = hi
        if lo == hi { hi = lo + 1; if lo > 0 { lo = 0 } }
        let raw = (hi - lo) / Double(max(1, ticks))
        let mag = pow(10, floor(log10(raw)))
        let n = raw / mag
        let step = (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * mag
        let a = floor(lo / step + 1e-9) * step
        var b = ceil(hi / step - 1e-9) * step
        // Like LibreOffice: a value close under the top gets one more interval.
        if headroom, hi > 0, b - hi < step * 0.3 { b += step }
        return (a, b == a ? a + step : b, step)
    }

    /// Marker symbols in the automatic order.
    static let symbols = ["square", "diamond", "triangleDown", "triangle", "x", "circle", "star", "plus"]

    static func marker(_ name: String, at p: CGPoint, r: CGFloat, ctx: CGContext) {
        let path = CGMutablePath()
        switch name {
        case "circle", "dot": path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        case "diamond": path.addLines(between: [CGPoint(x: p.x, y: p.y - r * 1.2), CGPoint(x: p.x + r * 1.2, y: p.y), CGPoint(x: p.x, y: p.y + r * 1.2), CGPoint(x: p.x - r * 1.2, y: p.y)]); path.closeSubpath()
        case "triangle": path.addLines(between: [CGPoint(x: p.x, y: p.y - r * 1.2), CGPoint(x: p.x + r * 1.1, y: p.y + r), CGPoint(x: p.x - r * 1.1, y: p.y + r)]); path.closeSubpath()
        case "triangleDown": path.addLines(between: [CGPoint(x: p.x, y: p.y + r * 1.2), CGPoint(x: p.x + r * 1.1, y: p.y - r), CGPoint(x: p.x - r * 1.1, y: p.y - r)]); path.closeSubpath()
        case "x", "star", "plus":
            ctx.saveGState()
            ctx.setLineWidth(max(1, r / 2.5))
            if name != "plus" { ctx.move(to: CGPoint(x: p.x - r, y: p.y - r)); ctx.addLine(to: CGPoint(x: p.x + r, y: p.y + r)); ctx.move(to: CGPoint(x: p.x + r, y: p.y - r)); ctx.addLine(to: CGPoint(x: p.x - r, y: p.y + r)) }
            if name != "x" { ctx.move(to: CGPoint(x: p.x, y: p.y - r)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + r)); ctx.move(to: CGPoint(x: p.x - r, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + r, y: p.y)) }
            ctx.strokePath()
            ctx.restoreGState()
            return
        default: path.addRect(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.addPath(path)
        ctx.fillPath()
    }

    static func font(_ deck: Deck, _ size: CGFloat, bold: Bool = false) -> NSFont {
        FontResolver.font(deck.theme.minorFont, size: size, bold: bold, italic: false)
    }

    static func text(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    /// Draws the chart into `box` (object coordinates, flipped context with NSGraphicsContext set).
    static func draw(_ m: ChartModel, deck: Deck, in box: CGRect, ctx: CGContext) {
        let theme = deck.theme
        let ink = (m.textColor ?? PColor(rgb: 0)).resolved(theme)
        let gridColor = PColor(scheme: "tx1", mods: [.init(name: "lumMod", val: 15000), .init(name: "lumOff", val: 85000)]).resolved(theme)
        let base = max(4, m.textSize)
        let small = font(deck, base)
        var area = box.insetBy(dx: max(4, box.width * 0.02), dy: max(4, box.height * 0.03))

        // Title
        if let t = m.title, !t.isEmpty {
            let s = text(t, font(deck, m.titleSize ?? base * 1.3, bold: m.titleBold), ink)
            let sz = s.boundingRect(with: CGSize(width: area.width, height: 1000), options: [.usesLineFragmentOrigin]).size
            s.draw(with: CGRect(x: area.midX - min(area.width, sz.width) / 2, y: area.minY, width: min(area.width, sz.width) + 1, height: sz.height + 1),
                   options: [.usesLineFragmentOrigin])
            area.origin.y += sz.height + base * 0.6
            area.size.height -= sz.height + base * 0.6
        }

        // Legend entries
        let pieLike = m.kind == .pie || m.kind == .doughnut
        let entries: [(String, PColor)] = pieLike
            ? m.categories.enumerated().map { e in (e.element, m.series.first.map { s in pointColor(s, e.offset, m) } ?? seriesColor(e.offset, nil)) }
            : m.series.enumerated().map { ($0.element.name, seriesColor($0.offset, $0.element)) }
        if let pos = m.legend, !entries.isEmpty {
            let sw = base * 0.7, gap = base * 0.4
            let labels = entries.map { text($0.0, small, ink) }
            let widths = labels.map { ceil($0.size().width) }
            let lineH = ceil(small.ascender - small.descender + small.leading) + 2
            func swatch(_ c: PColor, at p: CGPoint) {
                ctx.setFillColor(c.resolved(theme).cgColor)
                if m.kind == .line || m.kind == .scatter {
                    ctx.fill(CGRect(x: p.x, y: p.y + lineH / 2 - 1, width: sw * 1.6, height: 2))
                    if let k = entries.firstIndex(where: { $0.1 == c }), m.series.indices.contains(k), m.series[k].markers {
                        marker(m.series[k].symbol ?? symbols[k % symbols.count], at: CGPoint(x: p.x + sw * 0.8, y: p.y + lineH / 2), r: sw * 0.35, ctx: ctx)
                    }
                } else {
                    ctx.fill(CGRect(x: p.x, y: p.y + (lineH - sw) / 2, width: sw, height: sw))
                }
            }
            let swW = (m.kind == .line || m.kind == .scatter) ? sw * 1.6 : sw
            if pos == "r" || pos == "l" {
                let w = (widths.max() ?? 0) + swW + gap * 3
                let h = CGFloat(entries.count) * lineH
                let x = pos == "r" ? area.maxX - w + gap : area.minX
                var y = area.midY - h / 2
                for (i, e) in entries.enumerated() {
                    swatch(e.1, at: CGPoint(x: x, y: y))
                    labels[i].draw(at: CGPoint(x: x + swW + gap, y: y + 1))
                    y += lineH
                }
                area.size.width -= w + gap
                if pos == "l" { area.origin.x += w + gap }
            } else {
                let total = widths.reduce(0, +) + CGFloat(entries.count) * (swW + gap * 3)
                var x = area.midX - min(total, area.width) / 2
                let y = pos == "t" ? area.minY : area.maxY - lineH
                for (i, e) in entries.enumerated() {
                    swatch(e.1, at: CGPoint(x: x, y: y))
                    labels[i].draw(at: CGPoint(x: x + swW + gap, y: y + 1))
                    x += widths[i] + swW + gap * 3
                }
                area.size.height -= lineH + gap
                if pos == "t" { area.origin.y += lineH + gap }
            }
        }
        guard area.width > 10, area.height > 10 else { return }
        if pieLike { drawPie(m, deck: deck, in: area, ctx: ctx, font: small, ink: ink); return }
        drawAxes(m, deck: deck, in: area, ctx: ctx, font: small, ink: ink, grid: gridColor)
    }

    static func drawPie(_ m: ChartModel, deck: Deck, in area: CGRect, ctx: CGContext, font: NSFont, ink: NSColor) {
        guard let s = m.series.first else { return }
        let vals = s.values.map { max(0, $0 ?? 0) }
        let total = vals.reduce(0, +)
        guard total > 0 else { return }
        let r = min(area.width, area.height) / 2 * 0.92
        let c = CGPoint(x: area.midX, y: area.midY)
        let hole = m.kind == .doughnut ? r * CGFloat(min(90, max(10, m.holeSize))) / 100 : 0
        var a = -CGFloat.pi / 2
        for (k, v) in vals.enumerated() where v > 0 {
            let sweep = CGFloat(v / total) * 2 * .pi
            let p = CGMutablePath()
            if hole > 0 {
                p.addArc(center: c, radius: r, startAngle: a, endAngle: a + sweep, clockwise: false)
                p.addArc(center: c, radius: hole, startAngle: a + sweep, endAngle: a, clockwise: true)
            } else {
                p.move(to: c)
                p.addArc(center: c, radius: r, startAngle: a, endAngle: a + sweep, clockwise: false)
            }
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(pointColor(s, k, m).resolved(deck.theme).cgColor)
            ctx.fillPath()
            ctx.addPath(p)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(0.5, r / 120))
            ctx.strokePath()
            if m.dataLabels || m.percentLabels {
                let mid = a + sweep / 2
                let rr = hole > 0 ? (r + hole) / 2 : r * 0.62
                let label = m.percentLabels ? format(v / total, percent: true) : format(v, format: m.numberFormat)
                let t = text(label, font, ink)
                let sz = t.size()
                t.draw(at: CGPoint(x: c.x + cos(mid) * rr - sz.width / 2, y: c.y + sin(mid) * rr - sz.height / 2))
            }
            a += sweep
        }
    }

    static func drawAxes(_ m: ChartModel, deck: Deck, in area0: CGRect, ctx: CGContext, font: NSFont, ink: NSColor, grid: NSColor) {
        let theme = deck.theme
        let horizontal = m.kind == .bar
        let n = max(m.categories.count, m.series.map { $0.values.count }.max() ?? 0)
        guard n > 0 else { return }
        let stacked = m.grouping != .clustered && m.kind != .scatter
        let percent = m.grouping == .percentStacked && m.kind != .scatter
        // Value range
        var lo = 0.0, hi = 0.0
        var xlo = Double.infinity, xhi = -Double.infinity
        if percent {
            hi = 1
            if m.series.contains(where: { $0.values.contains { ($0 ?? 0) < 0 } }) { lo = -1 }
        } else if stacked {
            for k in 0..<n {
                var pos = 0.0, neg = 0.0
                for s in m.series { let v = k < s.values.count ? (s.values[k] ?? 0) : 0; if v >= 0 { pos += v } else { neg += v } }
                hi = max(hi, pos); lo = min(lo, neg)
            }
        } else {
            let all = m.series.flatMap { $0.values.compactMap { $0 } }
            hi = max(0, all.max() ?? 1); lo = min(0, all.min() ?? 0)
            if m.kind == .scatter || m.kind == .line, let mn = all.min(), mn > 0, (all.max() ?? 0) > 0 { lo = 0 }
        }
        if m.kind == .scatter {
            let xs = m.series.flatMap { s in s.xValues.isEmpty ? (1...max(1, s.values.count)).map { Double($0) } : s.xValues.compactMap { $0 } }
            xlo = min(0, xs.min() ?? 0); xhi = xs.max() ?? 1
        }
        let ticks = horizontal ? Int(area0.width / max(40, font.pointSize * 6)) : Int(area0.height / max(16, font.pointSize * 3.2))
        let (vmin, vmax, step) = percent ? (lo, hi, 0.1) : niceScale(lo, hi, ticks: max(2, min(12, ticks)))
        let valLabels = stride(from: vmin, through: vmax + step / 2, by: step).map { format($0, percent: percent, format: percent ? nil : m.numberFormat) }
        let lineH = ceil(font.ascender - font.descender) + 2
        let valWidth = valLabels.map { ceil(text($0, font, ink).size().width) }.max() ?? 20
        let catLabels = m.kind == .scatter ? [] : (0..<n).map { $0 < m.categories.count ? m.categories[$0] : "\($0 + 1)" }
        let catWidth = catLabels.map { ceil(text($0, font, ink).size().width) }.max() ?? 20
        var plot = area0
        let titleFont = FontResolver.font(theme.minorFont, size: font.pointSize * 1.1, bold: false, italic: false)
        // Axis titles: value axis title on the left (rotated) for columns, below for bars.
        if let t = m.valAxisTitle, !t.isEmpty {
            let s = text(t, titleFont, ink)
            if horizontal { s.draw(at: CGPoint(x: plot.midX - s.size().width / 2, y: plot.maxY - lineH)); plot.size.height -= lineH + 2 }
            else {
                ctx.saveGState()
                ctx.translateBy(x: plot.minX + lineH / 2, y: plot.midY)
                ctx.rotate(by: -.pi / 2)
                s.draw(at: CGPoint(x: -s.size().width / 2, y: -lineH / 2))
                ctx.restoreGState()
                plot.origin.x += lineH + 2; plot.size.width -= lineH + 2
            }
        }
        if let t = m.catAxisTitle, !t.isEmpty {
            let s = text(t, titleFont, ink)
            if horizontal {
                ctx.saveGState()
                ctx.translateBy(x: plot.minX + lineH / 2, y: plot.midY)
                ctx.rotate(by: -.pi / 2)
                s.draw(at: CGPoint(x: -s.size().width / 2, y: -lineH / 2))
                ctx.restoreGState()
                plot.origin.x += lineH + 2; plot.size.width -= lineH + 2
            } else { s.draw(at: CGPoint(x: plot.midX - s.size().width / 2, y: plot.maxY - lineH)); plot.size.height -= lineH + 2 }
        }
        if horizontal {
            plot.origin.x += min(catWidth, plot.width * 0.35) + 6; plot.size.width -= min(catWidth, plot.width * 0.35) + 6
            plot.size.height -= lineH + 4
        } else {
            plot.origin.x += valWidth + 6; plot.size.width -= valWidth + 6
            plot.size.height -= lineH + 4
            if m.kind == .scatter { plot.size.width -= 4 }
        }
        plot.origin.y += lineH / 2; plot.size.height -= lineH / 2
        guard plot.width > 4, plot.height > 4 else { return }
        // Value → coordinate along the value axis.
        func vpos(_ v: Double) -> CGFloat {
            let t = CGFloat((v - vmin) / (vmax - vmin))
            return horizontal ? plot.minX + t * plot.width : plot.maxY - t * plot.height
        }
        let (xmin, xmax, xstep) = m.kind == .scatter ? niceScale(xlo, xhi, ticks: max(2, min(12, Int(plot.width / max(40, font.pointSize * 6))))) : (0, 1, 1)
        func xpos(_ v: Double) -> CGFloat { plot.minX + CGFloat((v - xmin) / (xmax - xmin)) * plot.width }

        // Gridlines and value labels
        ctx.setLineWidth(0.75)
        for (k, v) in stride(from: vmin, through: vmax + step / 2, by: step).enumerated() {
            let p = vpos(v)
            if m.gridlines {
                ctx.setStrokeColor(grid.cgColor)
                if horizontal { ctx.move(to: CGPoint(x: p, y: plot.minY)); ctx.addLine(to: CGPoint(x: p, y: plot.maxY)) }
                else { ctx.move(to: CGPoint(x: plot.minX, y: p)); ctx.addLine(to: CGPoint(x: plot.maxX, y: p)) }
                ctx.strokePath()
            }
            let s = text(valLabels[min(k, valLabels.count - 1)], font, ink)
            let sz = s.size()
            if horizontal { s.draw(at: CGPoint(x: p - sz.width / 2, y: plot.maxY + 3)) }
            else { s.draw(at: CGPoint(x: plot.minX - sz.width - 5, y: p - sz.height / 2)) }
        }
        // Category axis line and labels
        ctx.setStrokeColor(grid.blended(withFraction: 0.3, of: ink)?.cgColor ?? grid.cgColor)
        let zero = vpos(max(vmin, min(vmax, 0)))
        if m.kind == .scatter {
            for v in stride(from: xmin, through: xmax + xstep / 2, by: xstep) {
                let s = text(format(v), font, ink)
                s.draw(at: CGPoint(x: xpos(v) - s.size().width / 2, y: plot.maxY + 3))
            }
            ctx.move(to: CGPoint(x: plot.minX, y: zero)); ctx.addLine(to: CGPoint(x: plot.maxX, y: zero))
        } else if horizontal {
            ctx.move(to: CGPoint(x: zero, y: plot.minY)); ctx.addLine(to: CGPoint(x: zero, y: plot.maxY))
        } else {
            ctx.move(to: CGPoint(x: plot.minX, y: zero)); ctx.addLine(to: CGPoint(x: plot.maxX, y: zero))
        }
        ctx.strokePath()
        let band = (horizontal ? plot.height : plot.width) / CGFloat(n)
        let between = m.kind == .column || m.kind == .bar
        func cpos(_ k: Int) -> CGFloat {
            // Lines and areas put points on category centres too (as PowerPoint does by default "between").
            let off = between || m.kind == .line ? band * (CGFloat(k) + 0.5) : (n > 1 ? plot.width * CGFloat(k) / CGFloat(n - 1) : plot.width / 2)
            // Bars: the first category at the bottom unless the axis is reversed.
            if horizontal { return m.reverseCategories ? plot.minY + off : plot.maxY - off }
            return plot.minX + off
        }
        if m.kind != .scatter {
            let maxLabel = band - 2
            for (k, c) in catLabels.enumerated() {
                let s = text(c, font, ink)
                let sz = s.size()
                if horizontal {
                    let w = min(sz.width, plot.minX - area0.minX - 6)
                    s.draw(with: CGRect(x: plot.minX - w - 5, y: cpos(k) - sz.height / 2, width: w + 1, height: sz.height), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
                } else if sz.width <= maxLabel || n <= 1 {
                    s.draw(at: CGPoint(x: cpos(k) - sz.width / 2, y: plot.maxY + 3))
                } else {
                    ctx.saveGState()
                    ctx.translateBy(x: cpos(k), y: plot.maxY + 3)
                    ctx.rotate(by: -.pi / 4)
                    s.draw(at: CGPoint(x: -sz.width, y: -sz.height / 2))
                    ctx.restoreGState()
                }
            }
        }
        func value(_ s: ChartSeries, _ k: Int) -> Double? { k < s.values.count ? s.values[k] : nil }
        func total(_ k: Int) -> Double { m.series.reduce(0) { $0 + abs(value($1, k) ?? 0) } }
        func scaled(_ v: Double, _ k: Int) -> Double { percent ? (total(k) > 0 ? v / total(k) : 0) : v }
        var labels: [(String, CGPoint)] = []

        switch m.kind {
        case .column, .bar:
            let ns = stacked ? 1 : max(1, m.series.count)
            let gap = CGFloat(max(0, m.gapWidth)) / 100
            let barW = band / (CGFloat(ns) + gap)
            for k in 0..<n {
                var pos = 0.0, neg = 0.0
                for (i, s) in m.series.enumerated() {
                    guard let v0 = value(s, k) else { continue }
                    let v = scaled(v0, k)
                    let a: Double, b: Double
                    if stacked { if v >= 0 { a = pos; pos += v; b = pos } else { a = neg; neg += v; b = neg } } else { a = 0; b = v }
                    let start = cpos(k) - barW * CGFloat(ns) / 2 + CGFloat(stacked ? 0 : i) * barW
                    let p1 = vpos(a), p2 = vpos(b)
                    let r = horizontal ? CGRect(x: min(p1, p2), y: start, width: abs(p2 - p1), height: barW)
                                       : CGRect(x: start, y: min(p1, p2), width: barW, height: abs(p2 - p1))
                    ctx.setFillColor((m.varyColors && m.series.count == 1 ? pointColor(s, k, m) : seriesColor(i, s)).resolved(theme).cgColor)
                    ctx.fill(r)
                    if m.dataLabels {
                        let t = format(percent ? v : v0, percent: percent, format: m.numberFormat)
                        labels.append((t, stacked ? CGPoint(x: r.midX, y: r.midY) : horizontal ? CGPoint(x: r.maxX + 4 + 10, y: r.midY) : CGPoint(x: r.midX, y: r.minY - lineH / 2)))
                    }
                }
            }
        case .line, .area:
            var prev = Array(repeating: 0.0, count: n)
            var layers: [(Int, [CGPoint], [CGPoint])] = []
            for (i, s) in m.series.enumerated() {
                var top: [CGPoint] = [], bottom: [CGPoint] = []
                var cur = prev
                for k in 0..<n {
                    let v = scaled(value(s, k) ?? 0, k)
                    let b = stacked ? prev[k] : 0
                    cur[k] = stacked ? prev[k] + v : v
                    top.append(CGPoint(x: cpos(k), y: vpos(cur[k])))
                    bottom.append(CGPoint(x: cpos(k), y: vpos(b)))
                    if m.dataLabels, value(s, k) != nil { labels.append((format(percent ? v : value(s, k)!, percent: percent, format: m.numberFormat), CGPoint(x: cpos(k), y: vpos(cur[k]) - lineH / 2 - 2))) }
                }
                if stacked { prev = cur }
                layers.append((i, top, bottom))
            }
            for (i, top, bottom) in layers {
                let s = m.series[i]
                let color = seriesColor(i, s).resolved(theme)
                if m.kind == .area {
                    let p = CGMutablePath()
                    p.addLines(between: top + bottom.reversed())
                    p.closeSubpath()
                    ctx.addPath(p)
                    ctx.setFillColor(color.cgColor)
                    ctx.fillPath()
                } else {
                    ctx.setStrokeColor(color.cgColor)
                    ctx.setLineWidth(s.lineWidth ?? 2.25)
                    ctx.setLineJoin(.round)
                    ctx.setLineCap(.round)
                    var pts: [CGPoint] = []
                    for (k, q) in top.enumerated() where value(s, k) != nil { pts.append(q) }
                    if pts.count > 1 { ctx.addLines(between: pts); ctx.strokePath() }
                    if s.markers {
                        ctx.setFillColor(color.cgColor)
                        let r = max(2.2, (s.lineWidth ?? 2.25) * 1.2)
                        for q in pts { marker(s.symbol ?? symbols[i % symbols.count], at: q, r: r, ctx: ctx) }
                    }
                }
            }
        case .scatter:
            for (i, s) in m.series.enumerated() {
                let color = seriesColor(i, s).resolved(theme)
                var pts: [CGPoint] = []
                for (k, v) in s.values.enumerated() {
                    guard let v else { continue }
                    let x = k < s.xValues.count ? (s.xValues[k] ?? Double(k + 1)) : Double(k + 1)
                    pts.append(CGPoint(x: xpos(x), y: vpos(v)))
                    if m.dataLabels { labels.append((format(v, format: m.numberFormat), CGPoint(x: xpos(x), y: vpos(v) - lineH / 2 - 3))) }
                }
                if s.smooth || s.lineWidth != nil, pts.count > 1 {
                    ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(s.lineWidth ?? 2.25)
                    ctx.addLines(between: pts); ctx.strokePath()
                }
                ctx.setFillColor(color.cgColor)
                ctx.setStrokeColor(color.cgColor)
                if s.markers { for q in pts { marker(s.symbol ?? symbols[i % symbols.count], at: q, r: 3, ctx: ctx) } }
            }
        default: break
        }
        for (t, p) in labels {
            let s = text(t, font, ink)
            let sz = s.size()
            s.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
        }
    }
}
