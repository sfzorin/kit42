import AppKit
import Kit42

/// Preset shapes (OOXML prst names) drawn as paths in a w×h box at the origin.
enum Shapes {
    struct Preset {
        let prst: String
        let name: String
        let symbol: String
    }

    /// Insert › Shape gallery, in order.
    static let gallery: [Preset] = [
        Preset(prst: "rect", name: L("Rectangle"), symbol: "rectangle"),
        Preset(prst: "roundRect", name: L("Rounded Rectangle"), symbol: "rectangle.roundedtop"),
        Preset(prst: "ellipse", name: L("Oval"), symbol: "oval"),
        Preset(prst: "triangle", name: L("Triangle"), symbol: "triangle"),
        Preset(prst: "rtTriangle", name: L("Right Triangle"), symbol: "triangle"),
        Preset(prst: "diamond", name: L("Diamond"), symbol: "diamond"),
        Preset(prst: "parallelogram", name: L("Parallelogram"), symbol: "rectangle"),
        Preset(prst: "trapezoid", name: L("Trapezoid"), symbol: "rectangle"),
        Preset(prst: "pentagon", name: L("Pentagon"), symbol: "pentagon"),
        Preset(prst: "hexagon", name: L("Hexagon"), symbol: "hexagon"),
        Preset(prst: "octagon", name: L("Octagon"), symbol: "octagon"),
        Preset(prst: "star5", name: L("Star"), symbol: "star"),
        Preset(prst: "plus", name: L("Cross"), symbol: "plus"),
        Preset(prst: "heart", name: L("Heart"), symbol: "heart"),
        Preset(prst: "donut", name: L("Donut"), symbol: "circle.circle"),
        Preset(prst: "rightArrow", name: L("Right Arrow"), symbol: "arrow.right"),
        Preset(prst: "leftArrow", name: L("Left Arrow"), symbol: "arrow.left"),
        Preset(prst: "upArrow", name: L("Up Arrow"), symbol: "arrow.up"),
        Preset(prst: "downArrow", name: L("Down Arrow"), symbol: "arrow.down"),
        Preset(prst: "leftRightArrow", name: L("Left-Right Arrow"), symbol: "arrow.left.and.right"),
        Preset(prst: "chevron", name: L("Chevron"), symbol: "chevron.right"),
        Preset(prst: "homePlate", name: L("Pentagon Arrow"), symbol: "arrowshape.right"),
        Preset(prst: "wedgeRectCallout", name: L("Rectangular Callout"), symbol: "text.bubble"),
        Preset(prst: "wedgeEllipseCallout", name: L("Oval Callout"), symbol: "bubble.left"),
        Preset(prst: "cloud", name: L("Cloud"), symbol: "cloud"),
        Preset(prst: "line", name: L("Line"), symbol: "line.diagonal"),
        Preset(prst: "arrow", name: L("Arrow"), symbol: "line.diagonal.arrow"),
    ]

    static let defaults: [String: [String: Int]] = [
        "roundRect": ["adj": 16667], "triangle": ["adj": 50000], "parallelogram": ["adj": 25000], "trapezoid": ["adj": 25000],
        "hexagon": ["adj": 25000], "octagon": ["adj": 29289], "plus": ["adj": 25000], "donut": ["adj": 25000],
        "rightArrow": ["adj1": 50000, "adj2": 50000], "leftArrow": ["adj1": 50000, "adj2": 50000],
        "upArrow": ["adj1": 50000, "adj2": 50000], "downArrow": ["adj1": 50000, "adj2": 50000],
        "leftRightArrow": ["adj1": 50000, "adj2": 50000], "chevron": ["adj": 50000], "homePlate": ["adj": 50000],
        "star5": ["adj": 19098], "wedgeRectCallout": ["adj1": -20833, "adj2": 62500], "wedgeEllipseCallout": ["adj1": -20833, "adj2": 62500],
        "wedgeRoundRectCallout": ["adj1": -20833, "adj2": 62500, "adj3": 16667],
    ]

    static func adj(_ o: [String: Int], _ prst: String, _ key: String) -> CGFloat {
        CGFloat(o[key] ?? o[key == "adj" ? "adj1" : key] ?? defaults[prst]?[key] ?? defaults[prst]?["adj"] ?? 0) / 100000
    }

