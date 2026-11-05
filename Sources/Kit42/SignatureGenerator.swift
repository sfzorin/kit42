import AppKit

/// How much of the name a signature shows.
public enum SignatureForm: Int, CaseIterable {
    case any, fullName, initialSurname, surname, initialsScribble, capitalScribble

    public var title: String {
        switch self {
        case .any: return L("Any form")
        case .fullName: return L("Full name")
        case .initialSurname: return L("Initial and surname")
        case .surname: return L("Surname")
        case .initialsScribble: return L("Initials and scribble")
        case .capitalScribble: return L("Capital and scribble")
        }
    }

    fileprivate var archetypes: [SignatureGenerator.Archetype] {
        switch self {
        case .any: return SignatureGenerator.Archetype.allCases
        case .fullName: return [.full, .fullFading]
        case .initialSurname: return [.initialSurname, .initialSurnameFading, .enclosed]
        case .surname: return [.surname, .surnameFading]
        case .initialsScribble: return [.initialsScribble, .monogram]
        case .capitalScribble: return [.capitalScribble]
        }
    }
}

/// Signatures written with a ballpoint pen by a kinematic model of the hand (no fonts).
///
/// Letters are hand-drawn centre lines (`PenAlphabet`): the pen moves through their via-points on a smooth spline.
/// Speed along the path sets the line: fast parts are slightly thinner and lighter, and every stroke starts and ends
/// thin and faint because the pen lands and lifts while moving — which is what makes a signature look confident.
///
/// A **style** (240 of them) combines a plan (what is written: full name, initial and surname, surname, initials and a
/// scribble, a monogram…), a flourish and how the initial joins the surname; the **design** seed also fixes slant,
/// proportions, garland or arcade, loops and rhythm. The **impression** seed varies each copy: via-points (±2.5 % of
/// the capital), size, slant, angle, pressure, ink shade, skips and touch-down blobs.
public enum SignatureGenerator {
    enum Archetype: Int, CaseIterable {
        case full, fullFading, initialSurname, initialSurnameFading, surname, surnameFading,
             initialsScribble, capitalScribble, monogram, enclosed
    }

    private static let flourishes = 11, joins = 3, capitalVariants = 4
    public static var styleCount: Int { Archetype.allCases.count * flourishes * joins * capitalVariants }

    private static func styleIndex(_ a: Archetype, flourish: Int, join: Int, capital: Int) -> Int {
        ((a.rawValue * flourishes + flourish) * capitalVariants + capital) * joins + join
    }

    /// Design seeds for `count` styles of the form, with different plans where possible.
    public static func designSeeds(_ count: Int, form: SignatureForm) -> [UInt64] {
        var plans = form.archetypes.shuffled()
        while plans.count < count { plans += form.archetypes.shuffled() }
        return plans.prefix(count).map { a in
            let style = styleIndex(a, flourish: Int.random(in: 0..<flourishes), join: Int.random(in: 0..<joins),
                                   capital: Int.random(in: 0..<capitalVariants))
            return (UInt64.random(in: 1...(UInt64.max >> 16)) << 16) | UInt64(style)
        }
    }

    /// A fixed design seed (sample sheets): the `variant`-th style of the form.
    public static func design(form: SignatureForm, variant: Int, seed: UInt64) -> UInt64 {
        let plans = form.archetypes
        let style = styleIndex(plans[variant % plans.count], flourish: (variant * 7 + 3) % flourishes, join: variant % joins,
                               capital: (variant / 2) % capitalVariants)
        return (seed << 16) | UInt64(style)
    }

    /// Style number (1-based) of a design seed.
    public static func styleNumber(_ design: UInt64) -> Int { Int(design & 0xFFFF) % styleCount + 1 }

    // MARK: - Plan

    private struct Style {
        var archetype: Archetype
        var flourish: Int      // 0 none, 1 underline →, 2 return under ←, 3 rising tail, 4 loop around capital,
                               // 5 strike through capital, 6 double dash, 7 spiral end
        var join: Int          // 0 initial joined, 1 pen lifted, 2 initial with a dot
        var capital: Int       // 0 as drawn, 1 lead-in loop, 2 simplified (fast), 3 tall
        var slant: CGFloat, xh: CGFloat, initialScale: CGFloat, capW: CGFloat, letterW: CGFloat
        var decay: CGFloat, legibleDecay: CGFloat, garland: Bool, loops: Bool, rise: CGFloat
        var entry: Bool, exitLength: CGFloat, exitLift: CGFloat, pen: CGFloat, keep: Int, legible: Int
        var waveH: [CGFloat], waveW: [CGFloat]
    }

