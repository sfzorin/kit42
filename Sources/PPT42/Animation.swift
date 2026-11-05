import AppKit
import Kit42

// Object animations: entrance, exit, emphasis and motion paths with their order and timing (p:timing, anim:*).

enum AnimClass: String, CaseIterable { case entrance, exit, emphasis, motion }

enum AnimEffect: String, CaseIterable {
    case appear, fade, flyIn, zoom, wipe
    case disappear, fadeOut, flyOut, zoomOut
    case pulse, spin, grow, colorChange
    case path

    var cls: AnimClass {
        switch self {
        case .appear, .fade, .flyIn, .zoom, .wipe: return .entrance
        case .disappear, .fadeOut, .flyOut, .zoomOut: return .exit
        case .pulse, .spin, .grow, .colorChange: return .emphasis
        case .path: return .motion
        }
    }

    var name: String {
        switch self {
        case .appear: return L("Appear")
        case .fade: return L("Fade In")
        case .flyIn: return L("Fly In")
        case .zoom: return L("Zoom")
        case .wipe: return L("Wipe")
        case .disappear: return L("Disappear")
        case .fadeOut: return L("Fade Out")
        case .flyOut: return L("Fly Out")
        case .zoomOut: return L("Zoom Out")
        case .pulse: return L("Pulse")
        case .spin: return L("Spin")
        case .grow: return L("Grow/Shrink")
        case .colorChange: return L("Change Colour")
        case .path: return L("Motion Path")
        }
    }

    static func of(_ c: AnimClass) -> [AnimEffect] { allCases.filter { $0.cls == c } }
}

enum AnimTrigger: String, CaseIterable {
    case onClick, withPrevious, afterPrevious

    var name: String {
        switch self {
        case .onClick: return L("On Click")
        case .withPrevious: return L("With Previous")
        case .afterPrevious: return L("After Previous")
        }
    }
}

struct Animation: Equatable {
    var id = UUID()
    var target: Int
    var effect: AnimEffect
    var trigger: AnimTrigger = .onClick
    var delay: Double = 0
    var duration: Double = 0.5
    /// Fly in/out: where from or to — b, t, l, r.
    var direction = "b"
    /// Spin: degrees; grow/shrink: scale.
    var amount: Double = 0
    var color: PColor?
    /// Motion path: points relative to the object's position, in fractions of the slide size (OOXML), starting at (0, 0).
    var path: [CGPoint] = []

    init(target: Int, effect: AnimEffect, trigger: AnimTrigger = .onClick) {
        self.target = target
        self.effect = effect
        self.trigger = trigger
        if effect == .appear || effect == .disappear { duration = 0.001 }
        if effect == .spin { amount = 360; duration = 2 }
        if effect == .grow { amount = 1.5; duration = 1 }
        if effect == .pulse { duration = 0.5 }
        if effect == .colorChange { color = PColor(scheme: "accent2"); duration = 1 }
        if effect == .path { path = [.zero, CGPoint(x: 0.25, y: 0)]; duration = 2 }
    }

    /// Direction presets of straight motion paths.
    static func linePath(_ dir: String) -> [CGPoint] {
        switch dir {
        case "l": return [.zero, CGPoint(x: -0.25, y: 0)]
        case "t": return [.zero, CGPoint(x: 0, y: -0.25)]
        case "b": return [.zero, CGPoint(x: 0, y: 0.25)]
        default: return [.zero, CGPoint(x: 0.25, y: 0)]
        }
    }

    var describe: String { "\(effect.rawValue)/\(trigger.rawValue) \(String(format: "%.2f", duration))s" + (delay > 0 ? " +\(String(format: "%.2f", delay))s" : "") }
}

/// The animations of a slide grouped by click, with start times.
struct AnimationTimeline {
    struct Item { let anim: Animation; let start: Double }
    struct Group {
        var items: [Item]
        /// Plays when the slide appears (the first group starts with "with/after previous").
        var automatic: Bool
        var duration: Double { items.map { $0.start + $0.anim.delay + $0.anim.duration }.max() ?? 0 }
    }
    let groups: [Group]

