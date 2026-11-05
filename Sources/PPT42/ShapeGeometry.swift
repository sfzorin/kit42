import AppKit

// Shape outlines: the OOXML preset shapes (from PresetData.swift, equations in LibreOffice's syntax) and
// custom geometry (a:custGeom with its guide formulas). Both produce sub-paths with their own fill mode.

enum GeoFill: String, Equatable {
    case norm, none, darken, darkenLess, lighten, lightenLess
}

struct GeoSubpath {
    var path: CGPath
    var fill: GeoFill = .norm
    var stroke = true
}

// MARK: - Custom geometry model (a:custGeom)

struct GeoGuide: Equatable {
    var name: String
    var fmla: String
}

enum GeoCommand: Equatable {
    case move(String, String)
    case line(String, String)
    case arc(wR: String, hR: String, st: String, sw: String)
    case quad(String, String, String, String)
    case cubic(String, String, String, String, String, String)
    case close
}

struct GeoPath: Equatable {
    var w: Double?
    var h: Double?
    var fill: GeoFill = .norm
    var stroke = true
    var commands: [GeoCommand] = []
}

struct CustomGeometry: Equatable {
    var adjust: [GeoGuide] = []
    var guides: [GeoGuide] = []
    /// Text rectangle (l, t, r, b guide names or numbers).
    var rect: [String]?
    var paths: [GeoPath] = []

    /// A literal outline (no guides) from a CGPath in a w×h box.
    init(path: CGPath, size: CGSize, fill: GeoFill = .norm, stroke: Bool = true) {
        var gp = GeoPath(w: Double(max(1, size.width * 100)), h: Double(max(1, size.height * 100)), fill: fill, stroke: stroke)
        func n(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))" }
        path.applyWithBlock { e in
            let el = e.pointee, p = el.points
            switch el.type {
            case .moveToPoint: gp.commands.append(.move(n(p[0].x), n(p[0].y)))
            case .addLineToPoint: gp.commands.append(.line(n(p[0].x), n(p[0].y)))
            case .addQuadCurveToPoint: gp.commands.append(.quad(n(p[0].x), n(p[0].y), n(p[1].x), n(p[1].y)))
            case .addCurveToPoint: gp.commands.append(.cubic(n(p[0].x), n(p[0].y), n(p[1].x), n(p[1].y), n(p[2].x), n(p[2].y)))
            case .closeSubpath: gp.commands.append(.close)
            @unknown default: break
            }
        }
        paths = [gp]
    }

    init() {}
}

// MARK: - OOXML guide formulas

enum OOXMLGeometry {
    /// Guide values for a shape of w×h EMU.
    static func values(_ g: CustomGeometry, w: Double, h: Double, overrides: [String: Int] = [:]) -> [String: Double] {
        var v: [String: Double] = [:]
        let ss = min(w, h), ls = max(w, h)
        v["w"] = w; v["h"] = h; v["l"] = 0; v["t"] = 0; v["r"] = w; v["b"] = h
        v["hc"] = w / 2; v["vc"] = h / 2; v["ss"] = ss; v["ls"] = ls
        for d in [2, 3, 4, 5, 6, 8, 10, 12, 16, 32] {
            v["wd\(d)"] = w / Double(d); v["hd\(d)"] = h / Double(d); v["ssd\(d)"] = ss / Double(d)
        }
        v["cd2"] = 10800000; v["cd4"] = 5400000; v["cd8"] = 2700000; v["3cd4"] = 16200000; v["3cd8"] = 8100000
        v["5cd8"] = 13500000; v["7cd8"] = 18900000
        for a in g.adjust {
            if let o = overrides[a.name] { v[a.name] = Double(o) } else { v[a.name] = eval(a.fmla, v) }
        }
        for gd in g.guides { v[gd.name] = eval(gd.fmla, v) }
        return v
    }

