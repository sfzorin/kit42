import AppKit
import Kit42

/// Draws a SheetChart (column, bar, line, area, pie, scatter) from the workbook's values.
enum ChartRenderer {
    static let palette: [NSColor] = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47", "264478", "9E480E"].map { hex in
        let v = Int(hex, radix: 16)!
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    struct Resolved {
        var name: String
        var categories: [String]
        var values: [Double]
    }

    /// Evaluates a series reference ("Sheet1!$B$2:$B$5") to values.
    static func resolve(_ chart: SheetChart, workbook: Workbook, sheet: Int) -> [Resolved] {
        let calc = Calculator(workbook)
        func values(_ ref: String?) -> [Value] {
            guard let ref, let e = Calculator.expression("=" + ref) else { return [] }
            switch calc.eval(e, sheet: sheet, at: CellRef(row: 0, col: 0)) {
            case .matrix(let m, _): return m.values
            case .value(let v): return [v]
            }
        }
        return chart.series.map { s in
            let nums = values(s.values).map { v -> Double in if case .number(let d) = v { return d }; return 0 }
            var cats = values(s.categories).map { v -> String in
                if case .number(let d) = v { return Value.formatGeneral(d) }
                return v.plain
            }
            if cats.isEmpty { cats = (1...max(1, nums.count)).map(String.init) }
            let name = s.name.hasPrefix("=") ? values(String(s.name.dropFirst())).first?.plain ?? "" : s.name
            return Resolved(name: name, categories: cats, values: nums)
        }
    }

