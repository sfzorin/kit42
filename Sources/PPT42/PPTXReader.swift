import AppKit
import Kit42

enum DeckError: LocalizedError {
    case legacyPPT
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .legacyPPT:
            return L("PowerPoint 97–2003 presentations (.ppt) cannot be opened.")
        case .invalid(let s): return s
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .legacyPPT:
            return L("Save it as .pptx in PowerPoint or Keynote, or convert it with LibreOffice: soffice --headless --convert-to pptx file.ppt")
        case .invalid: return nil
        }
    }
}

// MARK: - XML helpers

extension XMLElement {
    /// Attribute by local name (ignores the prefix: r:embed, r:id…).
    func a(_ name: String) -> String? {
        if let v = attribute(forName: name)?.stringValue { return v }
        return attributes?.first { $0.localName == name }?.stringValue
    }

    func int(_ name: String) -> Int? { a(name).flatMap { Int($0) } }

    /// The r:id attribute (relationship), not a plain id.
    var rid: String? {
        attributes?.first { $0.localName == "id" && ($0.uri == PPTXWriter.nsR || ($0.name ?? "").hasPrefix("r:")) }?.stringValue
    }
    func num(_ name: String) -> CGFloat? { a(name).flatMap { Double($0) }.map { CGFloat($0) } }
    func bool(_ name: String) -> Bool? { a(name).map { $0 == "1" || $0 == "true" } }

    var elements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    /// First descendant by local-name path: `path("spPr", "xfrm", "off")`.
    func path(_ names: String...) -> XMLElement? {
        var cur: XMLElement? = self
        for n in names { cur = cur?.child(n) }
        return cur
    }

    func descendants(_ name: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for e in elements {
            if e.localName == name { out.append(e) }
            out += e.descendants(name)
        }
        return out
    }
}

func xmlRoot(_ data: Data?) -> XMLElement? {
    guard let data else { return nil }
    return try? XMLDocument(data: data, options: [.nodePreserveWhitespace]).rootElement()
}

/// "ppt/slides/slide1.xml" + "../media/image1.png" → "ppt/media/image1.png".
func resolvePart(_ base: String, _ target: String) -> String {
    if target.hasPrefix("/") { return String(target.dropFirst()) }
    var parts = base.split(separator: "/").map(String.init)
    parts.removeLast()
    for c in target.split(separator: "/") {
        if c == ".." { if !parts.isEmpty { parts.removeLast() } } else if c != "." { parts.append(String(c)) }
    }
    return parts.joined(separator: "/")
}

func relsPath(_ part: String) -> String {
    var parts = part.split(separator: "/").map(String.init)
    let name = parts.removeLast()
    return (parts + ["_rels", name + ".rels"]).joined(separator: "/")
}

// MARK: - Reader

struct PPTXReader {
    let zip: ZipArchive
    var deck = Deck()
    /// Line widths of the theme's lnStyleLst (points).
    var themeLineWidths: [CGFloat] = [0.75, 1, 1.5]
    var themeBackgrounds: [Fill] = []
    var themeFills: [Fill] = []
    var themeLines: [LineStyle] = []
    var themeShadows: [Bool] = []
    var mediaByPart: [String: String] = [:]
    var contentTypes: (overrides: [String: String], defaults: [String: String]) = ([:], [:])