    static func eval(_ fmla: String, _ v: [String: Double]) -> Double {
        let p = fmla.split(separator: " ").map(String.init)
        func a(_ i: Int) -> Double {
            guard p.indices.contains(i) else { return 0 }
            return Double(p[i]) ?? v[p[i]] ?? 0
        }
        let deg = Double.pi / 180 / 60000
        switch p.first ?? "" {
        case "val": return a(1)
        case "*/": return a(3) == 0 ? 0 : a(1) * a(2) / a(3)
        case "+-": return a(1) + a(2) - a(3)
        case "+/": return a(3) == 0 ? 0 : (a(1) + a(2)) / a(3)
        case "?:": return a(1) > 0 ? a(2) : a(3)
        case "abs": return abs(a(1))
        case "at2": return atan2(a(2), a(1)) / deg
        case "cat2": return a(1) * cos(atan2(a(3), a(2)))
        case "sat2": return a(1) * sin(atan2(a(3), a(2)))
        case "cos": return a(1) * cos(a(2) * deg)
        case "sin": return a(1) * sin(a(2) * deg)
        case "tan": return a(1) * tan(a(2) * deg)
        case "max": return max(a(1), a(2))
        case "min": return min(a(1), a(2))
        case "mod": return (a(1) * a(1) + a(2) * a(2) + a(3) * a(3)).squareRoot()
        case "pin": return a(2) < a(1) ? a(1) : a(2) > a(3) ? a(3) : a(2)
        case "sqrt": return a(1).squareRoot()
        default: return Double(fmla) ?? v[fmla] ?? 0
        }
    }

    static func subpaths(_ g: CustomGeometry, size: CGSize, adjust: [String: Int] = [:]) -> [GeoSubpath] {
        let w = Double(size.width * emuPerPoint), h = Double(size.height * emuPerPoint)
        let v = values(g, w: w, h: h, overrides: adjust)
        func num(_ s: String) -> Double { Double(s) ?? v[s] ?? 0 }
        var out: [GeoSubpath] = []
        for gp in g.paths {
            let sx: CGFloat = gp.w.map { $0 > 0 ? size.width / CGFloat($0) : 1 } ?? 1 / emuPerPoint
            let sy: CGFloat = gp.h.map { $0 > 0 ? size.height / CGFloat($0) : 1 } ?? 1 / emuPerPoint
            func pt(_ x: String, _ y: String) -> CGPoint { CGPoint(x: CGFloat(num(x)) * sx, y: CGFloat(num(y)) * sy) }
            let path = CGMutablePath()
            for c in gp.commands {
                switch c {
                case .move(let x, let y): path.move(to: pt(x, y))
                case .line(let x, let y): if path.isEmpty { path.move(to: pt(x, y)) } else { path.addLine(to: pt(x, y)) }
                case .quad(let a, let b, let c, let d): path.addQuadCurve(to: pt(c, d), control: pt(a, b))
                case .cubic(let a, let b, let c, let d, let e, let f): path.addCurve(to: pt(e, f), control1: pt(a, b), control2: pt(c, d))
                case .arc(let wR, let hR, let st, let sw):
                    Arc.add(to: path, wR: CGFloat(num(wR)) * sx, hR: CGFloat(num(hR)) * sy, start: num(st) / 60000, sweep: num(sw) / 60000)
                case .close: path.closeSubpath()
                }
            }
            out.append(GeoSubpath(path: path, fill: gp.fill, stroke: gp.stroke))
        }
        return out
    }

    static func textRect(_ g: CustomGeometry, size: CGSize, adjust: [String: Int] = [:]) -> CGRect? {
        guard let r = g.rect, r.count == 4 else { return nil }
        let v = values(g, w: Double(size.width * emuPerPoint), h: Double(size.height * emuPerPoint), overrides: adjust)
        let n = r.map { CGFloat(Double($0) ?? v[$0] ?? 0) / emuPerPoint }
        return CGRect(x: n[0], y: n[1], width: max(1, n[2] - n[0]), height: max(1, n[3] - n[1]))
    }
}