    init(_ anims: [Animation]) {
        var gs: [Group] = []
        var chainStart = 0.0, chainEnd = 0.0
        for a in anims {
            if a.trigger == .onClick || gs.isEmpty {
                gs.append(Group(items: [], automatic: a.trigger != .onClick && gs.isEmpty))
                chainStart = 0; chainEnd = 0
            }
            var start = chainStart
            if a.trigger == .afterPrevious, !(gs[gs.count - 1].items.isEmpty) { start = chainEnd }
            if a.trigger == .afterPrevious { chainStart = start }
            gs[gs.count - 1].items.append(Item(anim: a, start: start))
            chainEnd = max(chainEnd, start + a.delay + a.duration)
        }
        groups = gs
    }

    /// Number of clicks (automatic first group excluded).
    var clicks: Int { groups.filter { !$0.automatic }.count }
}

extension Slide {
    /// The slide as it looks after `groups` animation groups have played (entrances shown, exits hidden, paths, spins, colours).
    func animated(after groups: Int, size: CGSize) -> Slide {
        var s = self
        guard !animations.isEmpty else { return s }
        let tl = AnimationTimeline(animations)
        var hidden = Set<Int>()
        // Objects whose first animation is an entrance start hidden.
        var seen = Set<Int>()
        for a in animations where !seen.contains(a.target) {
            seen.insert(a.target)
            if a.effect.cls == .entrance { hidden.insert(a.target) }
        }
        for g in tl.groups.prefix(max(0, groups)) {
            for it in g.items {
                let a = it.anim
                switch a.effect.cls {
                case .entrance: hidden.remove(a.target)
                case .exit: hidden.insert(a.target)
                case .emphasis:
                    s.update(a.target) { o in
                        switch a.effect {
                        case .spin: o.rotation = (o.rotation + CGFloat(a.amount)).truncatingRemainder(dividingBy: 360)
                        case .grow:
                            let k = CGFloat(a.amount)
                            o.setFrame(CGRect(x: o.frame.midX - o.frame.width * k / 2, y: o.frame.midY - o.frame.height * k / 2, width: o.frame.width * k, height: o.frame.height * k))
                        case .colorChange: if let c = a.color, o.kind != .line { o.fill = .solid(c) } else if let c = a.color { o.line.color = c }
                        default: break
                        }
                    }
                case .motion:
                    if let end = a.path.last {
                        s.update(a.target) { $0.offset(by: CGSize(width: end.x * size.width, height: end.y * size.height)) }
                    }
                }
            }
        }
        s.objects.removeAll { hidden.contains($0.id) }
        return s
    }

    func animations(of id: Int) -> [Animation] { animations.filter { $0.target == id } }
}

// MARK: - PresentationML (p:timing)

enum TimingXML {
    static func ms(_ s: Double) -> Int { max(1, Int((s * 1000).rounded())) }

    static func presetID(_ e: AnimEffect, direction: String) -> (Int, Int) {
        let flySub = ["b": 4, "t": 1, "l": 8, "r": 2][direction] ?? 4
        switch e {
        case .appear, .disappear: return (1, 0)
        case .flyIn, .flyOut: return (2, flySub)
        case .fade, .fadeOut: return (10, 0)
        case .zoom, .zoomOut: return (53, 16)
        case .wipe: return (22, ["b": 4, "t": 1, "l": 8, "r": 2][direction] ?? 4)
        case .pulse: return (26, 0)
        case .spin: return (8, 0)
        case .grow: return (6, 0)
        case .colorChange: return (1, 2)
        case .path: return (0, 0)
        }
    }

