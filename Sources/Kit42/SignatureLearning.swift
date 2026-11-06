import AppKit

/// One signature written by the user: strokes of [x, y, time, pressure] (y up; time in seconds, −1 when unknown,
/// as for a scan or a sketch).
public struct SignatureSample: Codable {
    public var strokes: [[[Double]]]
    /// Line width as a share of the signature's height, measured on a picture (nil when drawn on the pad).
    public var penWidth: Double?
    public init(strokes: [[[Double]]], penWidth: Double? = nil) { self.strokes = strokes; self.penWidth = penWidth }
    public var isTimed: Bool { strokes.first?.first.map { $0.count > 2 && $0[2] >= 0 } ?? false }
}

/// A signature learned from the user's samples. Copies are made by re-synthesising the samples with the
/// sigma-lognormal model: via-points and their real timing come from the samples, two samples are blended when
/// they have the same structure, and each copy perturbs the model — so new copies vary as the user's own do.
public struct LearnedSignature: Codable {
    public var samples: [SignatureSample]
    public init(samples: [SignatureSample]) { self.samples = samples }

    public func render(impression: UInt64, ink: NSColor, pen: PenType, pixelHeight: CGFloat = 120,
                       capture: (([[PenSample]]) -> Void)? = nil) -> CGImage? {
        SignatureLearning.render(self, impression: impression, ink: ink, pen: pen, pixelHeight: pixelHeight, capture: capture)
    }
}

enum SignatureLearning {
    struct Point { var p: CGPoint; var t: Double }

    /// Sample in cap units: height 1, left edge and lowest point at 0.
    static func normalized(_ s: SignatureSample) -> [[Point]] {
        let all = s.strokes.flatMap { $0 }
        guard let minX = all.map({ $0[0] }).min(), let maxY = all.map({ $0[1] }).max(), let minY = all.map({ $0[1] }).min() else { return [] }
        let h = max(1e-6, maxY - minY)
        return s.strokes.map { stroke in
            stroke.map { Point(p: CGPoint(x: ($0[0] - minX) / h, y: ($0[1] - minY) / h), t: $0.count > 2 ? $0[2] : -1) }
        }.filter { $0.count > 1 }
    }

    /// Even spacing along a stroke (`n` points), carrying time.
    static func resample(_ s: [Point], count n: Int) -> [Point] {
        guard s.count > 1, n > 1 else { return s }
        var lengths: [CGFloat] = [0]
        for i in 1..<s.count { lengths.append(lengths[i - 1] + hypot(s[i].p.x - s[i - 1].p.x, s[i].p.y - s[i - 1].p.y)) }
        let total = max(1e-6, lengths.last!)
        var out: [Point] = []
        var j = 0
        for k in 0..<n {
            let target = total * CGFloat(k) / CGFloat(n - 1)
            while j < s.count - 2, lengths[j + 1] < target { j += 1 }
            let seg = max(1e-9, lengths[j + 1] - lengths[j]), u = (target - lengths[j]) / seg
            out.append(Point(p: CGPoint(x: s[j].p.x + (s[j + 1].p.x - s[j].p.x) * u, y: s[j].p.y + (s[j + 1].p.y - s[j].p.y) * u),
                             t: s[j].t + (s[j + 1].t - s[j].t) * Double(u)))
        }
        return out
    }

    /// Via-points of a stroke: Ramer–Douglas–Peucker simplification (keeps the shape), plus the time spent between
    /// them when the stroke was recorded. Sharp turns become corners (the pen nearly stops there).
    static func via(_ stroke: [Point], tolerance: CGFloat = 0.012) -> (points: [CGPoint], corners: Set<Int>, durations: [Double]?) {
        let pts = stroke.map(\.p)
        guard pts.count > 2 else { return (pts, [], nil) }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        func rdp(_ a: Int, _ b: Int) {
            guard b > a + 1 else { return }
            let pa = pts[a], pb = pts[b]
            let dx = pb.x - pa.x, dy = pb.y - pa.y, len = max(1e-9, hypot(dx, dy))
            var worst = -1, dist: CGFloat = 0
            for i in (a + 1)..<b {
                let d = abs((pts[i].x - pa.x) * dy - (pts[i].y - pa.y) * dx) / len
                if d > dist { dist = d; worst = i }
            }
            if dist > tolerance, worst > 0 { keep[worst] = true; rdp(a, worst); rdp(worst, b) }
        }
        rdp(0, pts.count - 1)
        let idx = keep.indices.filter { keep[$0] }
        let points = idx.map { pts[$0] }
        var corners = Set<Int>()
        for k in 1..<max(1, points.count - 1) {
            let a = atan2(points[k].y - points[k - 1].y, points[k].x - points[k - 1].x)
            let b = atan2(points[k + 1].y - points[k].y, points[k + 1].x - points[k].x)
            var d = abs(b - a); if d > .pi { d = 2 * .pi - d }
            if d > 2.0 { corners.insert(k) }   // cusp: more than ~115°
        }
        let timed = stroke.first.map { $0.t >= 0 } ?? false
        let durations: [Double]? = timed ? zip(idx, idx.dropFirst()).map { max(0.02, stroke[$1].t - stroke[$0].t) * 2.2 } : nil
        return (points, corners, durations)
    }