    static func draw(_ chart: SheetChart, in rect: NSRect, workbook: Workbook, sheet: Int, scale: CGFloat) {
        NSColor.white.setFill()
        let frame = NSBezierPath(rect: rect)
        frame.fill()
        NSColor(white: 0.82, alpha: 1).setStroke()
        frame.lineWidth = 1
        frame.stroke()

        let series = resolve(chart, workbook: workbook, sheet: sheet)
        let font = NSFont(name: "Helvetica Neue", size: 9 * scale) ?? .systemFont(ofSize: 9 * scale)
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.35, alpha: 1)]
        var area = rect.insetBy(dx: 10 * scale, dy: 8 * scale)

        if !chart.title.isEmpty {
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica Neue Medium", size: 13 * scale) ?? font,
                                                             .foregroundColor: NSColor(white: 0.2, alpha: 1)]
            let size = (chart.title as NSString).size(withAttributes: titleAttrs)
            (chart.title as NSString).draw(at: NSPoint(x: area.midX - size.width / 2, y: area.minY), withAttributes: titleAttrs)
            area.origin.y += size.height + 6 * scale
            area.size.height -= size.height + 6 * scale
        }
        // Legend at the bottom
        let legendItems: [(String, NSColor)] = chart.kind == .pie
            ? (series.first?.categories ?? []).enumerated().map { ($1, palette[$0 % palette.count]) }
            : series.enumerated().map { ($1.name.isEmpty ? L("Series %d", $0 + 1) : $1.name, palette[$0 % palette.count]) }
        if !legendItems.isEmpty {
            let h = 14 * scale
            var x = area.minX
            let y = area.maxY - h
            for (name, color) in legendItems.prefix(10) {
                color.setFill()
                NSRect(x: x, y: y + 3 * scale, width: 8 * scale, height: 8 * scale).fill()
                (name as NSString).draw(at: NSPoint(x: x + 11 * scale, y: y + 1), withAttributes: label)
                x += (name as NSString).size(withAttributes: label).width + 22 * scale
            }
            area.size.height -= h + 4 * scale
        }
        guard !series.isEmpty, area.width > 20, area.height > 20 else { return }

        if chart.kind == .pie {
            let values = series[0].values.map { max(0, $0) }
            let total = values.reduce(0, +)
            guard total > 0 else { return }
            let r = min(area.width, area.height) / 2 - 2
            let c = NSPoint(x: area.midX, y: area.midY)
            var angle: CGFloat = 90
            for (i, v) in values.enumerated() {
                let sweep = CGFloat(v / total) * 360
                let p = NSBezierPath()
                p.move(to: c)
                p.appendArc(withCenter: c, radius: r, startAngle: -angle, endAngle: -(angle + sweep), clockwise: true)
                p.close()
                palette[i % palette.count].setFill()
                p.fill()
                NSColor.white.setStroke()
                p.lineWidth = 1
                p.stroke()
                angle += sweep
            }
            return
        }

        // Axes
        let all = series.flatMap(\.values)
        var lo = min(0, all.min() ?? 0), hi = max(0, all.max() ?? 1)
        if hi == lo { hi = lo + 1 }
        let step = niceStep((hi - lo) / 5)
        lo = (lo / step).rounded(.down) * step
        hi = (hi / step).rounded(.up) * step
        let axisLabelWidth = max(("\(Value.formatGeneral(hi))" as NSString).size(withAttributes: label).width,
                                 ("\(Value.formatGeneral(lo))" as NSString).size(withAttributes: label).width) + 4 * scale
        let horizontal = chart.kind == .bar
        var plot = area
        plot.origin.x += horizontal ? 60 * scale : axisLabelWidth
        plot.size.width -= horizontal ? 60 * scale : axisLabelWidth
        plot.size.height -= 14 * scale
        let categories = series.map(\.categories).max { $0.count < $1.count } ?? []
        let n = max(1, categories.count, series.map(\.values.count).max() ?? 1)

        func valuePos(_ v: Double) -> CGFloat {
            horizontal ? plot.minX + CGFloat((v - lo) / (hi - lo)) * plot.width
                       : plot.maxY - CGFloat((v - lo) / (hi - lo)) * plot.height
        }
        // Gridlines + value labels
        var v = lo
        while v <= hi + step / 2 {
            NSColor(white: 0.9, alpha: 1).setFill()
            let p = valuePos(v)
            let text = Value.formatGeneral(v) as NSString
            let size = text.size(withAttributes: label)
            if horizontal {
                NSRect(x: p, y: plot.minY, width: 0.5, height: plot.height).fill()
                text.draw(at: NSPoint(x: p - size.width / 2, y: plot.maxY + 2), withAttributes: label)
            } else {
                NSRect(x: plot.minX, y: p, width: plot.width, height: 0.5).fill()
                text.draw(at: NSPoint(x: plot.minX - size.width - 3 * scale, y: p - size.height / 2), withAttributes: label)
            }
            v += step
        }
        // Category labels
        let band = (horizontal ? plot.height : plot.width) / CGFloat(n)
        for (i, c) in categories.enumerated() {
            let text = c as NSString
            let size = text.size(withAttributes: label)
            if horizontal {
                text.draw(in: NSRect(x: area.minX, y: plot.minY + band * CGFloat(i) + band / 2 - size.height / 2, width: 56 * scale, height: size.height), withAttributes: label)
            } else if size.width < band * 1.4 || i % max(1, Int(size.width / band) + 1) == 0 {
                text.draw(at: NSPoint(x: plot.minX + band * CGFloat(i) + band / 2 - size.width / 2, y: plot.maxY + 2), withAttributes: label)
            }
        }
        let zero = valuePos(max(lo, min(hi, 0)))
        switch chart.kind {
        case .column, .bar:
            let groupWidth = band * 0.7
            let w = groupWidth / CGFloat(series.count)
            for (si, s) in series.enumerated() {
                palette[si % palette.count].setFill()
                for (i, value) in s.values.enumerated() {
                    let start = band * CGFloat(i) + (band - groupWidth) / 2 + w * CGFloat(si)
                    let p = valuePos(value)
                    if horizontal {
                        NSRect(x: min(zero, p), y: plot.minY + start, width: abs(p - zero), height: w * 0.92).fill()
                    } else {
                        NSRect(x: plot.minX + start, y: min(zero, p), width: w * 0.92, height: abs(p - zero)).fill()
                    }
                }
            }
        case .line, .area, .scatter:
            for (si, s) in series.enumerated() {
                let color = palette[si % palette.count]
                let path = NSBezierPath()
                for (i, value) in s.values.enumerated() {
                    let p = NSPoint(x: plot.minX + band * CGFloat(i) + band / 2, y: valuePos(value))
                    if i == 0 { path.move(to: p) } else { path.line(to: p) }
                    if chart.kind == .scatter || s.values.count < 30 {
                        color.setFill()
                        NSBezierPath(ovalIn: NSRect(x: p.x - 2.5 * scale, y: p.y - 2.5 * scale, width: 5 * scale, height: 5 * scale)).fill()
                    }
                }
                if chart.kind == .area, let last = s.values.indices.last {
                    let fill = path.copy() as! NSBezierPath
                    fill.line(to: NSPoint(x: plot.minX + band * CGFloat(last) + band / 2, y: zero))
                    fill.line(to: NSPoint(x: plot.minX + band / 2, y: zero))
                    fill.close()
                    color.withAlphaComponent(0.35).setFill()
                    fill.fill()
                }
                if chart.kind != .scatter {
                    color.setStroke()
                    path.lineWidth = 2 * scale
                    path.lineJoinStyle = .round
                    path.stroke()
                }
            }
        case .pie:
            break
        }
        NSColor(white: 0.6, alpha: 1).setFill()
        if horizontal { NSRect(x: zero, y: plot.minY, width: 1, height: plot.height).fill() }
        else { NSRect(x: plot.minX, y: zero, width: plot.width, height: 1).fill() }
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let p = pow(10, floor(log10(raw)))
        let f = raw / p
        return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p
    }
}