    /// p:timing for the slide's animations (nil when there are none).
    static func write(_ s: Slide, color: (PColor) -> String) -> String {
        let anims = s.animations.filter { s.object($0.target) != nil }
        guard !anims.isEmpty else { return "" }
        var id = 3
        func next() -> Int { id += 1; return id - 1 }
        let tl = AnimationTimeline(anims)
        var clicks = ""
        for g in tl.groups {
            let outer = next()
            let cond = g.automatic ? "<p:cond delay=\"indefinite\"/><p:cond evt=\"onBegin\" delay=\"0\"><p:tn val=\"2\"/></p:cond>" : "<p:cond delay=\"indefinite\"/>"
            clicks += "<p:par><p:cTn id=\"\(outer)\" fill=\"hold\"><p:stCondLst>\(cond)</p:stCondLst><p:childTnLst>"
            // Chains of effects starting together.
            var chains: [(Double, [AnimationTimeline.Item])] = []
            for it in g.items {
                if let last = chains.last, last.0 == it.start { chains[chains.count - 1].1.append(it) } else { chains.append((it.start, [it])) }
            }
            for (start, items) in chains {
                clicks += "<p:par><p:cTn id=\"\(next())\" fill=\"hold\"><p:stCondLst><p:cond delay=\"\(Int(start * 1000))\"/></p:stCondLst><p:childTnLst>"
                for it in items { clicks += effect(it.anim, next: next, color: color) }
                clicks += "</p:childTnLst></p:cTn></p:par>"
            }
            clicks += "</p:childTnLst></p:cTn></p:par>"
        }
        var x = "<p:timing><p:tnLst><p:par><p:cTn id=\"1\" dur=\"indefinite\" restart=\"never\" nodeType=\"tmRoot\"><p:childTnLst>"
        x += "<p:seq concurrent=\"1\" nextAc=\"seek\"><p:cTn id=\"2\" dur=\"indefinite\" nodeType=\"mainSeq\"><p:childTnLst>\(clicks)</p:childTnLst></p:cTn>"
        x += "<p:prevCondLst><p:cond evt=\"onPrev\" delay=\"0\"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst><p:nextCondLst><p:cond evt=\"onNext\" delay=\"0\"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:nextCondLst></p:seq>"
        x += "</p:childTnLst></p:cTn></p:par></p:tnLst>"
        var ids: [Int] = []
        for a in anims where !ids.contains(a.target) { ids.append(a.target) }
        let blds = ids.compactMap { s.object($0) }.filter { $0.text != nil && ($0.kind == .shape || $0.kind == .textBox) }.map { "<p:bldP spid=\"\($0.id)\" grpId=\"0\" animBg=\"1\"/>" }.joined()
        if !blds.isEmpty { x += "<p:bldLst>\(blds)</p:bldLst>" }
        return x + "</p:timing>"
    }