    static func render(_ learned: LearnedSignature, impression: UInt64, ink: NSColor, pen: PenType, pixelHeight: CGFloat,
                       capture: (([[PenSample]]) -> Void)? = nil) -> CGImage? {
        let samples = learned.samples.map(normalized).filter { !$0.isEmpty }
        guard !samples.isEmpty else { return nil }
        var copy = SeededRandom(impression)
        // Base sample, blended with another one of the same structure (same number of strokes, similar lengths).
        let ai = Int(copy.next() % UInt64(samples.count))
        let a = samples[ai]
        var strokes = a
        let partners = samples.indices.filter { $0 != ai && samples[$0].count == a.count }.map { samples[$0] }
        if let b = partners.randomElement(using: &copy), similar(a, b) {
            let w = CGFloat(copy.range(0.15...0.85))
            strokes = zip(a, b).map { sa, sb in
                let n = max(sa.count, sb.count, 24)
                return zip(resample(sa, count: n), resample(sb, count: n)).map { pa, pb in
                    Point(p: CGPoint(x: pa.p.x * (1 - w) + pb.p.x * w, y: pa.p.y * (1 - w) + pb.p.y * w),
                          t: pa.t >= 0 && pb.t >= 0 ? pa.t * Double(1 - w) + pb.t * Double(w) : pa.t)
                }
            }
        }
        var viaStrokes: [[CGPoint]] = []
        var durations: [[Double]] = []
        var anyTimed = false
        for s in strokes {
            let v = via(s)
            // Corners are marked for the synthesiser by repeating the point.
            var pts: [CGPoint] = []
            for (k, p) in v.points.enumerated() { pts.append(p); if v.corners.contains(k) { pts.append(p) } }
            viaStrokes.append(pts)
            durations.append(v.durations ?? [])
            anyTimed = anyTimed || v.durations != nil
        }
        var hand = SigmaLognormal.Hand()
        hand.overlap = anyTimed ? 0.6 : 0.68
        hand.cornerOverlap = 0.3
        hand.sizeScaled = false
        hand.curvatureGain = 0.4
        // The line width of the user's own pen when it was measured on a picture.
        let widths = learned.samples.compactMap(\.penWidth)
        let penRatio = widths.isEmpty ? 0.024 : CGFloat(min(0.06, max(0.012, widths.reduce(0, +) / Double(widths.count))))
        // A learned hand varies less than an invented one: the samples already carry its natural spread.
        return SignatureGenerator.draw(strokes: viaStrokes, hand: hand, slant: 0, penRatio: penRatio, pen: pen, ink: ink,
                                       pixelHeight: pixelHeight, copy: &copy, variation: samples.count > 1 ? 0.6 : 0.85,
                                       durations: anyTimed ? durations : nil, capture: capture)
    }

    /// Same number of strokes with similar lengths: blending them gives a plausible in-between copy.
    private static func similar(_ a: [[Point]], _ b: [[Point]]) -> Bool {
        func len(_ s: [Point]) -> CGFloat { zip(s, s.dropFirst()).reduce(0) { $0 + hypot($1.1.p.x - $1.0.p.x, $1.1.p.y - $1.0.p.y) } }
        return zip(a, b).allSatisfy { sa, sb in
            let la = len(sa), lb = len(sb)
            return abs(la - lb) / max(1e-6, max(la, lb)) < 0.3 && hypot(sa[0].p.x - sb[0].p.x, sa[0].p.y - sb[0].p.y) < 0.35
        }
    }

    // MARK: - Pictures (scan, sketch from iPhone): ink → centre lines → strokes

    /// Traces a picture of a signature into strokes (no timing). Dark or opaque pixels are ink.
    static func trace(_ image: CGImage) -> SignatureSample? {
        // Work at about 360 px height: small letters inside a large signature keep a few pixels of their own.
        let k = min(1, 360 / CGFloat(max(1, image.height)), 1600 / CGFloat(max(1, image.width)))
        let w = max(8, Int(CGFloat(image.width) * k)), h = max(8, Int(CGFloat(image.height) * k))
        guard let ctx = InkDraw.context(w, h), let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var m = [UInt8](repeating: 0, count: w * h)
        // Ink = clearly darker than the paper (adaptive to the picture's own brightness).
        var lum = [Int](repeating: 0, count: w * h)
        for i in 0..<(w * h) { lum[i] = (Int(data[i * 4]) * 3 + Int(data[i * 4 + 1]) * 6 + Int(data[i * 4 + 2])) / 10 }
        let paper = lum.sorted()[Int(Double(lum.count) * 0.6)]
        for i in 0..<(w * h) where lum[i] < paper - 60 { m[i] = 1 }
        let inkArea = m.reduce(0) { $0 + Int($1) }
        thin(&m, w, h)
        let centreLine = max(1, m.reduce(0) { $0 + Int($1) })
        // Short pieces are spurs where lines cross, not strokes (about a line width and a half).
        let width = Double(inkArea) / Double(centreLine)
        let paths = tracePaths(m, w, h).filter { Double($0.count) >= max(8, width * 1.6) }
        guard !paths.isEmpty else { return nil }
        let ys = paths.flatMap { $0.map(\.1) }
        let height = max(1, (ys.max() ?? 1) - (ys.min() ?? 0))
        // Rows in memory run top-down: flip to y up. Order strokes left to right by their start.
        let strokes = paths.map { $0.map { [$0.0, Double(h - 1) - $0.1, -1, -1] } }
            .sorted { ($0.first?[0] ?? 0) < ($1.first?[0] ?? 0) }
        return SignatureSample(strokes: strokes, penWidth: width / height)
    }