    private static func style(_ design: UInt64) -> Style {
        let index = Int(design & 0xFFFF) % styleCount
        var r = SeededRandom(design >> 16)
        let arche = Archetype(rawValue: index / (flourishes * joins * capitalVariants)) ?? .surname
        var s = Style(archetype: arche, flourish: (index / (joins * capitalVariants)) % flourishes, join: index % joins,
                      capital: (index / joins) % capitalVariants,
                      slant: r.range(0.12...0.6), xh: r.range(0.26...0.46), initialScale: r.range(0.7...1.0),
                      capW: r.range(0.6...1.0), letterW: r.range(0.95...1.4), decay: r.range(0.62...0.9),
                      legibleDecay: r.range(0.9...1.0), garland: r.chance(0.5), loops: r.chance(0.6),
                      rise: r.range(-0.03...0.09), entry: r.chance(0.35), exitLength: r.range(0.15...0.6),
                      exitLift: r.range(-0.2...0.9), pen: r.range(0.018...0.026), keep: Int(r.range(3...7.9)),
                      legible: Int(r.range(1...3.9)),
                      waveH: (0..<12).map { _ in r.range(0.75...1.25) }, waveW: (0..<12).map { _ in r.range(0.8...1.25) })
        if arche == .monogram, s.flourish == 0 { s.flourish = 4 }
        if arche == .enclosed { s.flourish = 99 }   // loop around the whole signature
        return s
    }