    static func read(_ data: Data) throws -> Deck {
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw DeckError.legacyPPT }
        var r = PPTXReader(zip: try ZipArchive(data: data))
        return try r.read()
    }

    init(zip: ZipArchive) { self.zip = zip }

    func rels(_ part: String) -> [String: (target: String, type: String, external: Bool)] {
        guard let root = xmlRoot(zip[relsPath(part)]) else { return [:] }
        var out: [String: (String, String, Bool)] = [:]
        for r in root.children("Relationship") {
            guard let id = r.a("Id"), let t = r.a("Target") else { continue }
            let external = r.a("TargetMode") == "External"
            out[id] = (external ? t : resolvePart(part, t), r.a("Type") ?? "", external)
        }
        return out
    }

    mutating func read() throws -> Deck {
        if let ct = xmlRoot(zip["[Content_Types].xml"]) {
            for o in ct.children("Override") { if let p = o.a("PartName"), let t = o.a("ContentType") { contentTypes.overrides[String(p.drop { $0 == "/" })] = t } }
            for d in ct.children("Default") { if let e = d.a("Extension"), let t = d.a("ContentType") { contentTypes.defaults[e.lowercased()] = t } }
        }
        let presPath = "ppt/presentation.xml"
        guard let pres = xmlRoot(zip[presPath]) else { throw DeckError.invalid(L("The file is not a PowerPoint presentation")) }
        if let sz = pres.child("sldSz"), let cx = sz.num("cx"), let cy = sz.num("cy"), cx > 0, cy > 0 {
            deck.size = CGSize(width: cx / emuPerPoint, height: cy / emuPerPoint)
        }
        if let n = pres.int("firstSlideNum") { deck.firstSlideNumber = n }
        let presRels = rels(presPath)

        // Master, theme, layouts
        let masterPath = pres.child("sldMasterIdLst")?.children("sldMasterId").first.flatMap { $0.rid.flatMap { presRels[$0]?.target } }
            ?? presRels.values.first { $0.type.hasSuffix("/slideMaster") }?.target
        guard let masterPath, let masterXML = xmlRoot(zip[masterPath]) else { throw DeckError.invalid(L("The presentation has no slide master")) }
        let masterRels = rels(masterPath)
        if let themePath = masterRels.values.first(where: { $0.type.hasSuffix("/theme") })?.target, let theme = xmlRoot(zip[themePath]) {
            readTheme(theme)
        }
        applyColorMap(masterXML.child("clrMap"))
        deck.master = Master()
        deck.master.background = readBackground(masterXML.child("cSld"), part: masterPath) ?? .solid(PColor(scheme: "bg1"))
        if let tx = masterXML.child("txStyles") {
            deck.master.titleStyle = readListStyle(tx.child("titleStyle"), part: masterPath)
            deck.master.bodyStyle = readListStyle(tx.child("bodyStyle"), part: masterPath)
            deck.master.otherStyle = readListStyle(tx.child("otherStyle"), part: masterPath)
        }
        // Shapes outside placeholders use the presentation's default text style.
        if let def = pres.child("defaultTextStyle") {
            deck.master.otherStyle = readListStyle(def, part: presPath).over(deck.master.otherStyle)
        }
        fillLevelDefaults()
        let (mph, mobj) = readTree(masterXML.path("cSld", "spTree"), part: masterPath, inherit: [])
        deck.master.placeholders = mph
        deck.master.objects = mobj

        var layoutIndex: [String: Int] = [:]
        var layoutPaths: [String] = (masterXML.child("sldLayoutIdLst")?.children("sldLayoutId") ?? []).compactMap { $0.rid.flatMap { masterRels[$0]?.target } }
        if layoutPaths.isEmpty { layoutPaths = masterRels.values.filter { $0.type.hasSuffix("/slideLayout") }.map(\.target).sorted() }
        for path in layoutPaths {
            guard let xml = xmlRoot(zip[path]) else { continue }
            var layout = Layout(name: xml.child("cSld")?.a("name") ?? "Layout", type: xml.a("type") ?? "cust")
            layout.showMasterShapes = xml.bool("showMasterSp") ?? true
            layout.background = readBackground(xml.child("cSld"), part: path)
            let (ph, obj) = readTree(xml.path("cSld", "spTree"), part: path, inherit: deck.master.placeholders)
            layout.placeholders = ph
            layout.objects = obj
            layoutIndex[path] = deck.layouts.count
            deck.layouts.append(layout)
        }
        if deck.layouts.isEmpty { deck.layouts = Themes.standard(size: deck.size).1 }

        // Slides
        let slidePaths = (pres.child("sldIdLst")?.children("sldId") ?? []).compactMap { $0.rid.flatMap { presRels[$0]?.target } }
        for path in slidePaths {
            guard let xml = xmlRoot(zip[path]) else { continue }
            let srels = rels(path)
            let lpath = srels.values.first { $0.type.hasSuffix("/slideLayout") }?.target
            var slide = Slide(layout: lpath.flatMap { layoutIndex[$0] } ?? 0)
            if layoutIndex[lpath ?? ""] == nil, let lpath, let lx = xmlRoot(zip[lpath]) {
                // Layout of another master: read it as well.
                var layout = Layout(name: lx.child("cSld")?.a("name") ?? "Layout", type: lx.a("type") ?? "cust")
                layout.background = readBackground(lx.child("cSld"), part: lpath)
                let (ph, obj) = readTree(lx.path("cSld", "spTree"), part: lpath, inherit: deck.master.placeholders)
                layout.placeholders = ph
                layout.objects = obj
                layoutIndex[lpath] = deck.layouts.count
                deck.layouts.append(layout)
                slide.layout = deck.layouts.count - 1
            }
            slide.hidden = xml.a("show") == "0"
            slide.showMasterShapes = xml.bool("showMasterSp") ?? true
            slide.background = readBackground(xml.child("cSld"), part: path)
            let inherit = (deck.layouts.indices.contains(slide.layout) ? deck.layouts[slide.layout].placeholders : []) + deck.master.placeholders
            let (ph, obj) = readTree(xml.path("cSld", "spTree"), part: path, inherit: inherit, keepOrder: true)
            slide.objects = ph + obj
            slide.transition = readTransition(xml)
            readTiming(xml, into: &slide)
            if let notesPath = srels.values.first(where: { $0.type.hasSuffix("/notesSlide") })?.target, let notes = xmlRoot(zip[notesPath]) {
                slide.notes = readNotes(notes)
            }
            deck.slides.append(slide)
        }
        return deck
    }

    // MARK: - Theme

    func contentType(_ path: String) -> String {
        contentTypes.overrides[path] ?? contentTypes.defaults[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// A part with the parts it refers to (kept verbatim for writing back).
    func package(_ path: String, depth: Int = 0) -> PackagePart? {
        guard let data = zip[path] else { return nil }
        var list: [PackageRel] = []
        if depth < 4 {
            for (id, r) in rels(path).sorted(by: { $0.key < $1.key }) {
                if r.external { list.append(PackageRel(id: id, type: r.type, external: r.target, part: nil)) }
                else if let p = package(r.target, depth: depth + 1) { list.append(PackageRel(id: id, type: r.type, external: nil, part: p)) }
            }
        }
        return PackagePart(name: path, data: data, contentType: contentType(path), rels: list)
    }

    mutating func readTheme(_ root: XMLElement) {
        guard let elements = root.child("themeElements") else { return }
        var theme = Theme(name: root.a("name") ?? "Theme", colors: [:], majorFont: "Calibri Light", minorFont: "Calibri")
        if let scheme = elements.child("clrScheme") {
            for slot in Theme.slots {
                guard let e = scheme.child(slot) else { continue }
                if let c = e.child("srgbClr")?.a("val"), let v = UInt32(c, radix: 16) { theme.colors[slot] = v }
                else if let c = e.child("sysClr")?.a("lastClr"), let v = UInt32(c, radix: 16) { theme.colors[slot] = v }
                else if let c = e.child("sysClr")?.a("val") { theme.colors[slot] = c == "window" ? 0xFFFFFF : 0x000000 }
            }
        }
        if let fonts = elements.child("fontScheme") {
            if let f = fonts.path("majorFont", "latin")?.a("typeface"), !f.isEmpty { theme.majorFont = f }
            if let f = fonts.path("minorFont", "latin")?.a("typeface"), !f.isEmpty { theme.minorFont = f }
        }
        deck.theme = theme
        if let fmt = elements.child("fmtScheme") {
            let widths = fmt.child("lnStyleLst")?.children("ln").compactMap { $0.num("w").map { $0 / emuPerPoint } } ?? []
            if !widths.isEmpty { themeLineWidths = widths }
            themeBackgrounds = fmt.child("bgFillStyleLst")?.elements.compactMap { readFill(wrapping: $0, part: "") } ?? []
            themeFills = fmt.child("fillStyleLst")?.elements.compactMap { readFill(wrapping: $0, part: "") } ?? []
            themeLines = fmt.child("lnStyleLst")?.children("ln").map { ln in var l = LineStyle(color: PColor(scheme: "phClr")); readLine(ln, into: &l); return l } ?? []
            themeShadows = fmt.child("effectStyleLst")?.children("effectStyle").map { $0.descendants("outerShdw").isEmpty == false } ?? []
        }
    }

    /// Non-standard colour maps (bg1 = dk1 for dark masters) are folded into the theme.
    mutating func applyColorMap(_ map: XMLElement?) {
        guard let map else { return }
        var c = deck.theme.colors
        let original = c
        for (alias, slot) in [("bg1", "lt1"), ("tx1", "dk1"), ("bg2", "lt2"), ("tx2", "dk2")] {
            if let target = map.a(alias), target != slot, let v = original[target] { c[slot] = v }
        }
        deck.theme.colors = c
    }

    /// Levels missing from the master styles get the standard values.
    mutating func fillLevelDefaults() {
        let std = Themes.masterStyles()
        deck.master.titleStyle = deck.master.titleStyle.over(std.title)
        deck.master.bodyStyle = deck.master.bodyStyle.over(std.body)
        deck.master.otherStyle = deck.master.otherStyle.over(std.other)
    }

    // MARK: - Colours and fills

    static let presetColors: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00,
        "gray": 0x808080, "grey": 0x808080, "orange": 0xFFA500, "purple": 0x800080, "cyan": 0x00FFFF, "magenta": 0xFF00FF,
        "darkGray": 0xA9A9A9, "lightGray": 0xD3D3D3, "navy": 0x000080, "teal": 0x008080, "maroon": 0x800000,
    ]

    func readColor(_ parent: XMLElement?) -> PColor? {
        guard let parent else { return nil }
        for e in parent.elements {
            var c: PColor?
            switch e.localName {
            case "srgbClr": c = e.a("val").flatMap { UInt32($0, radix: 16) }.map { PColor(rgb: $0) }
            case "schemeClr": c = e.a("val").map { PColor(scheme: $0) }
            case "sysClr": c = PColor(rgb: e.a("lastClr").flatMap { UInt32($0, radix: 16) } ?? (e.a("val") == "window" ? 0xFFFFFF : 0))
            case "prstClr": c = PColor(rgb: Self.presetColors[e.a("val") ?? ""] ?? 0)
            case "scrgbClr":
                let r = (e.num("r") ?? 0) / 100000, g = (e.num("g") ?? 0) / 100000, b = (e.num("b") ?? 0) / 100000
                c = PColor(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
            case "hslClr":
                let (r, g, b) = hslToRGB((e.num("hue") ?? 0) / 21600000, (e.num("sat") ?? 0) / 100000, (e.num("lum") ?? 0) / 100000)
                c = PColor(NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
            default: continue
            }
            guard var color = c else { continue }
            for m in e.elements {
                guard let v = m.int("val"), let name = m.localName else { continue }
                if ["lumMod", "lumOff", "tint", "shade", "satMod", "alpha"].contains(name) { color.mods.append(.init(name: name, val: v)) }
            }
            return color
        }
        return nil
    }

    /// Fill from the children of `parent` (spPr, bgPr, tcPr): nil when none is given.
    mutating func readFill(_ parent: XMLElement?, part: String) -> Fill? {
        guard let parent else { return nil }
        for e in parent.elements {
            if let f = readFill(wrapping: e, part: part) { return f }
        }
        return nil
    }

    mutating func readFill(wrapping e: XMLElement, part: String) -> Fill? {
        switch e.localName {
        case "noFill": return Fill.none
        case "solidFill": return readColor(e).map { .solid($0) }
        case "gradFill":
            let stops = (e.child("gsLst")?.children("gs") ?? []).compactMap { gs -> GradientStop? in
                guard let c = readColor(gs) else { return nil }
                return GradientStop(position: (gs.num("pos") ?? 0) / 100000, color: c)
            }.sorted { $0.position < $1.position }
            guard !stops.isEmpty else { return nil }
            var g = Gradient(stops: stops)
            if let lin = e.child("lin") { g.angle = (lin.num("ang") ?? 0) / 60000 } else if e.child("path") != nil { g.radial = true }
            return .gradient(g)
        case "blipFill":
            if let media = readBlip(e, part: part) { return .picture(media) }
            return nil
        case "grpFill": return nil
        default: return nil
        }
    }

    mutating func readBlip(_ blipFill: XMLElement, part: String) -> String? {
        guard let id = blipFill.child("blip")?.a("embed"), let target = rels(part)[id]?.target, let data = zip[target] else { return nil }
        if let m = mediaByPart[target] { return m }
        let name = deck.addMedia(data, ext: imageExtension(data))
        mediaByPart[target] = name
        return name
    }

    /// A theme style with its placeholder colour (phClr) replaced by `c`.
    static func substitute(_ f: Fill, _ c: PColor) -> Fill {
        func sub(_ x: PColor) -> PColor {
            guard x.scheme == "phClr" else { return x }
            var out = c
            out.mods += x.mods
            return out
        }
        switch f {
        case .solid(let x): return .solid(sub(x))
        case .gradient(var g): g.stops = g.stops.map { GradientStop(position: $0.position, color: sub($0.color)) }; return .gradient(g)
        default: return f
        }
    }

    mutating func readBackground(_ cSld: XMLElement?, part: String) -> Fill? {
        guard let bg = cSld?.child("bg") else { return nil }
        if let pr = bg.child("bgPr") { return readFill(pr, part: part) }
        if let ref = bg.child("bgRef") {
            let idx = ref.int("idx") ?? 0
            let color = readColor(ref)
            if idx >= 1001, themeBackgrounds.indices.contains(idx - 1001) {
                switch themeBackgrounds[idx - 1001] {
                case .solid: return color.map { .solid($0) }
                case .gradient(var g):
                    if let color { g.stops = g.stops.map { GradientStop(position: $0.position, color: $0.color.scheme == "phClr" ? PColor(scheme: color.scheme ?? "bg1", mods: color.mods + $0.color.mods) : $0.color) } }
                    return .gradient(g)
                case let f: return f
                }
            }
            return color.map { .solid($0) }
        }
        return nil
    }

    func readLine(_ ln: XMLElement?, into line: inout LineStyle) {
        guard let ln else { return }
        if let w = ln.num("w") { line.width = w / emuPerPoint }
        if ln.child("noFill") != nil { line.color = nil }
        if let c = readColor(ln.child("solidFill")) { line.color = c }
        if let g = ln.child("gradFill"), let c = readColor(g.child("gsLst")?.children("gs").first) { line.color = c }
        if let d = ln.child("prstDash")?.a("val") {
            switch d {
            case "solid": line.dash = .solid
            case "dot", "sysDot": line.dash = .dot
            case "dash", "sysDash": line.dash = .dash
            case "lgDash", "lgDashDot", "lgDashDotDot": line.dash = .lgDash
            case "dashDot", "sysDashDot", "sysDashDotDot": line.dash = .dashDot
            default: line.dash = .dash
            }
        }
        func head(_ e: XMLElement?) -> Arrowhead? {
            guard let t = e?.a("type") else { return nil }
            switch t {
            case "none": return Arrowhead.none
            case "triangle": return .triangle
            case "arrow": return .arrow
            case "stealth": return .stealth
            case "oval": return .oval
            case "diamond": return .diamond
            default: return .triangle
            }
        }
        if let h = head(ln.child("headEnd")) { line.head = h }
        if let t = head(ln.child("tailEnd")) { line.tail = t }
    }

    // MARK: - Text

    func readRunProps(_ e: XMLElement?, part: String) -> RunProps {
        guard let e else { return RunProps() }
        var r = RunProps()
        if let sz = e.num("sz") { r.size = sz / 100 }
        r.bold = e.bool("b")
        r.italic = e.bool("i")
        if let u = e.a("u") { r.underline = u != "none" }
        if let s = e.a("strike") { r.strike = s != "noStrike" }
        if let b = e.num("baseline") { r.baseline = b / 1000 }
        if let c = readColor(e.child("solidFill")) { r.color = c }
        if let f = e.child("latin")?.a("typeface"), !f.isEmpty { r.font = f }
        else if let f = e.child("cs")?.a("typeface"), !f.isEmpty, r.font == nil, f.hasPrefix("+") == false { r.font = f }
        return r
    }

    func readLevel(_ e: XMLElement?, part: String) -> LevelStyle {
        guard let e else { return LevelStyle() }
        var s = LevelStyle()
        if let a = e.a("algn") {
            switch a {
            case "ctr": s.align = .center
            case "r": s.align = .right
            case "just", "dist": s.align = .justify
            default: s.align = .left
            }
        }
        if let m = e.num("marL") { s.marL = m / emuPerPoint }
        if let i = e.num("indent") { s.indent = i / emuPerPoint }
        func spacing(_ el: XMLElement?, lineSpacing: Bool) -> CGFloat? {
            guard let el else { return nil }
            if let pct = el.child("spcPct")?.num("val") { return lineSpacing ? pct / 100000 : pct / 100000 * 12 }
            if let pts = el.child("spcPts")?.num("val") { return lineSpacing ? -pts / 100 : pts / 100 }
            return nil
        }
        s.lineSpacing = spacing(e.child("lnSpc"), lineSpacing: true)
        s.spaceBefore = spacing(e.child("spcBef"), lineSpacing: false)
        s.spaceAfter = spacing(e.child("spcAft"), lineSpacing: false)
        var bullet: Bullet?
        if e.child("buNone") != nil { bullet = Bullet.none }
        if let c = e.child("buChar") { bullet = Bullet(kind: .char, char: c.a("char") ?? "•") }
        if let n = e.child("buAutoNum") { bullet = Bullet(kind: .number, scheme: n.a("type") ?? "arabicPeriod", startAt: n.int("startAt") ?? 1) }
        if bullet != nil {
            if let f = e.child("buFont")?.a("typeface") { bullet?.font = f }
            if let c = readColor(e.child("buClr")) { bullet?.color = c }
            if let p = e.child("buSzPct")?.num("val") { bullet?.sizePercent = p / 100000 }
            s.bullet = bullet
        }
        s.run = readRunProps(e.child("defRPr"), part: part)
        return s
    }

    func readListStyle(_ e: XMLElement?, part: String) -> ListStyle {
        var l = ListStyle()
        guard let e else { return l }
        let base = readLevel(e.child("defPPr"), part: part)
        for i in 0..<9 {
            l[i] = readLevel(e.child("lvl\(i + 1)pPr"), part: part).over(base)
        }
        return l
    }

    mutating func readTextBody(_ tx: XMLElement?, part: String, base: TextBody?) -> TextBody? {
        guard let tx else { return nil }
        var body = TextBody()
        if let base {
            body.anchor = base.anchor
            body.insets = base.insets
            body.wrap = base.wrap
            body.autofit = base.autofit
        }
        if let pr = tx.child("bodyPr") {
            if let v = pr.num("lIns") { body.insets.left = v / emuPerPoint }
            if let v = pr.num("tIns") { body.insets.top = v / emuPerPoint }
            if let v = pr.num("rIns") { body.insets.right = v / emuPerPoint }
            if let v = pr.num("bIns") { body.insets.bottom = v / emuPerPoint }
            if let a = pr.a("anchor") { body.anchor = Anchor(rawValue: a) ?? .top }
            if let w = pr.a("wrap") { body.wrap = w != "none" }
            if let v = pr.a("vert") { body.vertical = v != "horz" }
            if pr.child("normAutofit") != nil { body.autofit = .shrink }
            if pr.child("spAutoFit") != nil { body.autofit = .resize }
            if pr.child("noAutofit") != nil { body.autofit = .none }
        }
        // Only explicit levels count as overrides.
        body.listStyle = sparseListStyle(tx.child("lstStyle"), part: part)
        var paras: [Paragraph] = []
        for p in tx.children("p") {
            var para = Paragraph()
            if let pPr = p.child("pPr") {
                para.level = pPr.int("lvl") ?? 0
                para.props = readLevel(pPr, part: part)
                para.props.run = RunProps()
            }
            for e in p.elements {
                switch e.localName {
                case "r":
                    var run = TextRun(text: e.child("t")?.stringValue ?? "", props: readRunProps(e.child("rPr"), part: part))
                    if let id = e.child("rPr")?.child("hlinkClick")?.rid, let t = rels(part)[id]?.target { run.link = t }
                    para.runs.append(run)
                case "br":
                    let props = readRunProps(e.child("rPr"), part: part)
                    if let last = para.runs.indices.last, para.runs[last].props == props { para.runs[last].text += "\u{0B}" }
                    else { para.runs.append(TextRun(text: "\u{0B}", props: props)) }
                case "fld":
                    let type = e.a("type") ?? ""
                    para.runs.append(TextRun(text: e.child("t")?.stringValue ?? "", props: readRunProps(e.child("rPr"), part: part),
                                             field: type == "slidenum" ? "slidenum" : type.hasPrefix("datetime") ? "datetime" : nil))
                case "endParaRPr":
                    para.endProps = readRunProps(e, part: part)
                default: break
                }
            }
            if let last = para.runs.last, para.endProps.isEmpty { para.endProps = last.props }
            paras.append(para)
        }
        body.paragraphs = paras.isEmpty ? [Paragraph()] : paras
        return body
    }

    func sparseListStyle(_ e: XMLElement?, part: String) -> ListStyle {
        var l = ListStyle()
        guard let e else { return l }
        for i in 0..<9 { if let lv = e.child("lvl\(i + 1)pPr") { l[i] = readLevel(lv, part: part) } }
        return l
    }

    func readNotes(_ root: XMLElement) -> String {
        guard let tree = root.path("cSld", "spTree") else { return "" }
        for sp in tree.descendants("sp") {
            guard sp.path("nvSpPr", "nvPr", "ph")?.a("type") == "body" else { continue }
            let paras = sp.child("txBody")?.children("p") ?? []
            return paras.map { p in p.elements.map { e -> String in
                switch e.localName {
                case "r", "fld": return e.child("t")?.stringValue ?? ""
                case "br": return "\n"
                default: return ""
                }
            }.joined() }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - Shape tree

    /// Placeholders and other shapes of a tree. `inherit`: placeholders of the layout/master the tree builds on.
    mutating func readTree(_ tree: XMLElement?, part: String, inherit: [SlideObject], keepOrder: Bool = false) -> ([SlideObject], [SlideObject]) {
        guard let tree else { return ([], []) }
        var ph: [SlideObject] = [], other: [SlideObject] = []
        for e in tree.elements {
            for o in readElement(e, part: part, inherit: inherit) {
                if keepOrder { ph.append(o) } else if o.placeholder != nil { ph.append(o) } else { other.append(o) }
            }
        }
        return (ph, other)
    }

    func xfrm(_ e: XMLElement?) -> (CGRect, CGFloat, Bool, Bool)? {
        guard let e, let off = e.child("off"), let ext = e.child("ext") else { return nil }
        let r = CGRect(x: (off.num("x") ?? 0) / emuPerPoint, y: (off.num("y") ?? 0) / emuPerPoint,
                       width: (ext.num("cx") ?? 0) / emuPerPoint, height: (ext.num("cy") ?? 0) / emuPerPoint)
        return (r, (e.num("rot") ?? 0) / 60000, e.bool("flipH") ?? false, e.bool("flipV") ?? false)
    }

    func inherited(_ ph: Placeholder?, from list: [SlideObject]) -> SlideObject? {
        guard let ph else { return nil }
        if let idx = ph.idx, let m = list.first(where: { $0.placeholder?.idx == idx && $0.placeholder?.type == ph.type }) { return m }
        if let idx = ph.idx, idx != 0, let m = list.first(where: { $0.placeholder?.idx == idx }) { return m }
        let t = ph.type
        return list.first { o in
            guard let ot = o.placeholder?.type else { return false }
            if ot == t { return true }
            if ph.isTitle && o.placeholder?.isTitle == true { return true }
            if (t == "body" || t == "obj" || t == "subTitle") && ot == "body" { return true }
            return false
        }
    }

    mutating func readElement(_ e: XMLElement, part: String, inherit: [SlideObject]) -> [SlideObject] {
        switch e.localName {
        case "sp", "cxnSp":
            return readShape(e, part: part, inherit: inherit).map { [$0] } ?? []
        case "pic":
            return readPicture(e, part: part, inherit: inherit).map { [$0] } ?? []
        case "graphicFrame":
            return readGraphicFrame(e, part: part).map { [$0] } ?? []
        case "grpSp":
            return readGroup(e, part: part, inherit: inherit).map { [$0] } ?? []
        case "AlternateContent":
            let branch = e.child("Fallback") ?? e.child("Choice")
            return (branch?.elements ?? []).flatMap { readElement($0, part: part, inherit: inherit) }
        default:
            return []
        }
    }

    func readNonVisual(_ e: XMLElement, into o: inout SlideObject) {
        let nv = e.elements.first { ($0.localName ?? "").hasPrefix("nv") }
        if let c = nv?.child("cNvPr") {
            o.id = c.int("id") ?? o.id
            o.name = c.a("name") ?? ""
            o.descr = c.a("descr") ?? ""
        }
        if let p = nv?.child("nvPr")?.child("ph") {
            o.placeholder = Placeholder(type: p.a("type") ?? "body", idx: p.int("idx"))
        }
    }

    mutating func readShape(_ e: XMLElement, part: String, inherit: [SlideObject]) -> SlideObject? {
        var o = SlideObject(id: 0, kind: e.localName == "cxnSp" ? .line : .shape, frame: .zero)
        readNonVisual(e, into: &o)
        if e.path("nvSpPr", "cNvSpPr")?.bool("txBox") == true { o.kind = .textBox }
        let base = inherited(o.placeholder, from: inherit)
        if o.placeholder != nil { o.kind = .textBox }
        let spPr = e.child("spPr")
        if let (r, rot, fh, fv) = xfrm(spPr?.child("xfrm")) {
            o.frame = r; o.rotation = rot; o.flipH = fh; o.flipV = fv
        } else if let base {
            o.frame = base.frame
            o.rotation = base.rotation
        }
        if let g = spPr?.child("prstGeom") {
            o.geometry = g.a("prst") ?? "rect"
            for gd in g.child("avLst")?.children("gd") ?? [] {
                if let n = gd.a("name"), let f = gd.a("fmla"), f.hasPrefix("val "), let v = Int(f.dropFirst(4).trimmingCharacters(in: .whitespaces)) { o.adjust[n] = v }
            }
        } else if let cg = spPr?.child("custGeom") {
            o.custom = readCustomGeometry(cg)
            o.geometry = "custom"
        }
        if ["line", "straightConnector1", "bentConnector2", "bentConnector3", "bentConnector4", "curvedConnector3"].contains(o.geometry) { o.kind = .line }
        // Theme style references (p:style) give the defaults; spPr overrides.
        var line = base?.line ?? LineStyle.none
        var fill = base?.fill ?? Fill.none
        var fontColor: PColor?
        var styleShadow = false
        if let style = e.child("style") {
            if let ref = style.child("lnRef"), let idx = ref.int("idx"), idx > 0 {
                line.color = readColor(ref)
                line.width = themeLineWidths.indices.contains(idx - 1) ? themeLineWidths[idx - 1] : 1
                if themeLines.indices.contains(idx - 1), let c = line.color {
                    let tl = themeLines[idx - 1]
                    line.dash = tl.dash
                    if let tc = tl.color, tc.scheme == "phClr" { var x = c; x.mods += tc.mods; line.color = x }
                }
            }
            if let ref = style.child("fillRef"), let idx = ref.int("idx"), idx > 0, let c = readColor(ref) {
                fill = themeFills.indices.contains(idx - 1) ? Self.substitute(themeFills[idx - 1], c) : .solid(c)
            }
            if let ref = style.child("effectRef"), let idx = ref.int("idx"), idx > 0, themeShadows.indices.contains(idx - 1), themeShadows[idx - 1] {
                styleShadow = true
            }
            fontColor = readColor(style.child("fontRef"))
        }
        if let f = readFill(spPr, part: part) { fill = f }
        readLine(spPr?.child("ln"), into: &line)
        o.fill = o.kind == .line ? .none : fill
        o.line = line
        if o.kind == .line, o.line.color == nil, spPr?.child("ln")?.child("noFill") == nil { o.line.color = PColor(scheme: "tx1") }
        o.shadow = spPr?.child("effectLst").map { $0.child("outerShdw") != nil } ?? styleShadow
        if let tx = e.child("txBody") {
            o.text = readTextBody(tx, part: part, base: base?.text)
            if let fontColor, var t = o.text {
                for i in 0..<9 where t.listStyle[i].run.color == nil { t.listStyle.levels[i].run.color = fontColor }
                o.text = t
            }
            if o.kind == .shape, o.text?.isEmpty == true, o.placeholder == nil { o.text?.paragraphs = [Paragraph()] }
        } else if o.placeholder != nil {
            o.text = base?.text.map { var t = $0; t.paragraphs = [Paragraph()]; t.listStyle = ListStyle(); return t } ?? TextBody()
        }
        if o.kind == .shape, o.text == nil {
            var t = TextBody()
            t.anchor = .middle
            o.text = t
        }
        return o
    }

    func readCustomGeometry(_ e: XMLElement) -> CustomGeometry {
        var g = CustomGeometry()
        func guides(_ list: XMLElement?) -> [GeoGuide] {
            (list?.children("gd") ?? []).compactMap { gd in gd.a("name").map { GeoGuide(name: $0, fmla: gd.a("fmla") ?? "val 0") } }
        }
        g.adjust = guides(e.child("avLst"))
        g.guides = guides(e.child("gdLst"))
        if let r = e.child("rect") { g.rect = [r.a("l") ?? "l", r.a("t") ?? "t", r.a("r") ?? "r", r.a("b") ?? "b"] }
        for p in e.child("pathLst")?.children("path") ?? [] {
            var gp = GeoPath()
            gp.w = p.a("w").flatMap(Double.init)
            gp.h = p.a("h").flatMap(Double.init)
            gp.fill = GeoFill(rawValue: p.a("fill") ?? "norm") ?? .norm
            gp.stroke = p.bool("stroke") ?? true
            for c in p.elements {
                let pts = c.children("pt").map { ($0.a("x") ?? "0", $0.a("y") ?? "0") }
                switch c.localName {
                case "moveTo": if let q = pts.first { gp.commands.append(.move(q.0, q.1)) }
                case "lnTo": if let q = pts.first { gp.commands.append(.line(q.0, q.1)) }
                case "arcTo": gp.commands.append(.arc(wR: c.a("wR") ?? "0", hR: c.a("hR") ?? "0", st: c.a("stAng") ?? "0", sw: c.a("swAng") ?? "0"))
                case "quadBezTo": if pts.count >= 2 { gp.commands.append(.quad(pts[0].0, pts[0].1, pts[1].0, pts[1].1)) }
                case "cubicBezTo": if pts.count >= 3 { gp.commands.append(.cubic(pts[0].0, pts[0].1, pts[1].0, pts[1].1, pts[2].0, pts[2].1)) }
                case "close": gp.commands.append(.close)
                default: break
                }
            }
            g.paths.append(gp)
        }
        return g
    }

    mutating func readPicture(_ e: XMLElement, part: String, inherit: [SlideObject]) -> SlideObject? {
        var o = SlideObject(id: 0, kind: .picture, frame: .zero)
        readNonVisual(e, into: &o)
        let base = inherited(o.placeholder, from: inherit)
        let spPr = e.child("spPr")
        if let (r, rot, fh, fv) = xfrm(spPr?.child("xfrm")) {
            o.frame = r; o.rotation = rot; o.flipH = fh; o.flipV = fv
        } else if let base { o.frame = base.frame }
        if let blip = e.child("blipFill") {
            o.media = readBlip(blip, part: part)
            if let src = blip.child("srcRect") {
                o.crop = NSEdgeInsets(top: (src.num("t") ?? 0) / 100000, left: (src.num("l") ?? 0) / 100000,
                                      bottom: (src.num("b") ?? 0) / 100000, right: (src.num("r") ?? 0) / 100000)
            }
        }
        if let g = spPr?.child("prstGeom")?.a("prst") { o.geometry = g }
        if let cg = spPr?.child("custGeom") { o.custom = readCustomGeometry(cg); o.geometry = "custom" }
        var line = LineStyle.none
        readLine(spPr?.child("ln"), into: &line)
        o.line = line
        o.shadow = spPr?.child("effectLst")?.child("outerShdw") != nil
        if let amt = e.path("blipFill", "blip", "alphaModFix")?.num("amt") { o.opacity = amt / 100000 }
        if o.media == nil && o.placeholder == nil { return nil }
        return o
    }

    mutating func readGraphicFrame(_ e: XMLElement, part: String) -> SlideObject? {
        var o = SlideObject(id: 0, kind: .table, frame: .zero)
        readNonVisual(e, into: &o)
        if let (r, rot, _, _) = xfrm(e.child("xfrm")) { o.frame = r; o.rotation = rot }
        guard let data = e.path("graphic", "graphicData") else { return nil }
        if let tbl = data.child("tbl") {
            o.table = readTable(tbl, part: part)
            if let t = o.table { o.frame.size = CGSize(width: max(o.frame.width, t.size.width), height: max(o.frame.height, t.size.height)) }
            o.placeholder = nil
            return o
        }
        let uri = data.a("uri") ?? ""
        if uri.hasSuffix("/chart"), let id = data.child("chart")?.rid, let target = rels(part)[id]?.target,
           let pkg = package(target), let root = xmlRoot(pkg.data) {
            var m = ChartXML.read(root) { readColor($0) }
            m.original = ChartOriginal(model: m, part: pkg)
            o.kind = .chart
            o.chart = m
            o.placeholder = nil
            return o
        }
        // SmartArt, OLE: a box saying what was there (a fallback picture when the file has one).
        o.kind = .shape
        o.unsupported = uri.contains("chart") ? L("Chart (not supported)") : uri.contains("diagram") ? L("SmartArt (not supported)") : L("Object (not supported)")
        if let pic = data.descendants("pic").first, let blip = pic.child("blipFill") {
            o.kind = .picture
            o.media = readBlip(blip, part: part)
        }
        o.placeholder = nil
        return o
    }

    mutating func readTable(_ tbl: XMLElement, part: String) -> TableModel {
        let cols = tbl.child("tblGrid")?.children("gridCol").map { ($0.num("w") ?? 914400) / emuPerPoint } ?? []
        let rows = tbl.children("tr")
        var t = TableModel(rows: max(1, rows.count), columns: max(1, cols.count), width: cols.reduce(0, +))
        t.columns = cols.isEmpty ? [100] : cols
        if let pr = tbl.child("tblPr") {
            t.firstRow = pr.bool("firstRow") ?? false
            t.bandRows = pr.bool("bandRow") ?? false
        }
        for (ri, tr) in rows.enumerated() {
            t.rows[ri] = (tr.num("h") ?? 370840) / emuPerPoint
            let tcs = tr.children("tc")
            var row: [TableCell] = []
            for tc in tcs {
                var cell = TableCell()
                cell.gridSpan = tc.int("gridSpan") ?? 1
                cell.rowSpan = tc.int("rowSpan") ?? 1
                cell.merged = tc.bool("hMerge") == true || tc.bool("vMerge") == true
                if let body = readTextBody(tc.child("txBody"), part: part, base: nil) {
                    cell.text = body
                    cell.text.insets = NSEdgeInsets(top: 3.6, left: 7.2, bottom: 3.6, right: 7.2)
                }
                if let pr = tc.child("tcPr") {
                    if let v = pr.num("marL") { cell.text.insets.left = v / emuPerPoint }
                    if let v = pr.num("marR") { cell.text.insets.right = v / emuPerPoint }
                    if let v = pr.num("marT") { cell.text.insets.top = v / emuPerPoint }
                    if let v = pr.num("marB") { cell.text.insets.bottom = v / emuPerPoint }
                    if let a = pr.a("anchor") { cell.text.anchor = Anchor(rawValue: a) ?? .top }
                    cell.fill = readFill(pr, part: part)
                    if case .none? = cell.fill, pr.child("noFill") == nil { cell.fill = nil }
                }
                row.append(cell)
            }
            while row.count < t.columns.count { row.append(TableCell()) }
            t.cells[ri] = Array(row.prefix(t.columns.count))
        }
        // Tables without a style look: plain cells with thin borders.
        if tbl.child("tblPr")?.child("tableStyleId") == nil, !t.firstRow, !t.bandRows {
            for ri in t.cells.indices { for ci in t.cells[ri].indices where t.cells[ri][ci].fill == nil { t.cells[ri][ci].fill = Fill.none } }
            t.borderColor = PColor(scheme: "tx1")
            t.borderWidth = 0.75
        }
        return t
    }

    mutating func readGroup(_ e: XMLElement, part: String, inherit: [SlideObject]) -> SlideObject? {
        var o = SlideObject(id: 0, kind: .group, frame: .zero)
        readNonVisual(e, into: &o)
        let x = e.path("grpSpPr", "xfrm")
        var children: [SlideObject] = []
        for c in e.elements { children += readElement(c, part: part, inherit: inherit) }
        guard !children.isEmpty else { return nil }
        if let (r, rot, _, _) = xfrm(x) {
            o.frame = r
            o.rotation = rot
            let chOff = x?.child("chOff"), chExt = x?.child("chExt")
            let cx = (chOff?.num("x") ?? r.minX * emuPerPoint) / emuPerPoint, cy = (chOff?.num("y") ?? r.minY * emuPerPoint) / emuPerPoint
            let cw = (chExt?.num("cx") ?? r.width * emuPerPoint) / emuPerPoint, ch = (chExt?.num("cy") ?? r.height * emuPerPoint) / emuPerPoint
            let sx = cw > 0 ? r.width / cw : 1, sy = ch > 0 ? r.height / ch : 1
            func map(_ list: inout [SlideObject]) {
                for i in list.indices {
                    let f = list[i].frame
                    let nf = CGRect(x: r.minX + (f.minX - cx) * sx, y: r.minY + (f.minY - cy) * sy, width: f.width * sx, height: f.height * sy)
                    // Children of nested groups are already in this group's child space: map them too.
                    var kids = list[i].children
                    map(&kids)
                    list[i].children = kids
                    list[i].frame = nf
                    if var t = list[i].table { t.fit(to: nf.size); list[i].table = t }
                }
            }
            map(&children)
        } else {
            o.frame = children.map(\.frame).reduce(children[0].frame) { $0.union($1) }
        }
        o.children = children
        return o
    }

    // MARK: - Transitions and builds

    func readTransition(_ slide: XMLElement) -> Transition {
        var t = Transition()
        var tr = slide.child("transition")
        if tr == nil, let alt = slide.children("AlternateContent").first(where: { $0.descendants("transition").isEmpty == false }) {
            tr = alt.child("Fallback")?.child("transition") ?? alt.child("Choice")?.child("transition")
        }
        guard let tr else { return t }
        switch tr.a("spd") {
        case "slow": t.duration = 1.0
        case "fast": t.duration = 0.5
        default: t.duration = 0.75
        }
        if let d = tr.num("dur") { t.duration = Double(d) / 1000 }
        if let adv = tr.num("advTm") { t.advanceAfter = Double(adv) / 1000 }
        for c in tr.elements {
            switch c.localName {
            case "fade": t.kind = .fade
            case "push": t.kind = .push; t.direction = c.a("dir") ?? "l"
            case "wipe": t.kind = .wipe; t.direction = c.a("dir") ?? "l"
            case "cover", "pull": t.kind = .cover; t.direction = c.a("dir") ?? "l"
            case "dissolve", "randomBar": t.kind = .dissolve
            case "split": t.kind = .split
            case "zoom": t.kind = .zoom
            case "sndAc", "extLst": continue
            default: if t.kind == .none { t.kind = .fade }
            }
        }
        return t
    }

    func readTiming(_ slide: XMLElement, into s: inout Slide) {
        guard let timing = slide.child("timing") else { return }
        for ctn in timing.descendants("cTn") where ctn.a("presetClass") == "entr" {
            guard let spid = ctn.descendants("spTgt").first?.int("spid") else { continue }
            let effect: BuildEffect
            switch ctn.int("presetID") ?? 1 {
            case 1: effect = .appear
            case 2: effect = .flyIn
            case 53, 21, 23: effect = .zoom
            default: effect = .fade
            }
            if s.object(spid)?.build == nil { s.update(spid) { $0.build = effect } }
        }
    }
}