/// Arc as OOXML/LibreOffice define arcTo: from the current point, along an ellipse with radii wR×hR,
/// from the (visual) start angle sweeping `sweep` degrees, clockwise on screen for positive sweeps.
enum Arc {
    static func add(to path: CGMutablePath, wR: CGFloat, hR: CGFloat, start: Double, sweep: Double) {
        guard wR > 0.0001 || hR > 0.0001, sweep != 0 else { return }
        let st = start * .pi / 180, en = (start + sweep) * .pi / 180
        // Visual angle → parametric angle on the ellipse.
        func param(_ a: Double) -> Double { atan2(Double(wR) * sin(a), Double(hR) * cos(a)) }
        let t1 = param(st)
        var d = param(en) - t1
        if abs(sweep) >= 360 { d = sweep > 0 ? 2 * .pi : -2 * .pi } else if sweep > 0 { while d <= 0 { d += 2 * .pi } } else { while d >= 0 { d -= 2 * .pi } }
        let cur = path.isEmpty ? CGPoint.zero : path.currentPoint
        let c = CGPoint(x: cur.x - wR * CGFloat(cos(t1)), y: cur.y - hR * CGFloat(sin(t1)))
        if path.isEmpty { path.move(to: cur) }
        // Cubic pieces of at most 90°.
        let n = max(1, Int(ceil(abs(d) / (.pi / 2))))
        let step = d / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var a = t1
        for _ in 0..<n {
            let b = a + step
            let p0 = (cos(a), sin(a)), p3 = (cos(b), sin(b))
            let c1 = CGPoint(x: c.x + wR * CGFloat(p0.0 - k * p0.1), y: c.y + hR * CGFloat(p0.1 + k * p0.0))
            let c2 = CGPoint(x: c.x + wR * CGFloat(p3.0 + k * p3.1), y: c.y + hR * CGFloat(p3.1 - k * p3.0))
            path.addCurve(to: CGPoint(x: c.x + wR * CGFloat(p3.0), y: c.y + hR * CGFloat(p3.1)), control1: c1, control2: c2)
            a = b
        }
    }
}

// MARK: - Preset shapes (LibreOffice equation syntax)

indirect enum LExpr {
    case num(Double), eq(Int), adj(Int), w, h, pi
    case neg(LExpr)
    case bin(Character, LExpr, LExpr)
    case fn(String, [LExpr])

    /// Parses "logwidth*$0/100000", "if(0-$0,0,?1)"…
    static func parse(_ s: String) -> LExpr {
        var chars = Array(s.replacingOccurrences(of: " ", with: ""))
        var i = 0
        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        func additive() -> LExpr {
            var l = term()
            while let c = peek(), c == "+" || c == "-" { i += 1; l = .bin(c, l, term()) }
            return l
        }
        func term() -> LExpr {
            var l = unary()
            while let c = peek(), c == "*" || c == "/" { i += 1; l = .bin(c, l, unary()) }
            return l
        }
        func unary() -> LExpr {
            if peek() == "-" { i += 1; return .neg(unary()) }
            if peek() == "+" { i += 1; return unary() }
            return primary()
        }
        func number() -> Double {
            var t = ""
            while let c = peek(), c.isNumber || c == "." || c == "E" || (c == "-" && t.last == "E") { t.append(c); i += 1 }
            return Double(t) ?? 0
        }
        func primary() -> LExpr {
            guard let c = peek() else { return .num(0) }
            if c == "(" { i += 1; let e = additive(); if peek() == ")" { i += 1 }; return e }
            if c == "?" { i += 1; if peek() == "f" { i += 1 }; return .eq(Int(number())) }
            if c == "$" { i += 1; return .adj(Int(number())) }
            if c.isNumber || c == "." { return .num(number()) }
            var name = ""
            while let c = peek(), c.isLetter || c.isNumber { name.append(c); i += 1 }
            if peek() == "(" {
                i += 1
                var args: [LExpr] = []
                while peek() != nil && peek() != ")" {
                    args.append(additive())
                    if peek() == "," { i += 1 }
                }
                i += 1
                return .fn(name, args)
            }
            switch name {
            case "logwidth", "width", "right": return .w
            case "logheight", "height", "bottom": return .h
            case "pi": return .pi
            default: return .num(0)
            }
        }
        _ = chars.count
        let e = additive()
        chars = []
        return e
    }
}