    /// The pen paths (cap-height units) for a name in a style.
    /// `copy` varies this written copy: each letter shifts and scales a little as a whole, loops and flourishes
    /// change shape — the way one person's signatures differ from each other.
    private static func plan(_ words: [String], _ s: Style, _ copy: inout SeededRandom) -> [[CGPoint]] {
        let surname = words.last!, given = words.dropLast()
        var strokes: [[CGPoint]] = []
        var current: [CGPoint] = []
        var x: CGFloat = 0
        var capitalBox = CGRect.null
        func baseline(_ x: CGFloat) -> CGFloat { s.rise * x }

        func capital(_ c: Character, scale baseScale: CGFloat) {
            var parts = PenAlphabet.capital(c)
            switch s.capital {
            case 2:   // written fast: interior via-points thinned out
                parts = parts.map { p in p.count > 4 ? p.enumerated().filter { $0.offset == 0 || $0.offset == p.count - 1 || $0.offset % 2 == 1 }.map(\.element) : p }
            case 3:   // tall upper strokes
                parts = parts.map { $0.map { CGPoint(x: $0.x * 1.08, y: $0.y > 0.55 ? 0.55 + ($0.y - 0.55) * 1.35 : $0.y) } }
            default: break
            }
            let scale = baseScale * copy.range(0.93...1.07)
            let width = s.capW * scale * copy.range(0.94...1.06)
            let dx = copy.range(-0.04...0.04), dy = copy.range(-0.04...0.04)
            for (i, part) in parts.enumerated() {
                var pts = part.map { CGPoint(x: x + dx + $0.x * width, y: baseline(x) + dy + $0.y * scale) }
                if i == 0, s.capital == 1, let first = pts.first, current.isEmpty {
                    // Lead-in loop under the start of the capital.
                    pts.insert(contentsOf: [CGPoint(x: first.x - 0.22 * scale, y: first.y - 0.18 * scale),
                                            CGPoint(x: first.x - 0.02 * scale, y: first.y - 0.3 * scale),
                                            CGPoint(x: first.x + 0.08 * scale, y: first.y - 0.12 * scale)], at: 0)
                }
                if i == 0, s.entry, current.isEmpty { pts.insert(CGPoint(x: x - 0.25 * scale, y: baseline(x) - 0.12 * scale), at: 0) }
                for p in pts { capitalBox = capitalBox.union(CGRect(origin: p, size: .zero)) }
                if i == 0 { current += pts } else { flush(); strokes.append(pts) }
            }
            x += width * 0.95
        }
        func flush() { if current.count > 1 { strokes.append(current) }; current = [] }
        func lower(_ c: Character, amp: CGFloat) {
            guard let (w, pts) = PenAlphabet.lower(c) else { wave(0, amp: amp); return }
            let width = w * s.xh * s.letterW * copy.range(0.88...1.12)
            let a = amp * copy.range(0.9...1.1), dy = copy.range(-0.025...0.025)
            current += pts.map { CGPoint(x: x + $0.x * width, y: baseline(x) + dy + $0.y * s.xh * a) }
            x += width
        }
        func wave(_ i: Int, amp: CGFloat, tall: Bool = false) {
            let width = s.xh * s.letterW * 0.9 * s.waveW[i % 12] * copy.range(0.86...1.14)
            let h = s.xh * amp * s.waveH[i % 12] * (tall && s.loops ? 2.0 : 1) * copy.range(0.82...1.18)
            let b = baseline(x)
            if s.garland {
                current += [CGPoint(x: x + width * 0.3, y: b), CGPoint(x: x + width * 0.75, y: b + h)]
                if tall, s.loops { current.append(CGPoint(x: x + width * 0.55, y: b + h * 0.8)) }
            } else {
                current += [CGPoint(x: x + width * 0.3, y: b + h)]
                if tall, s.loops { current.append(CGPoint(x: x + width * 0.12, y: b + h * 0.8)) }
                current.append(CGPoint(x: x + width * 0.75, y: b))
            }
            x += width
        }
        /// Word: capital, `legible` letters written out, the rest as a fading garland (or all legible).
        func word(_ w: String, legible: Int?, garlandCount: Int? = nil) {
            capital(w.first!, scale: 1)
            let rest = Array(w.dropFirst())
            var amp: CGFloat = 1
            let n = legible ?? rest.count
            for c in rest.prefix(n) { lower(c, amp: amp); amp *= s.legibleDecay }
            let remaining = Array(rest.dropFirst(n))
            let garland = garlandCount ?? min(remaining.count, s.keep)
            for i in 0..<garland {
                let c = i < remaining.count ? remaining[i] : "n"
                wave(i, amp: amp, tall: PenAlphabet.isTall(c))
                amp *= s.decay
            }
        }
        func initials(_ letters: [Character], scale: CGFloat) {
            for c in letters {
                capital(c, scale: scale)
                if s.join == 1 { flush() }
                if s.join == 2 { flush(); strokes.append(dot(at: CGPoint(x: x + 0.04, y: baseline(x) + 0.03))); x += 0.12 }
                x += s.join == 0 ? 0.02 : 0.1
            }
        }
        func exit() {
            let length = s.exitLength * copy.range(0.7...1.3)
            current.append(CGPoint(x: x + length, y: baseline(x) + s.xh * (s.exitLift + copy.range(-0.3...0.3))))
            x += length
        }
        let givenInitials = given.compactMap(\.first)

        switch s.archetype {
        case .full:
            for g in given { word(g, legible: nil); flush(); x += 0.22 }
            word(surname, legible: nil); exit()
        case .fullFading:
            for g in given { word(g, legible: nil); if s.join == 1 { flush() }; x += 0.18 }
            word(surname, legible: s.legible + 1); exit()
        case .initialSurname:
            initials(Array(givenInitials.prefix(2)), scale: s.initialScale); word(surname, legible: nil); exit()
        case .initialSurnameFading, .enclosed:
            initials(Array(givenInitials.prefix(2)), scale: s.initialScale); word(surname, legible: s.legible); exit()
        case .surname:
            word(surname, legible: nil); exit()
        case .surnameFading:
            word(surname, legible: s.legible); exit()
        case .initialsScribble:
            initials(Array(givenInitials.prefix(1)), scale: s.initialScale)
            word(surname, legible: 0, garlandCount: max(3, s.keep)); exit()
        case .capitalScribble:
            word(surname, legible: 0, garlandCount: max(3, s.keep)); exit()
        case .monogram:
            for c in givenInitials.prefix(1) { capital(c, scale: 1.15); x -= s.capW * 0.45 }
            capital(surname.first!, scale: 1.05); exit()
        }
        flush()

        // Flourish, from the extent of what was written; its control points move more than the letters.
        func v(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + copy.range(-0.09...0.09), y: p.y + copy.range(-0.06...0.06)) }
        let flourishStart = strokes.count
        let mainEnd = strokes.last?.count ?? 0
        let all = strokes.flatMap { $0 }
        let left = all.map(\.x).min() ?? 0, right = all.map(\.x).max() ?? x
        let low = all.map(\.y).min() ?? 0, mid = (left + right) / 2
        let end = strokes.last?.last ?? CGPoint(x: right, y: 0)
        switch s.flourish {
        case 1:
            strokes.append([CGPoint(x: left - 0.15, y: low - 0.05), CGPoint(x: mid, y: low - 0.28), CGPoint(x: right + 0.35, y: low + 0.1)])
        case 2:
            strokes[strokes.count - 1] += [CGPoint(x: end.x + 0.25, y: low - 0.05), CGPoint(x: mid, y: low - 0.32), CGPoint(x: left - 0.3, y: low - 0.12)]
        case 3:
            strokes[strokes.count - 1] += [CGPoint(x: end.x + 0.3, y: end.y + 0.5), CGPoint(x: end.x + 0.4, y: end.y + 1.0)]
        case 4 where !capitalBox.isNull:
            let c = CGPoint(x: capitalBox.midX, y: capitalBox.midY), rx = capitalBox.width * 0.8 + 0.1, ry = capitalBox.height * 0.65
            strokes.append((0...14).map { i in
                let a = 0.9 + CGFloat(i) / 14 * 1.8 * .pi
                return CGPoint(x: c.x + rx * cos(a) + CGFloat(i) * 0.02, y: c.y + ry * sin(a))
            })
        case 5 where !capitalBox.isNull:
            strokes.append([CGPoint(x: capitalBox.minX - 0.25, y: capitalBox.midY - 0.05), CGPoint(x: (capitalBox.maxX + right) / 2, y: capitalBox.midY + 0.25),
                            CGPoint(x: right + 0.1, y: capitalBox.midY + 0.2)])
        case 6:
            for k in 0..<2 {
                let y = low - 0.12 - CGFloat(k) * 0.12, x0 = mid + CGFloat(k) * 0.1
                strokes.append([CGPoint(x: x0, y: y), CGPoint(x: x0 + 0.35, y: y - 0.02), CGPoint(x: x0 + 0.7, y: y + 0.04)])
            }
        case 7:
            let r: CGFloat = 0.18
            strokes[strokes.count - 1] += (1...10).map { i in
                let a = CGFloat(i) / 10 * 2.2 * .pi
                return CGPoint(x: end.x + r + r * cos(.pi + a) * (1 - CGFloat(i) * 0.05), y: end.y + r * sin(.pi + a))
            }
        case 8:   // big swoop under everything, from below the capital, rising at the end
            strokes.append([CGPoint(x: left + 0.1, y: low + 0.25), CGPoint(x: left - 0.1, y: low - 0.15), CGPoint(x: mid, y: low - 0.32),
                            CGPoint(x: right, y: low - 0.1), CGPoint(x: right + 0.3, y: low + 0.45)])
        case 9:   // zigzag finish
            strokes[strokes.count - 1] += (1...4).map { k in
                CGPoint(x: end.x + CGFloat(k) * 0.13, y: end.y + (k % 2 == 0 ? 0.0 : 0.3) * (1 - CGFloat(k) * 0.15))
            }
        case 10:  // hook up and back over the name
            strokes[strokes.count - 1] += [CGPoint(x: end.x + 0.2, y: end.y + 0.55), CGPoint(x: end.x - 0.1, y: end.y + 0.95),
                                           CGPoint(x: mid, y: end.y + 0.9)]
        case 99:  // loop around everything, starting from the end
            let cx = mid, cy = (all.map(\.y).max()! + low) / 2, rx = (right - left) / 2 + 0.25, ry = (all.map(\.y).max()! - low) / 2 + 0.2
            strokes[strokes.count - 1] += (0...16).map { i in
                let a = -0.3 - CGFloat(i) / 16 * 1.9 * .pi
                return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            }
        default:
            break
        }
        // Copy variation of the flourish: new strokes and the points appended to the last written stroke.
        for i in strokes.indices where i >= flourishStart { strokes[i] = strokes[i].map(v) }
        if flourishStart > 0, strokes[flourishStart - 1].count > mainEnd {
            let k = flourishStart - 1
            strokes[k] = Array(strokes[k].prefix(mainEnd)) + strokes[k].dropFirst(mainEnd).map(v)
        }
        return strokes
    }

    private static func dot(at p: CGPoint) -> [CGPoint] {
        [p, CGPoint(x: p.x + 0.02, y: p.y + 0.015), CGPoint(x: p.x + 0.035, y: p.y)]
    }

    // MARK: - Rendering

    /// Renders one copy. `pixelHeight` is the capital height in pixels.
    public static func render(_ name: String, design: UInt64, impression: UInt64, ink: NSColor, pixelHeight: CGFloat = 130) -> CGImage? {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return nil }
        let s = style(design)
        var copy = SeededRandom(impression)

        // Fast writing does not stop at corners: repeated (corner) points are merged, so the pen sweeps through
        // every turn. This copy moves the via-points a little, size, slant and angle.
        // Natural variation is smooth: a low-frequency drift of the whole hand plus tiny point noise — never
        // independent jumps of single points, which read as a shaky, slow hand.
        let jitter: CGFloat = 0.008
        let driftA = copy.range(0.02...0.045), driftX = copy.range(1.1...2.2), driftY = copy.range(0.9...1.8)
        let driftP1 = copy.range(0...6.28), driftP2 = copy.range(0...6.28)
        let raw = plan(words, s, &copy)
        let strokes = raw.map { stroke -> [CGPoint] in
            var out: [CGPoint] = []
            for p in stroke where out.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.012 }) ?? true {
                out.append(p)
            }
            return out.map { p in
                CGPoint(x: p.x + driftA * sin(p.y / driftY * 2 * .pi + driftP1) + copy.range(-jitter...jitter),
                        y: p.y + driftA * sin(p.x / driftX * 2 * .pi + driftP2) + copy.range(-jitter...jitter))
            }
        }
        let size = pixelHeight * copy.range(0.93...1.07)
        let slant = s.slant + copy.range(-0.08...0.08), angle = copy.range(-0.06...0.06)
        let xStretch = copy.range(0.94...1.06)
        let ca = cos(angle), sa = sin(angle)
        let pen = max(2, size * s.pen * copy.range(0.95...1.05))
        let paths = strokes.map { splineThrough($0) }.map { $0.map { p -> CGPoint in
            let q = CGPoint(x: (p.x + p.y * slant) * size * xStretch, y: p.y * size)
            return CGPoint(x: q.x * ca - q.y * sa, y: q.x * sa + q.y * ca)
        } }.map { fastHand($0, smoothing: max(pen * 3, size * 0.03)) }.filter { $0.count > 2 }
        guard !paths.isEmpty else { return nil }

        let all = paths.flatMap { $0 }
        let minX = all.map(\.x).min()! - pen * 4, maxX = all.map(\.x).max()! + pen * 4
        let minY = all.map(\.y).min()! - pen * 4, maxY = all.map(\.y).max()! + pen * 4
        let w = Int((maxX - minX).rounded(.up)), h = Int((maxY - minY).rounded(.up))
        guard w > 0, h > 0, w < 6000, h < 4000, let out = InkDraw.context(w, h) else { return nil }
        let shade = shift(ink, &copy)

        for path in paths {
            let pts = path.map { CGPoint(x: $0.x - minX, y: $0.y - minY) }
            // Speed from curvature (two-thirds power law: v ∝ curvature^(−1/3)), smoothed; the samples are evenly
            // spaced along the path. Fast parts are thinner and lighter, tight turns slightly heavier.
            let n = pts.count
            var curvature = [CGFloat](repeating: 0, count: n)
            // Curvature over a few pen widths: neighbouring pixels give numerical noise that makes the line flicker.
            let span = max(3, Int(size * 0.04))
            for i in 0..<n {
                let a = pts[max(0, i - span)], b = pts[i], c = pts[min(n - 1, i + span)]
                let ab = hypot(b.x - a.x, b.y - a.y), bc = hypot(c.x - b.x, c.y - b.y), ac = hypot(c.x - a.x, c.y - a.y)
                let cross = abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))
                curvature[i] = ab * bc * ac > 0 ? 2 * cross / (ab * bc * ac) : 0
            }
            let raw = curvature.map { pow($0 * pen + 0.002, -1.0 / 3.0) }
            let speed = raw.indices.map { i -> CGFloat in
                let r = max(0, i - span * 2)...min(n - 1, i + span * 2)
                return raw[r].reduce(0, +) / CGFloat(r.count)
            }
            let sorted = speed.sorted()
            let lo = sorted[Int(Double(n - 1) * 0.1)], hi = max(lo + 0.001, sorted[Int(Double(n - 1) * 0.9)])
            var width: [CGFloat] = [], alpha: [CGFloat] = []
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n - 1)
                let v = min(1, max(0, (speed[i] - lo) / (hi - lo)))
                // Flying start and finish: the pen lands and lifts while moving.
                let land = min(1, t / 0.06), lift = min(1, (1 - t) / 0.16)
                let touch = min(land, lift)
                width.append(pen * (1.08 - 0.28 * v) * (0.25 + 0.75 * touch))
                alpha.append(1.0 - 0.22 * v - 0.5 * (1 - touch))
            }
            let ribbon = InkDraw.taperedStroke(pts) { t in width[min(width.count - 1, Int((t * CGFloat(width.count - 1)).rounded()))] }
            // Ink density varies along the stroke without darker overlaps: paint inside the ribbon with "copy",
            // so each place takes the value of the last segment covering it, then add the stroke to the page.
            guard let layer = InkDraw.context(w, h) else { continue }
            layer.addPath(ribbon)
            layer.clip()
            layer.setBlendMode(.copy)
            layer.setLineCap(.round)
            layer.setLineWidth(pen * 3)
            for i in 1..<pts.count {
                layer.setStrokeColor(shade.withAlphaComponent(max(0.15, alpha[i])).cgColor)
                layer.move(to: pts[i - 1])
                layer.addLine(to: pts[i])
                layer.strokePath()
            }
            if let image = layer.makeImage() { out.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            // An occasional ink blob where the ball first touched the paper.
            if copy.chance(0.2) {
                let r = pen * copy.range(0.45...0.7)
                out.setFillColor(shade.withAlphaComponent(0.85).cgColor)
                out.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
            }
        }
        guard let image = out.makeImage() else { return nil }
        let texture = InkTexture.Strength(pressure: copy.range(0.06...0.16), gaps: copy.range(0.01...0.035),
                                          bleed: copy.range(0.25...0.4), alongX: copy.range(0.04...0.12))
        return InkDraw.trim(InkTexture.apply(image, seed: copy.next(), strength: texture))
    }

    /// The hand at speed: even spacing along the path (about one pixel), a short straight run-out where the pen
    /// lifts, and a low-pass filter over a few pen widths — fast movements carry no small wobbles.
    private static func fastHand(_ path: [CGPoint], smoothing: CGFloat) -> [CGPoint] {
        guard path.count > 2 else { return path }
        var p = path
        let a = p[p.count - 2], b = p[p.count - 1], d = max(0.001, hypot(b.x - a.x, b.y - a.y))
        p.append(CGPoint(x: b.x + (b.x - a.x) / d * smoothing * 3, y: b.y + (b.y - a.y) / d * smoothing * 3))
        var even: [CGPoint] = [p[0]]
        var carry: CGFloat = 0
        for i in 1..<p.count {
            let s = p[i - 1], e = p[i], len = hypot(e.x - s.x, e.y - s.y)
            var t = 1 - carry
            while t <= len {
                even.append(CGPoint(x: s.x + (e.x - s.x) * t / len, y: s.y + (e.y - s.y) * t / len))
                t += 1
            }
            carry = len - (t - 1)
        }
        even.append(p.last!)
        let k = max(1, Int(smoothing))
        for _ in 0..<2 {
            let src = even
            even = src.indices.map { i in
                let r = max(0, i - k)...min(src.count - 1, i + k)
                let w = CGFloat(r.count)
                return CGPoint(x: src[r].reduce(0) { $0 + $1.x } / w, y: src[r].reduce(0) { $0 + $1.y } / w)
            }
        }
        return even
    }

    /// Centripetal Catmull-Rom spline through the via-points (no overshoot loops between uneven points).
    private static func splineThrough(_ p: [CGPoint], steps: Int = 22) -> [CGPoint] {
        guard p.count > 2 else { return p }
        var out: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            if p1 == p2 { continue }
            func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(1e-4, pow(hypot(b.x - a.x, b.y - a.y), 0.5)) }
            let t1 = knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
            for k in 0..<steps {
                let t = t1 + (t2 - t1) * CGFloat(k) / CGFloat(steps)
                func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
                    let u = tb - ta < 1e-6 ? 0 : (t - ta) / (tb - ta)
                    return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
                }
                let a1 = lerp(p0, p1, 0, t1), a2 = lerp(p1, p2, t1, t2), a3 = lerp(p2, p3, t2, t3)
                let b1 = lerp(a1, a2, 0, t2), b2 = lerp(a2, a3, t1, t3)
                out.append(lerp(b1, b2, t1, t2))
            }
        }
        out.append(p.last!)
        return out
    }

    /// The ink colour, nudged in brightness, saturation and hue for this copy.
    private static func shift(_ color: NSColor, _ copy: inout SeededRandom) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: (h + copy.range(-0.01...0.01) + 1).truncatingRemainder(dividingBy: 1),
                       saturation: min(1, max(0, s * copy.range(0.92...1.08))),
                       brightness: min(1, max(0, b + copy.range(-0.05...0.05))), alpha: a)
    }
}