    static func effect(_ a: Animation, next: () -> Int, color: (PColor) -> String) -> String {
        let spid = a.target
        let d = ms(a.duration)
        let (pid, sub) = presetID(a.effect, direction: a.direction)
        let cls = ["entrance": "entr", "exit": "exit", "emphasis": "emph", "motion": "path"][a.effect.cls.rawValue] ?? "entr"
        let node = ["onClick": "clickEffect", "withPrevious": "withEffect", "afterPrevious": "afterEffect"][a.trigger.rawValue] ?? "clickEffect"
        let tgt = "<p:tgtEl><p:spTgt spid=\"\(spid)\"/></p:tgtEl>"
        func set(_ value: String, delay: Int = 0) -> String {
            "<p:set><p:cBhvr><p:cTn id=\"\(next())\" dur=\"1\" fill=\"hold\"><p:stCondLst><p:cond delay=\"\(delay)\"/></p:stCondLst></p:cTn>\(tgt)<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val=\"\(value)\"/></p:to></p:set>"
        }
        func anim(_ attr: String, _ from: String, _ to: String) -> String {
            "<p:anim calcmode=\"lin\" valueType=\"num\"><p:cBhvr additive=\"base\"><p:cTn id=\"\(next())\" dur=\"\(d)\" fill=\"hold\"/>\(tgt)<p:attrNameLst><p:attrName>\(attr)</p:attrName></p:attrNameLst></p:cBhvr><p:tavLst><p:tav tm=\"0\"><p:val><p:strVal val=\"\(from)\"/></p:val></p:tav><p:tav tm=\"100000\"><p:val><p:strVal val=\"\(to)\"/></p:val></p:tav></p:tavLst></p:anim>"
        }
        func filter(_ f: String, _ dir: String) -> String {
            "<p:animEffect transition=\"\(dir)\" filter=\"\(f)\"><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(d)\"/>\(tgt)</p:cBhvr></p:animEffect>"
        }
        let off: (String, String) = {
            switch a.direction {
            case "t": return ("#ppt_x", "0-#ppt_h/2")
            case "l": return ("0-#ppt_w/2", "#ppt_y")
            case "r": return ("1+#ppt_w/2", "#ppt_y")
            default: return ("#ppt_x", "1+#ppt_h/2")
            }
        }()
        var b = ""
        switch a.effect {
        case .appear: b = set("visible")
        case .fade: b = set("visible") + filter("fade", "in")
        case .flyIn: b = set("visible") + anim("ppt_x", off.0, "#ppt_x") + anim("ppt_y", off.1, "#ppt_y")
        case .zoom: b = set("visible") + anim("ppt_w", "0", "#ppt_w") + anim("ppt_h", "0", "#ppt_h") + filter("fade", "in")
        case .wipe: b = set("visible") + filter("wipe(\(["t": "up", "l": "left", "r": "right"][a.direction] ?? "down"))", "in")
        case .disappear: b = set("hidden")
        case .fadeOut: b = filter("fade", "out") + set("hidden", delay: max(0, d - 1))
        case .flyOut: b = anim("ppt_x", "#ppt_x", off.0) + anim("ppt_y", "#ppt_y", off.1) + set("hidden", delay: max(0, d - 1))
        case .zoomOut: b = anim("ppt_w", "#ppt_w", "0") + anim("ppt_h", "#ppt_h", "0") + filter("fade", "out") + set("hidden", delay: max(0, d - 1))
        case .pulse:
            b = "<p:animScale><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(max(1, d / 2))\" autoRev=\"1\" fill=\"hold\"/>\(tgt)</p:cBhvr><p:by x=\"105000\" y=\"105000\"/></p:animScale>"
        case .spin:
            b = "<p:animRot by=\"\(Int(a.amount * 60000))\"><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(d)\" fill=\"hold\"/>\(tgt)<p:attrNameLst><p:attrName>r</p:attrName></p:attrNameLst></p:cBhvr></p:animRot>"
        case .grow:
            let k = Int(a.amount * 100000)
            b = "<p:animScale><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(d)\" fill=\"hold\"/>\(tgt)</p:cBhvr><p:by x=\"\(k)\" y=\"\(k)\"/></p:animScale>"
        case .colorChange:
            b = "<p:animClr clrSpc=\"rgb\" dir=\"cw\"><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(d)\" fill=\"hold\"/>\(tgt)<p:attrNameLst><p:attrName>fillcolor</p:attrName></p:attrNameLst></p:cBhvr><p:to>\(color(a.color ?? PColor(scheme: "accent2")))</p:to></p:animClr>"
            b += "<p:set><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(d)\" fill=\"hold\"/>\(tgt)<p:attrNameLst><p:attrName>fill.type</p:attrName></p:attrNameLst></p:cBhvr><p:to><p:strVal val=\"solid\"/></p:to></p:set>"
        case .path:
            b = "<p:animMotion origin=\"layout\" path=\"\(pathString(a.path))\" pathEditMode=\"relative\" ptsTypes=\"\"><p:cBhvr><p:cTn id=\"\(next())\" dur=\"\(d)\" fill=\"hold\"/>\(tgt)<p:attrNameLst><p:attrName>ppt_x</p:attrName><p:attrName>ppt_y</p:attrName></p:attrNameLst></p:cBhvr></p:animMotion>"
        }
        var x = "<p:par><p:cTn id=\"\(next())\" presetID=\"\(pid)\" presetClass=\"\(cls)\" presetSubtype=\"\(sub)\""
        x += " fill=\"hold\" grpId=\"0\" nodeType=\"\(node)\"><p:stCondLst><p:cond delay=\"\(Int(a.delay * 1000))\"/></p:stCondLst><p:childTnLst>\(b)</p:childTnLst></p:cTn></p:par>"
        return x
    }

    static func pathString(_ pts: [CGPoint]) -> String {
        guard let f = pts.first else { return "M 0 0 E" }
        func n(_ v: CGFloat) -> String { String(format: "%.5f", Double(v)) }
        return "M \(n(f.x)) \(n(f.y))" + pts.dropFirst().map { " L \(n($0.x)) \(n($0.y))" }.joined() + " E"
    }