enum LParam {
    case num(Double), eq(Int), adj(Int)

    init(_ s: Substring) {
        if s.hasPrefix("?") { self = .eq(Int(s.dropFirst()) ?? 0) }
        else if s.hasPrefix("$") { self = .adj(Int(s.dropFirst()) ?? 0) }
        else { self = .num(Double(s) ?? 0) }
    }
}

struct PresetHandle {
    var x: LParam, y: LParam
    var polar = false
    var refX: Int?, refY: Int?
}

struct PresetDef {
    enum Cmd { case move([LParam]), line([LParam]), cubic([LParam]), quad([LParam]), arc([LParam]), close, end, noFill, noStroke, mode(GeoFill) }
    let name: String
    let adjNames: [String]
    let adjDefaults: [Double]
    let eqs: [LExpr]
    let cmds: [Cmd]
    let frames: [[LParam]]
    let views: [CGSize]
    let handles: [PresetHandle]

    init?(line: Substring) {
        let f = line.split(separator: "|", omittingEmptySubsequences: false)
        guard f.count >= 7 else { return nil }
        name = String(f[0])
        var names: [String] = [], defs: [Double] = []
        for kv in f[1].split(separator: ",") {
            let p = kv.split(separator: "=")
            names.append(String(p[0])); defs.append(Double(p.count > 1 ? p[1] : "0") ?? 0)
        }
        adjNames = names; adjDefaults = defs
        eqs = f[2].split(separator: ";").map { LExpr.parse(String($0)) }
        var cmds: [Cmd] = []
        let toks = f[3].split(separator: " ")
        var i = 0
        func params(_ n: Int) -> [LParam] {
            var out: [LParam] = []
            while out.count < n * 2, i < toks.count, let ch = toks[i].first, !ch.isLetter || ch == "?" {
                for part in toks[i].split(separator: ",") { out.append(LParam(part)) }
                i += 1
            }
            return out
        }
        while i < toks.count {
            let t = toks[i]; i += 1
            switch t {
            case "M": cmds.append(.move(params(1)))
            case "L": cmds.append(.line(params(1)))
            case "C": cmds.append(.cubic(params(3)))
            case "Q": cmds.append(.quad(params(2)))
            case "A": cmds.append(.arc(params(2)))
            case "Z": cmds.append(.close)
            case "N": cmds.append(.end)
            case "F": cmds.append(.noFill)
            case "S": cmds.append(.noStroke)
            case "D": cmds.append(.mode(.darken))
            case "d": cmds.append(.mode(.darkenLess))
            case "H": cmds.append(.mode(.lighten))
            case "h": cmds.append(.mode(.lightenLess))
            default: break
            }
        }
        self.cmds = cmds
        frames = f[4].split(separator: ";").map { $0.split(separator: ",").map(LParam.init) }
        views = f[5].split(separator: ";").map { s in
            let p = s.split(separator: ",").compactMap { Double($0) }
            return CGSize(width: p.first ?? 0, height: p.count > 1 ? p[1] : 0)
        }
        handles = f[6].split(separator: " ").compactMap { h in
            let parts = h.split(separator: "@")
            guard parts.count == 2 else { return nil }
            let pos = parts[0].split(separator: ",")
            guard pos.count == 2 else { return nil }
            var ref = parts[1]
            var polar = false
            if ref.hasPrefix("p") { polar = true; ref = ref.dropFirst() }
            let refs = ref.split(separator: "[").first?.split(separator: ",") ?? []
            func r(_ k: Int) -> Int? { refs.count > k ? Int(refs[k]) : nil }
            return PresetHandle(x: LParam(pos[0]), y: LParam(pos[1]), polar: polar, refX: r(0), refY: r(1))
        }
    }