    /// Outline of a preset in a box of `size` at the origin (y down).
    static func path(_ prst: String, adjust: [String: Int] = [:], size: CGSize) -> CGPath {
        let w = size.width, h = size.height, ss = min(w, h)
        let p = CGMutablePath()
        func poly(_ pts: [CGPoint]) {
            guard let f = pts.first else { return }
            p.move(to: f)
            for q in pts.dropFirst() { p.addLine(to: q) }
            p.closeSubpath()
        }
        func a(_ k: String) -> CGFloat { adj(adjust, prst, k) }
        let box = CGRect(origin: .zero, size: size)
        switch prst {
        case "ellipse", "flowChartConnector":
            p.addEllipse(in: box)
        case "roundRect", "flowChartAlternateProcess":
            let r = min(ss * a("adj"), ss / 2)
            p.addRoundedRect(in: box, cornerWidth: r, cornerHeight: r)
        case "flowChartTerminator":
            p.addRoundedRect(in: box, cornerWidth: min(h / 2, w / 2), cornerHeight: min(h / 2, w / 2))
        case "triangle", "flowChartExtract":
            poly([CGPoint(x: w * a("adj"), y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
        case "rtTriangle":
            poly([CGPoint(x: 0, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
        case "diamond", "flowChartDecision":
            poly([CGPoint(x: w / 2, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: w / 2, y: h), CGPoint(x: 0, y: h / 2)])
        case "parallelogram", "flowChartInputOutput":
            let x = min(ss * a("adj"), w)
            poly([CGPoint(x: x, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w - x, y: h), CGPoint(x: 0, y: h)])
        case "trapezoid":
            let x = min(ss * a("adj"), w / 2)
            poly([CGPoint(x: x, y: 0), CGPoint(x: w - x, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
        case "pentagon":
            poly([CGPoint(x: w / 2, y: 0), CGPoint(x: w, y: h * 0.382), CGPoint(x: w * 0.809, y: h), CGPoint(x: w * 0.191, y: h), CGPoint(x: 0, y: h * 0.382)])
        case "hexagon":
            let x = min(ss * a("adj"), w / 2)
            poly([CGPoint(x: x, y: 0), CGPoint(x: w - x, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: w - x, y: h), CGPoint(x: x, y: h), CGPoint(x: 0, y: h / 2)])
        case "octagon":
            let x = min(ss * a("adj"), min(w, h) / 2)
            poly([CGPoint(x: x, y: 0), CGPoint(x: w - x, y: 0), CGPoint(x: w, y: x), CGPoint(x: w, y: h - x), CGPoint(x: w - x, y: h),
                  CGPoint(x: x, y: h), CGPoint(x: 0, y: h - x), CGPoint(x: 0, y: x)])
        case "star5", "star4", "star6", "star8":
            let n = prst == "star4" ? 4 : prst == "star6" ? 6 : prst == "star8" ? 8 : 5
            let inner = prst == "star5" ? max(0.1, a("adj") * 2) : 0.4
            var pts: [CGPoint] = []
            for i in 0..<(n * 2) {
                let ang = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(n)
                let r: CGFloat = i % 2 == 0 ? 1 : inner
                pts.append(CGPoint(x: w / 2 + cos(ang) * w / 2 * r, y: h / 2 + sin(ang) * h / 2 * r * (n == 5 ? 1.05 : 1) + (n == 5 ? h * 0.025 : 0)))
            }
            poly(pts)
        case "plus":
            let x = ss * a("adj")
            poly([CGPoint(x: x, y: 0), CGPoint(x: w - x, y: 0), CGPoint(x: w - x, y: x), CGPoint(x: w, y: x), CGPoint(x: w, y: h - x), CGPoint(x: w - x, y: h - x),
                  CGPoint(x: w - x, y: h), CGPoint(x: x, y: h), CGPoint(x: x, y: h - x), CGPoint(x: 0, y: h - x), CGPoint(x: 0, y: x), CGPoint(x: x, y: x)])
        case "heart":
            p.move(to: CGPoint(x: w / 2, y: h * 0.25))
            p.addCurve(to: CGPoint(x: w / 2, y: h), control1: CGPoint(x: w * 1.1, y: -h * 0.3), control2: CGPoint(x: w * 1.05, y: h * 0.55))
            p.addCurve(to: CGPoint(x: w / 2, y: h * 0.25), control1: CGPoint(x: -w * 0.05, y: h * 0.55), control2: CGPoint(x: -w * 0.1, y: -h * 0.3))
            p.closeSubpath()
        case "donut":
            p.addEllipse(in: box)
            let d = ss * a("adj")
            p.addEllipse(in: box.insetBy(dx: d, dy: d))
        case "rightArrow", "leftArrow", "leftRightArrow":
            let shaft = h * a("adj1"), head = min(ss * a("adj2"), prst == "leftRightArrow" ? w / 2 : w)
            let t = (h - shaft) / 2
            var pts: [CGPoint]
            if prst == "leftRightArrow" {
                pts = [CGPoint(x: 0, y: h / 2), CGPoint(x: head, y: 0), CGPoint(x: head, y: t), CGPoint(x: w - head, y: t), CGPoint(x: w - head, y: 0),
                       CGPoint(x: w, y: h / 2), CGPoint(x: w - head, y: h), CGPoint(x: w - head, y: h - t), CGPoint(x: head, y: h - t), CGPoint(x: head, y: h)]
            } else {
                pts = [CGPoint(x: 0, y: t), CGPoint(x: w - head, y: t), CGPoint(x: w - head, y: 0), CGPoint(x: w, y: h / 2),
                       CGPoint(x: w - head, y: h), CGPoint(x: w - head, y: h - t), CGPoint(x: 0, y: h - t)]
                if prst == "leftArrow" { pts = pts.map { CGPoint(x: w - $0.x, y: $0.y) } }
            }
            poly(pts)
        case "upArrow", "downArrow":
            let shaft = w * a("adj1"), head = min(ss * a("adj2"), h)
            let t = (w - shaft) / 2
            var pts = [CGPoint(x: w / 2, y: 0), CGPoint(x: w, y: head), CGPoint(x: w - t, y: head), CGPoint(x: w - t, y: h),
                       CGPoint(x: t, y: h), CGPoint(x: t, y: head), CGPoint(x: 0, y: head)]
            if prst == "downArrow" { pts = pts.map { CGPoint(x: $0.x, y: h - $0.y) } }
            poly(pts)
        case "chevron":
            let x = min(ss * a("adj"), w)
            poly([CGPoint(x: 0, y: 0), CGPoint(x: w - x, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: w - x, y: h), CGPoint(x: 0, y: h), CGPoint(x: x, y: h / 2)])
        case "homePlate":
            let x = min(ss * a("adj"), w)
            poly([CGPoint(x: 0, y: 0), CGPoint(x: w - x, y: 0), CGPoint(x: w, y: h / 2), CGPoint(x: w - x, y: h), CGPoint(x: 0, y: h)])
        case "wedgeRectCallout", "wedgeRoundRectCallout", "wedgeEllipseCallout":
            let tip = CGPoint(x: w / 2 + w * a("adj1"), y: h / 2 + h * a("adj2"))
            if prst == "wedgeEllipseCallout" {
                let body = CGPath(ellipseIn: box, transform: nil)
                p.addPath(body)
                let ang = atan2(tip.y - h / 2, tip.x - w / 2)
                let b1 = CGPoint(x: w / 2 + cos(ang - 0.25) * w / 2, y: h / 2 + sin(ang - 0.25) * h / 2)
                let b2 = CGPoint(x: w / 2 + cos(ang + 0.25) * w / 2, y: h / 2 + sin(ang + 0.25) * h / 2)
                poly([b1, tip, b2, CGPoint(x: w / 2, y: h / 2)])
            } else {
                // Tip off the bottom edge between 1/4 and 3/4 of the width (the common case), else off the nearest side.
                if tip.y > h {
                    poly([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: w * 0.58, y: h), tip,
                          CGPoint(x: w * 0.42, y: h), CGPoint(x: 0, y: h)])
                } else if tip.y < 0 {
                    poly([CGPoint(x: 0, y: 0), CGPoint(x: w * 0.42, y: 0), tip, CGPoint(x: w * 0.58, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
                } else if tip.x < 0 {
                    poly([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.58), tip, CGPoint(x: 0, y: h * 0.42)])
                } else {
                    poly([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h * 0.42), tip, CGPoint(x: w, y: h * 0.58), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
                }
            }
        case "cloud", "cloudCallout":
            // Overlapping circles along an ellipse.
            let n = 9
            for i in 0..<n {
                let ang = CGFloat(i) / CGFloat(n) * 2 * .pi
                let cx = w / 2 + cos(ang) * w * 0.32, cy = h / 2 + sin(ang) * h * 0.3
                let r = CGSize(width: w * 0.22, height: h * 0.25)
                p.addEllipse(in: CGRect(x: cx - r.width, y: cy - r.height, width: r.width * 2, height: r.height * 2))
            }
            p.addEllipse(in: box.insetBy(dx: w * 0.18, dy: h * 0.2))
        case "line", "straightConnector1", "arrow", "bentConnector3", "curvedConnector3":
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: h))
        case "flowChartDocument":
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h * 0.83))
            p.addCurve(to: CGPoint(x: 0, y: h * 0.9), control1: CGPoint(x: w * 0.7, y: h * 0.7), control2: CGPoint(x: w * 0.35, y: h * 1.1))
            p.closeSubpath()
        case "can":
            let e = min(h * 0.25, ss * 0.25)
            p.move(to: CGPoint(x: 0, y: e / 2))
            p.addLine(to: CGPoint(x: 0, y: h - e / 2))
            p.addCurve(to: CGPoint(x: w, y: h - e / 2), control1: CGPoint(x: 0, y: h + e * 0.17), control2: CGPoint(x: w, y: h + e * 0.17))
            p.addLine(to: CGPoint(x: w, y: e / 2))
            p.addCurve(to: CGPoint(x: 0, y: e / 2), control1: CGPoint(x: w, y: -e * 0.17), control2: CGPoint(x: 0, y: -e * 0.17))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 0, y: 0, width: w, height: e))
        default:
            p.addRect(box)
        }
        return p
    }

    /// Area for the text inside a preset (box-relative).
    static func textRect(_ prst: String, size: CGSize) -> CGRect {
        let box = CGRect(origin: .zero, size: size)
        switch prst {
        case "ellipse", "wedgeEllipseCallout", "cloud", "flowChartConnector":
            return box.insetBy(dx: size.width * 0.146, dy: size.height * 0.146)
        case "triangle":
            return CGRect(x: size.width * 0.25, y: size.height * 0.5, width: size.width * 0.5, height: size.height * 0.5)
        case "diamond", "flowChartDecision":
            return box.insetBy(dx: size.width * 0.25, dy: size.height * 0.25)
        default:
            return box
        }
    }

    /// Small picture of a preset for menus and the gallery.
    static func icon(_ prst: String, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inset: CGFloat = 2
            let s = CGSize(width: size - inset * 2, height: (prst == "rightArrow" || prst == "leftArrow" || prst == "leftRightArrow" || prst == "chevron" || prst == "homePlate") ? (size - inset * 2) * 0.7 : size - inset * 2)
            ctx.translateBy(x: inset, y: (size - s.height) / 2)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.3)
            if prst == "line" || prst == "arrow" {
                ctx.move(to: CGPoint(x: 0, y: s.height))
                ctx.addLine(to: CGPoint(x: s.width, y: 0))
                ctx.strokePath()
                if prst == "arrow" {
                    ctx.setFillColor(NSColor.black.cgColor)
                    ctx.move(to: CGPoint(x: s.width, y: 0))
                    ctx.addLine(to: CGPoint(x: s.width - 6, y: 1.5))
                    ctx.addLine(to: CGPoint(x: s.width - 1.5, y: 6))
                    ctx.fillPath()
                }
                return true
            }
            ctx.addPath(path(prst, size: s))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.drawPath(using: .eoFillStroke)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Arrowhead at `tip`, pointing away from `from`.
    static func arrowhead(_ kind: Arrowhead, tip: CGPoint, from: CGPoint, width: CGFloat) -> CGPath? {
        guard kind != .none else { return nil }
        let len = max(6, width * 3.5), half = max(3, width * 2)
        let ang = atan2(tip.y - from.y, tip.x - from.x)
        let back = CGPoint(x: tip.x - cos(ang) * len, y: tip.y - sin(ang) * len)
        let nx = -sin(ang), ny = cos(ang)
        let p = CGMutablePath()
        switch kind {
        case .oval:
            p.addEllipse(in: CGRect(x: tip.x - half, y: tip.y - half, width: half * 2, height: half * 2))
        case .diamond:
            let mid = CGPoint(x: tip.x - cos(ang) * len / 2, y: tip.y - sin(ang) * len / 2)
            p.addLines(between: [CGPoint(x: tip.x + cos(ang) * len / 2, y: tip.y + sin(ang) * len / 2),
                                 CGPoint(x: mid.x + nx * half, y: mid.y + ny * half), back, CGPoint(x: mid.x - nx * half, y: mid.y - ny * half)])
            p.closeSubpath()
        case .stealth:
            let notch = CGPoint(x: tip.x - cos(ang) * len * 0.65, y: tip.y - sin(ang) * len * 0.65)
            p.addLines(between: [tip, CGPoint(x: back.x + nx * half, y: back.y + ny * half), notch, CGPoint(x: back.x - nx * half, y: back.y - ny * half)])
            p.closeSubpath()
        case .arrow:
            p.addLines(between: [CGPoint(x: back.x + nx * half, y: back.y + ny * half), tip, CGPoint(x: back.x - nx * half, y: back.y - ny * half)])
        default:
            p.addLines(between: [tip, CGPoint(x: back.x + nx * half, y: back.y + ny * half), CGPoint(x: back.x - nx * half, y: back.y - ny * half)])
            p.closeSubpath()
        }
        return p
    }
}