    /// Points of an OOXML/SMIL motion path ("M 0 0 L 0.25 0 C … E", relative to the object).
    static func parsePath(_ s: String) -> [CGPoint] {
        var nums: [CGFloat] = []
        var pts: [CGPoint] = []
        for t in s.replacingOccurrences(of: ",", with: " ").split(separator: " ") {
            if let v = Double(t) { nums.append(CGFloat(v)); if nums.count == 2 { pts.append(CGPoint(x: nums[0], y: nums[1])); nums = [] } }
            else { nums = [] }
        }
        if pts.first != .zero, !pts.isEmpty { let o = pts[0]; pts = pts.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) } }
        return pts
    }

    static func read(_ timing: XMLElement, color: (XMLElement?) -> PColor?) -> [Animation] {
        guard let main = timing.descendants("cTn").first(where: { $0.a("nodeType") == "mainSeq" }) else { return [] }
        var out: [Animation] = []
        for ctn in main.descendants("cTn") {
            guard let cls = ctn.a("presetClass"), let node = ctn.a("nodeType"), ["clickEffect", "withEffect", "afterEffect"].contains(node) else { continue }
            guard let spid = ctn.descendants("spTgt").first?.int("spid") else { continue }
            let pid = ctn.int("presetID") ?? 1, sub = ctn.int("presetSubtype") ?? 0
            let kids = ctn.child("childTnLst")?.elements ?? []
            let names = Set(kids.compactMap(\.localName))
            var e: AnimEffect
            switch cls {
            case "entr":
                switch pid {
                case 1: e = .appear
                case 2: e = .flyIn
                case 22: e = .wipe
                case 53, 21, 23, 31: e = .zoom
                default: e = .fade
                }
            case "exit":
                switch pid {
                case 1: e = .disappear
                case 2: e = .flyOut
                case 53, 21, 23, 31: e = .zoomOut
                default: e = .fadeOut
                }
            case "emph":
                if names.contains("animRot") { e = .spin }
                else if names.contains("animClr") { e = .colorChange }
                else if names.contains("animScale") { e = kids.first { $0.localName == "animScale" }?.descendants("cTn").first?.bool("autoRev") == true ? .pulse : .grow }
                else { e = .pulse }
            case "path": e = .path
            default: continue
            }
            var a = Animation(target: spid, effect: e, trigger: node == "clickEffect" ? .onClick : node == "withEffect" ? .withPrevious : .afterPrevious)
            a.delay = Double(ctn.child("stCondLst")?.child("cond")?.int("delay") ?? 0) / 1000
            let durs = ctn.descendants("cTn").compactMap { $0.a("dur").flatMap(Int.init) }.filter { $0 > 1 }
            a.duration = durs.max().map { Double($0) / 1000 } ?? (e == .appear || e == .disappear ? 0.001 : 0.5)
            if e == .pulse, let d = durs.max() { a.duration = Double(d) / 500 }
            if e == .flyIn || e == .flyOut || e == .wipe { a.direction = [1: "t", 8: "l", 2: "r", 4: "b"][sub] ?? "b" }
            if e == .spin, let by = kids.first(where: { $0.localName == "animRot" })?.num("by") { a.amount = Double(by) / 60000 }
            if e == .grow, let by = kids.first(where: { $0.localName == "animScale" })?.child("by")?.num("x") { a.amount = Double(by) / 100000 }
            if e == .colorChange, let c = color(kids.first(where: { $0.localName == "animClr" })?.child("to")) { a.color = c }
            if e == .path, let p = kids.first(where: { $0.localName == "animMotion" })?.a("path") { a.path = parsePath(p) }
            out.append(a)
        }
        return out
    }
}

// MARK: - OpenDocument (anim:*)

enum AnimationODF {
    static let presets: [AnimEffect: String] = [
        .appear: "ooo-entrance-appear", .fade: "ooo-entrance-fade-in", .flyIn: "ooo-entrance-fly-in", .zoom: "ooo-entrance-zoom", .wipe: "ooo-entrance-wipe",
        .disappear: "ooo-exit-disappear", .fadeOut: "ooo-exit-fade-out", .flyOut: "ooo-exit-fly-out", .zoomOut: "ooo-exit-zoom",
        .pulse: "ooo-emphasis-pulse", .spin: "ooo-emphasis-spin", .grow: "ooo-emphasis-grow-and-shrink", .colorChange: "ooo-emphasis-fill-color",
        .path: "ooo-motionpath-custom",
    ]