    final class Eval {
        let def: PresetDef
        let w: Double, h: Double
        let adj: [Double]
        var cache: [Double?]
        var busy = Set<Int>()

        init(_ def: PresetDef, w: Double, h: Double, adj: [Double]) {
            self.def = def; self.w = w; self.h = h; self.adj = adj
            cache = Array(repeating: nil, count: def.eqs.count)
        }

        func eq(_ i: Int) -> Double {
            guard def.eqs.indices.contains(i) else { return 0 }
            if let v = cache[i] { return v }
            guard !busy.contains(i) else { return 0 }
            busy.insert(i)
            let v = value(def.eqs[i])
            busy.remove(i)
            cache[i] = v.isFinite ? v : 0
            return cache[i]!
        }

        func value(_ e: LExpr) -> Double {
            switch e {
            case .num(let v): return v
            case .eq(let i): return eq(i)
            case .adj(let i): return adj.indices.contains(i) ? adj[i] : 0
            case .w: return w
            case .h: return h
            case .pi: return .pi
            case .neg(let a): return -value(a)
            case .bin(let op, let a, let b):
                let x = value(a), y = value(b)
                switch op {
                case "+": return x + y
                case "-": return x - y
                case "*": return x * y
                default: return y == 0 ? 0 : x / y
                }
            case .fn(let name, let args):
                let v = args.map(value)
                func a(_ k: Int) -> Double { v.indices.contains(k) ? v[k] : 0 }
                switch name {
                case "if": return a(0) > 0 ? a(1) : a(2)
                case "min": return min(a(0), a(1))
                case "max": return max(a(0), a(1))
                case "abs": return abs(a(0))
                case "sqrt": return a(0) > 0 ? a(0).squareRoot() : 0
                case "sin": return sin(a(0))
                case "cos": return cos(a(0))
                case "tan": return tan(a(0))
                case "atan": return atan(a(0))
                case "atan2": return atan2(a(0), a(1))
                default: return 0
                }
            }
        }

        func param(_ p: LParam) -> Double {
            switch p {
            case .num(let v): return v
            case .eq(let i): return eq(i)
            case .adj(let i): return adj.indices.contains(i) ? adj[i] : 0
            }
        }
    }

    func adjustValues(_ adjust: [String: Int]) -> [Double] {
        adjNames.enumerated().map { k, name in
            if let v = adjust[name] { return Double(v) }
            // Files and older versions call a single value "adj" or "adj1".
            if adjNames.count == 1, let v = adjust["adj"] ?? adjust["adj1"] { return Double(v) }
            return adjDefaults[k]
        }
    }

    func subpaths(size: CGSize, adjust: [String: Int]) -> [GeoSubpath] {
        let e = Eval(self, w: Double(size.width), h: Double(size.height), adj: adjustValues(adjust))
        var out: [GeoSubpath] = []
        var path = CGMutablePath()
        var fill = GeoFill.norm, stroke = true
        var sub = 0
        func scale() -> (CGFloat, CGFloat) {
            guard views.indices.contains(sub), views[sub].width > 0, views[sub].height > 0 else { return (1, 1) }
            return (size.width / views[sub].width, size.height / views[sub].height)
        }
        var (sx, sy) = scale()
        func pt(_ p: [LParam], _ k: Int) -> CGPoint {
            guard p.count > k * 2 + 1 else { return .zero }
            return CGPoint(x: CGFloat(e.param(p[k * 2])) * sx, y: CGFloat(e.param(p[k * 2 + 1])) * sy)
        }
        func flush() {
            if !path.isEmpty { out.append(GeoSubpath(path: path, fill: fill, stroke: stroke)) }
            path = CGMutablePath(); fill = .norm; stroke = true
        }
        for c in cmds {
            switch c {
            case .move(let p): path.move(to: pt(p, 0))
            case .line(let p): if path.isEmpty { path.move(to: pt(p, 0)) } else { path.addLine(to: pt(p, 0)) }
            case .cubic(let p): if !path.isEmpty { path.addCurve(to: pt(p, 2), control1: pt(p, 0), control2: pt(p, 1)) }
            case .quad(let p): if !path.isEmpty { path.addQuadCurve(to: pt(p, 1), control: pt(p, 0)) }
            case .arc(let p):
                guard p.count >= 4 else { continue }
                Arc.add(to: path, wR: CGFloat(e.param(p[0])) * sx, hR: CGFloat(e.param(p[1])) * sy, start: e.param(p[2]), sweep: e.param(p[3]))
            case .close: if !path.isEmpty { path.closeSubpath() }
            case .end:
                flush()
                sub += 1
                (sx, sy) = scale()
            case .noFill: fill = .none
            case .noStroke: stroke = false
            case .mode(let m): fill = m
            }
        }
        flush()
        return out
    }