    /// Zhang–Suen thinning to one-pixel centre lines.
    private static func thin(_ m: inout [UInt8], _ w: Int, _ h: Int) {
        var changed = true
        var remove: [Int] = []
        while changed {
            changed = false
            for step in 0..<2 {
                remove.removeAll(keepingCapacity: true)
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) where m[row + x] == 1 {
                        let p2 = m[row - w + x], p3 = m[row - w + x + 1], p4 = m[row + x + 1], p5 = m[row + w + x + 1]
                        let p6 = m[row + w + x], p7 = m[row + w + x - 1], p8 = m[row + x - 1], p9 = m[row - w + x - 1]
                        let b = Int(p2) + Int(p3) + Int(p4) + Int(p5) + Int(p6) + Int(p7) + Int(p8) + Int(p9)
                        guard b >= 2, b <= 6 else { continue }
                        let seq = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                        var a = 0
                        for k in 0..<8 where seq[k] == 0 && seq[k + 1] == 1 { a += 1 }
                        guard a == 1 else { continue }
                        if step == 0 { guard p2 * p4 * p6 == 0, p4 * p6 * p8 == 0 else { continue } }
                        else { guard p2 * p4 * p8 == 0, p2 * p6 * p8 == 0 else { continue } }
                        remove.append(row + x)
                    }
                }
                if !remove.isEmpty { changed = true }
                for i in remove { m[i] = 0 }
            }
        }
    }

    /// Walks the centre-line graph into strokes: from the leftmost free end, always continuing in the straightest
    /// direction at crossings (good continuation), until every pixel is used; closed loops are picked up too.
    private static func tracePaths(_ m: [UInt8], _ w: Int, _ h: Int) -> [[(Double, Double)]] {
        var used = [Bool](repeating: false, count: w * h)
        let offsets = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] == 1 }
        func neighbours(_ x: Int, _ y: Int) -> [(Int, Int)] { offsets.compactMap { on(x + $0.0, y + $0.1) ? (x + $0.0, y + $0.1) : nil } }
        var ends: [(Int, Int)] = []
        for y in 0..<h { for x in 0..<w where m[y * w + x] == 1 && neighbours(x, y).count == 1 { ends.append((x, y)) } }
        ends.sort { $0.0 < $1.0 }
        var paths: [[(Int, Int)]] = []
        func walk(from start: (Int, Int)) {
            var path = [start]
            used[start.1 * w + start.0] = true
            var cur = start
            var dir: (Double, Double) = (1, 0)
            while true {
                let free = neighbours(cur.0, cur.1).filter { !used[$0.1 * w + $0.0] }
                guard !free.isEmpty else { break }
                // Prefer the step closest to the current direction (looking back a few pixels).
                let back = path[max(0, path.count - 6)]
                let dx = Double(cur.0 - back.0), dy = Double(cur.1 - back.1), dl = max(1e-6, (dx * dx + dy * dy).squareRoot())
                if path.count > 2 { dir = (dx / dl, dy / dl) }
                let next = free.max { a, b in
                    let ax = Double(a.0 - cur.0), ay = Double(a.1 - cur.1), bx = Double(b.0 - cur.0), by = Double(b.1 - cur.1)
                    return (ax * dir.0 + ay * dir.1) / (ax * ax + ay * ay).squareRoot() < (bx * dir.0 + by * dir.1) / (bx * bx + by * by).squareRoot()
                }!
                used[next.1 * w + next.0] = true
                path.append(next)
                cur = next
            }
            if path.count > 1 { paths.append(path) }
        }
        for e in ends where !used[e.1 * w + e.0] { walk(from: e) }
        // Closed loops (an "o" with no free end).
        for y in 0..<h { for x in 0..<w where m[y * w + x] == 1 && !used[y * w + x] { walk(from: (x, y)) } }
        // Smooth pixel steps a little (5-point average) so via-points follow the line, not the pixel grid.
        return paths.map { p in
            p.indices.map { i in
                let r = max(0, i - 2)...min(p.count - 1, i + 2)
                let n = Double(r.count)
                return (Double(p[r].reduce(0) { $0 + $1.0 }) / n, Double(p[r].reduce(0) { $0 + $1.1 }) / n)
            }
        }
    }
}