    /// The main sequence (inside the timing root) for the slide's animations. `target` gives the shape's xml:id.
    static func mainSequence(_ s: Slide, target: (Int) -> String, hex: (PColor) -> String) -> String {
        let anims = s.animations.filter { s.object($0.target) != nil }
        guard !anims.isEmpty else { return "" }
        let tl = AnimationTimeline(anims)
        func sec(_ v: Double) -> String { String(format: "%.3fs", max(0.001, v)) }
        var x = "<anim:seq presentation:node-type=\"main-sequence\">"
        for g in tl.groups {
            x += "<anim:par smil:begin=\"\(g.automatic ? "0s" : "next")\">"
            var chains: [(Double, [AnimationTimeline.Item])] = []
            for it in g.items { if let l = chains.last, l.0 == it.start { chains[chains.count - 1].1.append(it) } else { chains.append((it.start, [it])) } }
            for (start, items) in chains {
                x += "<anim:par smil:begin=\"\(String(format: "%.3fs", start))\">"
                for it in items {
                    let a = it.anim, t = target(a.target), d = sec(a.duration)
                    let cls = ["entrance": "entrance", "exit": "exit", "emphasis": "emphasis", "motion": "motion-path"][a.effect.cls.rawValue] ?? "entrance"
                    let node = ["onClick": "on-click", "withPrevious": "with-previous", "afterPrevious": "after-previous"][a.trigger.rawValue] ?? "on-click"
                    let subs = ["b": "from-bottom", "t": "from-top", "l": "from-left", "r": "from-right"]
                    var sub = ""
                    if a.effect == .flyIn || a.effect == .flyOut { sub = " presentation:preset-sub-type=\"\(subs[a.direction] ?? "from-bottom")\"" }
                    x += "<anim:par smil:begin=\"\(String(format: "%.3fs", a.delay))\" smil:fill=\"hold\" presentation:node-type=\"\(node)\" presentation:preset-class=\"\(cls)\" presentation:preset-id=\"\(presets[a.effect] ?? "ooo-entrance-appear")\"\(sub)>"
                    func vis(_ v: String, begin: String = "0s") -> String {
                        "<anim:set smil:begin=\"\(begin)\" smil:dur=\"0.001s\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"visibility\" smil:to=\"\(v)\"/>"
                    }
                    let off: (String, String) = ["t": ("x", "0-height/2"), "l": ("0-width/2", "y"), "r": ("1+width/2", "y")][a.direction] ?? ("x", "1+height/2")
                    func move(_ from: (String, String), _ to: (String, String)) -> String {
                        "<anim:animate smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"x\" smil:values=\"\(from.0);\(to.0)\" smil:keyTimes=\"0;1\" presentation:additive=\"base\"/>"
                            + "<anim:animate smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"y\" smil:values=\"\(from.1);\(to.1)\" smil:keyTimes=\"0;1\" presentation:additive=\"base\"/>"
                    }
                    func size(_ a1: String, _ b1: String) -> String {
                        "<anim:animate smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"width\" smil:values=\"\(a1 == "0" ? "0;width" : "width;0")\" smil:keyTimes=\"0;1\" presentation:additive=\"base\"/>"
                            + "<anim:animate smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"height\" smil:values=\"\(b1 == "0" ? "0;height" : "height;0")\" smil:keyTimes=\"0;1\" presentation:additive=\"base\"/>"
                    }
                    let end = String(format: "%.3fs", max(0, a.duration - 0.001))
                    switch a.effect {
                    case .appear: x += vis("visible")
                    case .fade: x += vis("visible") + "<anim:transitionFilter smil:dur=\"\(d)\" smil:targetElement=\"\(t)\" smil:type=\"fade\" smil:subtype=\"crossfade\"/>"
                    case .flyIn: x += vis("visible") + move(off, ("x", "y"))
                    case .zoom: x += vis("visible") + size("0", "0")
                    case .wipe: x += vis("visible") + "<anim:transitionFilter smil:dur=\"\(d)\" smil:targetElement=\"\(t)\" smil:type=\"barWipe\" smil:subtype=\"\(a.direction == "l" || a.direction == "r" ? "leftToRight" : "topToBottom")\"\(a.direction == "l" || a.direction == "t" ? " smil:direction=\"reverse\"" : "")/>"
                    case .disappear: x += vis("hidden")
                    case .fadeOut: x += "<anim:transitionFilter smil:dur=\"\(d)\" smil:targetElement=\"\(t)\" smil:type=\"fade\" smil:subtype=\"crossfade\" smil:mode=\"out\"/>" + vis("hidden", begin: end)
                    case .flyOut: x += move(("x", "y"), off) + vis("hidden", begin: end)
                    case .zoomOut: x += size("w", "h") + vis("hidden", begin: end)
                    case .pulse: x += "<anim:animateTransform smil:dur=\"\(sec(a.duration / 2))\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:autoReverse=\"true\" svg:type=\"scale\" smil:to=\"1.05,1.05\"/>"
                    case .spin: x += "<anim:animateTransform smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:by=\"\(Int(a.amount))\" svg:type=\"rotate\"/>"
                    case .grow: x += "<anim:animateTransform smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:to=\"\(a.amount),\(a.amount)\" svg:type=\"scale\"/>"
                    case .colorChange:
                        x += "<anim:set smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"fill\" smil:to=\"solid\"/>"
                        x += "<anim:animateColor smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" smil:attributeName=\"fill-color\" smil:to=\"\(hex(a.color ?? PColor(scheme: "accent2")))\" anim:color-interpolation=\"rgb\" anim:color-interpolation-direction=\"clockwise\"/>"
                    case .path: x += "<anim:animateMotion smil:dur=\"\(d)\" smil:fill=\"hold\" smil:targetElement=\"\(t)\" svg:path=\"\(TimingXML.pathString(a.path).replacingOccurrences(of: " E", with: ""))\"/>"
                    }
                    x += "</anim:par>"
                }
                x += "</anim:par>"
            }
            x += "</anim:par>"
        }
        return x + "</anim:seq>"
    }

    static func read(_ timing: XMLElement, ids: [String: Int]) -> [Animation] {
        var out: [Animation] = []
        func secs(_ s: String?) -> Double {
            guard let s else { return 0 }
            if s.hasSuffix("s"), let v = Double(s.dropLast()) { return v }
            return Double(s) ?? 0
        }
        for effect in timing.descendants("par") where effect.a("preset-class") != nil {
            let behaviors = effect.elements
            guard let target = behaviors.compactMap({ $0.a("targetElement") }).first ?? effect.descendants("set").first?.a("targetElement"),
                  let id = ids[target] else { continue }
            let preset = effect.a("preset-id") ?? ""
            let cls = effect.a("preset-class") ?? "entrance"
            var e: AnimEffect
            switch cls {
            case "entrance":
                e = preset.contains("appear") ? .appear : preset.contains("fly") ? .flyIn : preset.contains("zoom") || preset.contains("grow") ? .zoom : preset.contains("wipe") ? .wipe : .fade
            case "exit":
                e = preset.contains("disappear") ? .disappear : preset.contains("fly") ? .flyOut : preset.contains("zoom") || preset.contains("shrink") ? .zoomOut : .fadeOut
            case "emphasis":
                if behaviors.contains(where: { $0.localName == "animateTransform" && $0.a("type") == "rotate" }) { e = .spin }
                else if behaviors.contains(where: { $0.localName == "animateColor" }) { e = .colorChange }
                else if behaviors.contains(where: { $0.localName == "animateTransform" && $0.a("autoReverse") == "true" }) || preset.contains("pulse") { e = .pulse }
                else { e = .grow }
            case "motion-path": e = .path
            default: continue
            }
            let node = effect.a("node-type") ?? "on-click"
            var a = Animation(target: id, effect: e, trigger: node == "with-previous" ? .withPrevious : node == "after-previous" ? .afterPrevious : .onClick)
            a.delay = secs(effect.a("begin"))
            let durs = behaviors.compactMap { $0.a("dur").map(secs) }.filter { $0 > 0.002 }
            if let d = durs.max() { a.duration = e == .pulse ? d * 2 : d }
            let sub = effect.a("preset-sub-type") ?? ""
            a.direction = sub.contains("top") ? "t" : sub.contains("left") ? "l" : sub.contains("right") ? "r" : "b"
            if e == .spin, let by = behaviors.first(where: { $0.a("type") == "rotate" })?.a("by").flatMap(Double.init) { a.amount = by }
            if e == .grow, let to = behaviors.first(where: { $0.localName == "animateTransform" })?.a("to")?.split(separator: ",").first.flatMap({ Double($0) }) { a.amount = to }
            if e == .colorChange, let c = behaviors.first(where: { $0.localName == "animateColor" })?.a("to"), c.hasPrefix("#"), let v = UInt32(c.dropFirst(), radix: 16) { a.color = PColor(rgb: v) }
            if e == .path, let p = behaviors.first(where: { $0.localName == "animateMotion" })?.a("path") { a.path = TimingXML.parsePath(p) }
            out.append(a)
        }
        return out
    }
}