    func textRect(size: CGSize, adjust: [String: Int]) -> CGRect? {
        guard let f = frames.first, f.count == 4 else { return nil }
        let e = Eval(self, w: Double(size.width), h: Double(size.height), adj: adjustValues(adjust))
        let v = f.map { CGFloat(e.param($0)) }
        return CGRect(x: v[0], y: v[1], width: max(1, v[2] - v[0]), height: max(1, v[3] - v[1]))
    }

    /// Handle positions in the shape box.
    func handlePoints(size: CGSize, adjust: [String: Int]) -> [CGPoint] {
        let e = Eval(self, w: Double(size.width), h: Double(size.height), adj: adjustValues(adjust))
        let (sx, sy) = views.first.map { $0.width > 0 && $0.height > 0 ? (size.width / $0.width, size.height / $0.height) : (1, 1) } ?? (1, 1)
        return handles.map { CGPoint(x: CGFloat(e.param($0.x)) * sx, y: CGFloat(e.param($0.y)) * sy) }
    }

    /// Adjust values that bring handle `k` closest to `p` (a search along each value the handle drives).
    func drag(handle k: Int, to p: CGPoint, size: CGSize, adjust: [String: Int]) -> [String: Int] {
        guard handles.indices.contains(k) else { return adjust }
        var vals = adjustValues(adjust)
        let h = handles[k]
        let refs = [h.refX, h.refY].compactMap { $0 }.filter { adjNames.indices.contains($0) }
        func distance(_ v: [Double]) -> Double {
            var a: [String: Int] = [:]
            for (i, n) in adjNames.enumerated() { a[n] = Int(v[i].rounded()) }
            let q = handlePoints(size: size, adjust: a)[k]
            return Double(hypot(q.x - p.x, q.y - p.y))
        }
        for _ in 0..<2 {
            for r in refs {
                let angle = h.polar && r == h.refX
                var lo = angle ? -21600000.0 : -1_000_000.0, hi = angle ? 21600000.0 : 1_000_000.0
                for _ in 0..<4 {
                    let n = 60
                    var best = vals[r], bestD = Double.infinity
                    for s in 0...n {
                        var t = vals
                        t[r] = lo + (hi - lo) * Double(s) / Double(n)
                        let d = distance(t)
                        if d < bestD - 1e-9 { bestD = d; best = t[r] }
                    }
                    let span = (hi - lo) / Double(n)
                    vals[r] = best
                    lo = best - span; hi = best + span
                }
            }
        }
        var out = adjust
        out.removeValue(forKey: "adj")
        for (i, n) in adjNames.enumerated() { out[n] = Int(vals[i].rounded()) }
        return out
    }

    static let all: [String: PresetDef] = {
        var m: [String: PresetDef] = [:]
        for line in presetShapeData.split(separator: "\n") { if let d = PresetDef(line: line) { m[d.name] = d } }
        return m
    }()
}
