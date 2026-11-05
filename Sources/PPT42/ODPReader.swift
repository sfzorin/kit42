import AppKit
import Kit42

/// Reads an OpenDocument presentation (.odp): pages, frames, custom shapes, lines, pictures, tables, groups,
/// text with lists, notes, transitions and backgrounds. Text formatting is resolved through the style chain
/// and stored explicitly, so the deck looks as authored with our own master underneath.
enum ODPReader {
    static func read(_ data: Data) throws -> Deck {
        var r = try ODPReaderImpl(zip: ZipArchive(data: data))
        return try r.read()
    }
}

// MARK: - Units

/// "1.5cm", "10mm", "12pt", "1in", "3pc", "2px" → points.
func odfPoints(_ s: String?) -> CGFloat? {
    guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    var factor: CGFloat = 1
    for (unit, f) in [("cm", pointsPerCm), ("mm", pointsPerCm / 10), ("in", 72), ("pt", 1), ("pc", 12), ("px", 0.75)] as [(String, CGFloat)] where s.hasSuffix(unit) {
        s.removeLast(unit.count)
        factor = f
        break
    }
    guard let v = Double(s) else { return nil }
    return CGFloat(v) * factor
}

private func percent(_ s: String?) -> CGFloat? {
    guard let s, s.hasSuffix("%"), let v = Double(s.dropLast()) else { return nil }
    return CGFloat(v) / 100
}

private func hexColor(_ s: String?) -> PColor? {
    guard let s, s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) else { return nil }
    return PColor(rgb: v)
}

/// ISO 8601 duration ("PT5S", "PT00H01M30S") → seconds.
private func isoDuration(_ s: String?) -> Double? {
    guard let s, s.hasPrefix("P") else { return nil }
    var total = 0.0, num = ""
    for ch in s.dropFirst() {
        if ch.isNumber || ch == "." { num.append(ch); continue }
        let v = Double(num) ?? 0
        num = ""
        switch ch {
        case "H": total += v * 3600
        case "M": total += v * 60
        case "S": total += v
        default: break
        }
    }
    return total
}

// MARK: - Styles

private struct OStyle {
    var family: String
    var parent: String?
    var props: [String: [String: String]] = [:]   // "graphic", "paragraph", "text", "drawing-page", "table-cell", "table-column", "table-row"
    var listStyle: XMLElement?
    var listStyleName: String?
}

private struct ODPReaderImpl {
    let zip: ZipArchive
    var deck = Deck()
    var styles: [String: OStyle] = [:]
    var contentStyles: [String: OStyle] = [:]
    var defaults: [String: OStyle] = [:]
    var lists: [String: XMLElement] = [:]
    var gradients: [String: XMLElement] = [:]
    var fillImages: [String: String] = [:]
    var dashes: [String: XMLElement] = [:]
    var fontFaces: [String: String] = [:]
    var pageLayouts: [String: CGSize] = [:]
    var masters: [String: XMLElement] = [:]
    var nextID = 2
    var masterName = "Default"
    /// While reading content.xml, automatic styles of content win over styles.xml.
    var inContent = false

    init(zip: ZipArchive) { self.zip = zip }

    mutating func read() throws -> Deck {
        guard let content = xmlRoot(zip["content.xml"]) else { throw DeckError.invalid(L("The file is damaged")) }
        let stylesRoot = xmlRoot(zip["styles.xml"])
        deck = Deck.makeDefault()
        deck.slides = []
        if let s = stylesRoot {
            collectFonts(s.child("font-face-decls"))
            styles.merge(collectStyles(s.child("styles"))) { _, b in b }
            styles.merge(collectStyles(s.child("automatic-styles"))) { _, b in b }
            for m in s.child("master-styles")?.children("master-page") ?? [] {
                if let n = m.a("name") { masters[n] = m }
            }
        }
        collectFonts(content.child("font-face-decls"))
        contentStyles = collectStyles(content.child("automatic-styles"))

        let pages = content.child("body")?.child("presentation")?.children("page") ?? []
        // Slide size and master background from the master of the first page.
        masterName = pages.first?.a("master-page-name") ?? masters.keys.sorted().first ?? "Default"
        if let master = masters[masterName] {
            if let pl = master.a("page-layout-name"), let size = pageLayouts[pl], size.width > 0, size.height > 0, size != deck.size {
                deck.resize(to: size)
            }
            if let dp = master.a("style-name"), let fill = pageFill(dp, explicitOnly: false) { deck.master.background = fill }
            var objects: [SlideObject] = []
            for e in master.elements where e.localName != "notes" && e.a("class") == nil {
                objects += readShape(e, slide: nil)
            }
            deck.master.objects = objects
        }
        inContent = true
        for page in pages { deck.slides.append(readPage(page)) }
        if deck.slides.isEmpty { deck.slides = [deck.newSlide(layout: 0)] }
        return deck
    }

    // MARK: Style collection

    mutating func collectFonts(_ decls: XMLElement?) {
        for f in decls?.children("font-face") ?? [] {
            if let n = f.a("name") { fontFaces[n] = (f.a("font-family") ?? n).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        }
    }

    mutating func collectStyles(_ root: XMLElement?) -> [String: OStyle] {
        var table: [String: OStyle] = [:]
        guard let root else { return table }
        for e in root.elements {
            switch e.localName {
            case "style", "default-style":
                var s = OStyle(family: e.a("family") ?? "", parent: e.a("parent-style-name"))
                s.listStyleName = e.a("list-style-name")
                for p in e.elements {
                    guard let ln = p.localName, ln.hasSuffix("-properties") else { continue }
                    let kind = String(ln.dropLast("-properties".count))
                    var d = s.props[kind] ?? [:]
                    for a in p.attributes ?? [] { if let n = a.localName { d[n] = a.stringValue ?? "" } }
                    s.props[kind] = d
                    if let l = p.child("list-style") { s.listStyle = l }
                }
                if e.localName == "default-style" { defaults[s.family] = s } else if let n = e.a("name") { table[n] = s }
            case "list-style":
                if let n = e.a("name") { lists[n] = e }
            case "gradient":
                if let n = e.a("name") { gradients[n] = e }
            case "fill-image":
                if let n = e.a("name"), let h = e.a("href") { fillImages[n] = h }
            case "stroke-dash":
                if let n = e.a("name") { dashes[n] = e }
            case "page-layout":
                if let n = e.a("name"), let p = e.child("page-layout-properties"),
                   let w = odfPoints(p.a("page-width")), let h = odfPoints(p.a("page-height")) {
                    pageLayouts[n] = CGSize(width: w, height: h)
                }
            default: break
            }
        }
        return table
    }

    func style(_ name: String?) -> OStyle? {
        guard let name else { return nil }
        if inContent, let s = contentStyles[name] { return s }
        return styles[name] ?? contentStyles[name]
    }

    /// Properties of `kind` along the parent chain (parents first, then the family's default style).
    func props(_ name: String?, _ kind: String) -> [String: String] {
        var chain: [OStyle] = []
        var n = name
        var guardCount = 0
        while let s = style(n), guardCount < 20 {
            chain.append(s)
            n = s.parent
            guardCount += 1
        }
        var out = chain.last.flatMap { defaults[$0.family]?.props[kind] } ?? [:]
        for s in chain.reversed() { out.merge(s.props[kind] ?? [:]) { _, b in b } }
        return out
    }

    func embeddedList(_ name: String?) -> XMLElement? {
        var n = name
        var guardCount = 0
        while let s = style(n), guardCount < 20 {
            if let l = s.listStyle { return l }
            if let ln = s.listStyleName, let l = lists[ln] { return l }
            n = s.parent
            guardCount += 1
        }
        return nil
    }

    // MARK: Pages

    func transition(_ p: [String: String]) -> Transition {
        var t = Transition()
        if p["transition-type"] == "automatic", let d = isoDuration(p["duration"]) { t.advanceAfter = d }
        switch p["transition-speed"] {
        case "slow": t.duration = 1.0
        case "fast": t.duration = 0.5
        default: t.duration = 0.75
        }
        if let d = p["dur"], let v = Double(d.replacingOccurrences(of: "s", with: "")) { t.duration = v }
        let sub = p["subtype"] ?? "", reverse = p["direction"] == "reverse"
        func dir(_ s: String) -> String { ["fromRight": "l", "fromLeft": "r", "fromBottom": "u", "fromTop": "d"][s] ?? "l" }
        switch p["type"] ?? "" {
        case "": t.kind = .none
        case "fade": t.kind = .fade
        case "pushWipe": t.kind = .push; t.direction = dir(sub)
        case "slideWipe": t.kind = .cover; t.direction = dir(sub)
        case "barWipe":
            t.kind = .wipe
            t.direction = sub == "topToBottom" ? (reverse ? "u" : "d") : (reverse ? "l" : "r")
        case "dissolve", "randomBarWipe": t.kind = .dissolve
        case "barnDoorWipe": t.kind = .split
        case "irisWipe", "ellipseWipe", "zoom": t.kind = .zoom
        default: t.kind = .fade
        }
        return t
    }

    mutating func pageFill(_ styleName: String?, explicitOnly: Bool) -> Fill? {
        let p = props(styleName, "drawing-page")
        guard let kind = p["fill"] else { return explicitOnly ? nil : nil }
        return fill(p, kind: kind)
    }

    mutating func readPage(_ page: XMLElement) -> Slide {
        var slide = Slide(layout: 0)
        let dp = props(page.a("style-name"), "drawing-page")
        slide.hidden = dp["visibility"] == "hidden" || page.a("visibility") == "hidden"
        slide.showMasterShapes = dp["background-objects-visible"] != "false"
        if let kind = dp["fill"], kind != "none" || dp["background-size"] != nil { slide.background = fill(dp, kind: kind) }
        slide.transition = transition(dp)
        nextID = 2
        var objects: [SlideObject] = []
        // Pages on another master (LibreOffice makes one per pptx layout): its background and shapes.
        if let mname = page.a("master-page-name"), mname != masterName, let master = masters[mname] {
            if slide.background == nil, let ms = master.a("style-name") {
                inContent = false
                let p = props(ms, "drawing-page")
                if let kind = p["fill"], kind != "none" {
                    let f = fill(p, kind: kind)
                    if f != deck.master.background { slide.background = f }
                }
                inContent = true
            }
            if slide.showMasterShapes {
                inContent = false
                for e in master.elements where e.localName != "notes" && e.a("class") == nil { objects += readShape(e, slide: nil) }
                inContent = true
            }
        }
        var ids: [String: Int] = [:]
        var timing: XMLElement?
        for e in page.elements {
            switch e.localName {
            case "notes":
                slide.notes = readNotes(e)
            case "par", "seq":
                timing = e
            case "forms", "animations":
                continue
            default:
                let shapes = readShape(e, slide: slide)
                if let sid = e.a("id"), let first = shapes.first { ids[sid] = first.id }
                objects += shapes
            }
        }
        if let timing {
            // Slide transition and entrance effects (LibreOffice anim:* elements).
            if let filter = timing.elements.first(where: { $0.localName == "par" && ($0.a("begin") ?? "").hasSuffix(".begin") })?.child("transitionFilter") {
                var p: [String: String] = [:]
                for a in filter.attributes ?? [] { if let n = a.localName { p[n] = a.stringValue ?? "" } }
                p["transition-speed"] = dp["transition-speed"]
                p["transition-type"] = dp["transition-type"]
                p["duration"] = dp["duration"]
                let t = transition(p)
                if t.kind != .none { slide.transition.kind = t.kind; slide.transition.direction = t.direction; slide.transition.duration = t.duration }
            }
            for effect in timing.descendants("par") where effect.a("preset-class") == "entrance" {
                let target = effect.descendants("set").first?.a("targetElement") ?? effect.elements.compactMap { $0.a("targetElement") }.first
                guard let target, let id = ids[target] else { continue }
                let preset = effect.a("preset-id") ?? ""
                let build: BuildEffect = preset.contains("appear") ? .appear : preset.contains("fly") ? .flyIn : preset.contains("zoom") ? .zoom : .fade
                for i in objects.indices where objects[i].id == id && objects[i].build == nil { objects[i].build = build }
            }
        }
        // Layout from the placeholders present.
        let classes = objects.compactMap { $0.placeholder?.type }
        let titles = classes.filter { $0 == "title" }.count
        let outlines = classes.filter { $0 == "body" }.count
        let type: String
        if classes.contains("subTitle") { type = "title" }
        else if classes.contains("pic") { type = "picTx" }
        else if outlines >= 2 { type = "twoObj" }
        else if outlines == 1 { type = titles > 0 ? "obj" : "obj" }
        else if titles > 0 { type = "titleOnly" }
        else { type = "blank" }
        let own = page.a("layout").flatMap { deck.layoutIndex(type: $0) }
        slide.layout = own ?? deck.layoutIndex(type: type) ?? 0
        let layoutType = deck.layouts.indices.contains(slide.layout) ? deck.layouts[slide.layout].type : type
        if layoutType == "title" {
            for i in objects.indices where objects[i].placeholder?.type == "title" { objects[i].placeholder?.type = "ctrTitle" }
        }
        var bodyIdx = 1
        for i in objects.indices where objects[i].placeholder?.type == "body" {
            objects[i].placeholder?.idx = bodyIdx
            bodyIdx += 1
        }
        slide.objects = objects
        return slide
    }

    func readNotes(_ notes: XMLElement) -> String {
        for f in notes.descendants("frame") where f.a("class") == "notes" {
            guard let box = f.child("text-box") else { continue }
            return plainText(box).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func plainText(_ e: XMLElement) -> String {
        var lines: [String] = []
        func inline(_ n: XMLNode) -> String {
            if n.kind == .text { return n.stringValue ?? "" }
            guard let el = n as? XMLElement else { return "" }
            switch el.localName {
            case "s": return String(repeating: " ", count: el.int("c") ?? 1)
            case "tab": return "\t"
            case "line-break": return "\n"
            default: return (el.children ?? []).map(inline).joined()
            }
        }
        func visit(_ el: XMLElement) {
            for c in el.elements {
                if c.localName == "p" || c.localName == "h" { lines.append((c.children ?? []).map(inline).joined()) } else { visit(c) }
            }
        }
        visit(e)
        return lines.joined(separator: "\n")
    }

    // MARK: Fill, stroke

    mutating func fill(_ g: [String: String], kind: String) -> Fill {
        let opacity = percent(g["opacity"]) ?? 1
        switch kind {
        case "none": return .none
        case "solid":
            let c = hexColor(g["fill-color"]) ?? PColor(rgb: 0x729FCF)
            return .solid(opacity < 1 ? c.withAlpha(opacity) : c)
        case "gradient":
            guard let gname = g["fill-gradient-name"], let gr = gradients[gname] else { return .solid(hexColor(g["fill-color"]) ?? .white) }
            var a = hexColor(gr.a("start-color")) ?? .black, b = hexColor(gr.a("end-color")) ?? .white
            if let si = percent(gr.a("start-intensity")), si < 1 { a = PColor(a.resolved(deck.theme).blended(withFraction: 1 - si, of: .black) ?? .black) }
            if let ei = percent(gr.a("end-intensity")), ei < 1 { b = PColor(b.resolved(deck.theme).blended(withFraction: 1 - ei, of: .black) ?? .black) }
            var stops = [GradientStop(position: 0, color: a), GradientStop(position: 1, color: b)]
            let extra = gr.children("gradient-stop").compactMap { s -> GradientStop? in
                guard let off = s.a("offset").flatMap(Double.init), let c = hexColor(s.a("color-value")) else { return nil }
                return GradientStop(position: CGFloat(off), color: c)
            }
            if extra.count >= 2 { stops = extra }
            let style = gr.a("style") ?? "linear"
            var angleText = gr.a("angle") ?? "0"
            var angle: CGFloat
            if angleText.hasSuffix("deg") { angleText.removeLast(3); angle = CGFloat(Double(angleText) ?? 0) }
            else if angleText.hasSuffix("rad") { angleText.removeLast(3); angle = CGFloat(Double(angleText) ?? 0) * 180 / .pi }
            else if angleText.hasSuffix("grad") { angleText.removeLast(4); angle = CGFloat(Double(angleText) ?? 0) * 0.9 }
            else { angle = CGFloat(Double(angleText) ?? 0) / 10 }
            if style == "axial" {
                // Axial: end colour in the middle.
                stops = [GradientStop(position: 0, color: b), GradientStop(position: 0.5, color: a), GradientStop(position: 1, color: b)]
            }
            var grad = Gradient(stops: stops, angle: (90 - angle).truncatingRemainder(dividingBy: 360))
            if grad.angle < 0 { grad.angle += 360 }
            if style == "radial" || style == "ellipsoid" || style == "square" || style == "rectangular" {
                grad.radial = true
                grad.stops = [GradientStop(position: 0, color: b), GradientStop(position: 1, color: a)]
            }
            return .gradient(grad)
        case "bitmap":
            if let n = g["fill-image-name"], let href = fillImages[n], let data = zip[href] {
                return .picture(deck.addMedia(data, ext: imageExtension(data)))
            }
            return .none
        default:
            return .none
        }
    }

    func arrowhead(_ name: String?) -> Arrowhead {
        guard let n = name?.lowercased(), !n.isEmpty else { return .none }
        if n.contains("circle") || n.contains("oval") { return .oval }
        if n.contains("square") || n.contains("diamond") { return .diamond }
        if n.contains("line") { return .arrow }
        if n.contains("stealth") || n.contains("concave") { return .stealth }
        return .triangle
    }

    func line(_ g: [String: String]) -> LineStyle {
        var l = LineStyle.none
        let stroke = g["stroke"] ?? "none"
        guard stroke != "none" else { return l }
        l.color = hexColor(g["stroke-color"]) ?? PColor(rgb: 0x3465A4)
        if let o = percent(g["stroke-opacity"]), o < 1 { l.color = l.color?.withAlpha(o) }
        l.width = max(0.5, odfPoints(g["stroke-width"]) ?? 0.75)
        if stroke == "dash" {
            l.dash = .dash
            if let d = g["stroke-dash"].flatMap({ dashes[$0] }) {
                let len1 = d.a("dots1-length") ?? "", dots2 = d.int("dots2") ?? 0
                if dots2 > 0 { l.dash = .dashDot }
                else if let p = percent(len1), p <= 1.5 { l.dash = .dot }
                else if let p = percent(len1), p >= 6 { l.dash = .lgDash }
                else if let v = odfPoints(len1), v < l.width * 1.5 { l.dash = .dot }
            }
        }
        l.head = arrowhead(g["marker-start"])
        l.tail = arrowhead(g["marker-end"])
        return l
    }

    // MARK: Shapes

    mutating func takeID() -> Int {
        nextID += 1
        return nextID - 1
    }

    /// Box from svg:x/y/width/height or draw:transform (rotation in clockwise degrees).
    func geometry(_ e: XMLElement) -> (CGRect, CGFloat) {
        let w = odfPoints(e.a("width")) ?? 0, h = odfPoints(e.a("height")) ?? 0
        var x = odfPoints(e.a("x")) ?? 0, y = odfPoints(e.a("y")) ?? 0
        var rotation: CGFloat = 0
        if let t = e.a("transform") {
            var theta: CGFloat = 0, tx: CGFloat = 0, ty: CGFloat = 0
            let scanner = t.replacingOccurrences(of: ",", with: " ")
            var rest = Substring(scanner)
            while let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") {
                let name = rest[..<open].trimmingCharacters(in: .whitespaces)
                let args = rest[rest.index(after: open)..<close].split(separator: " ").map(String.init)
                switch name {
                case "rotate": theta += CGFloat(Double(args.first ?? "0") ?? 0)
                case "translate":
                    tx += odfPoints(args.first) ?? 0
                    ty += odfPoints(args.count > 1 ? args[1] : "0") ?? 0
                default: break
                }
                rest = rest[rest.index(after: close)...]
            }
            let cx = tx + (w / 2) * cos(theta) + (h / 2) * sin(theta)
            let cy = ty - (w / 2) * sin(theta) + (h / 2) * cos(theta)
            x = cx - w / 2
            y = cy - h / 2
            rotation = -theta * 180 / .pi
            rotation = rotation.truncatingRemainder(dividingBy: 360)
            if rotation < 0 { rotation += 360 }
            if abs(rotation) < 0.01 || abs(rotation - 360) < 0.01 { rotation = 0 }
        }
        return (CGRect(x: x, y: y, width: w, height: h), rotation)
    }

    func placeholder(_ cls: String?) -> Placeholder? {
        switch cls {
        case "title": return Placeholder(type: "title", idx: nil)
        case "subtitle": return Placeholder(type: "subTitle", idx: 1)
        case "outline", "text": return Placeholder(type: "body", idx: 1)
        case "graphic", "object", "chart", "table": return cls == "graphic" ? Placeholder(type: "pic", idx: 1) : nil
        case "date-time": return Placeholder(type: "dt", idx: 10)
        case "footer": return Placeholder(type: "ftr", idx: 11)
        case "page-number": return Placeholder(type: "sldNum", idx: 12)
        default: return nil
        }
    }

    static let prstByType: [String: String] = {
        var m: [String: String] = [:]
        for (k, v) in [
            "rect": "rectangle", "roundRect": "round-rectangle", "ellipse": "ellipse", "triangle": "isosceles-triangle",
            "rtTriangle": "right-triangle", "diamond": "diamond", "parallelogram": "parallelogram", "trapezoid": "trapezoid",
            "pentagon": "pentagon", "hexagon": "hexagon", "octagon": "octagon", "star5": "star5", "star4": "star4", "star6": "star6", "star8": "star8",
            "plus": "cross", "heart": "heart", "donut": "ring", "rightArrow": "right-arrow", "leftArrow": "left-arrow",
            "upArrow": "up-arrow", "downArrow": "down-arrow", "leftRightArrow": "left-right-arrow", "chevron": "chevron",
            "homePlate": "pentagon-right", "wedgeRectCallout": "rectangular-callout", "wedgeRoundRectCallout": "round-rectangular-callout",
            "wedgeEllipseCallout": "round-callout", "cloud": "cloud", "cloudCallout": "cloud-callout", "can": "can",
            "flowChartProcess": "flowchart-process", "flowChartDecision": "flowchart-decision", "flowChartTerminator": "flowchart-terminator",
            "flowChartDocument": "flowchart-document", "flowChartConnector": "flowchart-connector", "flowChartAlternateProcess": "flowchart-alternate-process",
            "flowChartInputOutput": "flowchart-data", "flowChartExtract": "flowchart-extract",
        ] { m[v] = k }
        m["circle"] = "ellipse"; m["frame"] = "rect"; m["paper"] = "rect"; m["star24"] = "star8"; m["star12"] = "star8"
        m["mso-spt100"] = "rect"; m["quad-bevel"] = "rect"; m["octagon-bevel"] = "octagon"; m["circle-pie"] = "ellipse"
        m["flowchart-predefined-process"] = "rect"; m["flowchart-internal-storage"] = "rect"; m["flowchart-preparation"] = "hexagon"
        m["flowchart-manual-input"] = "rect"; m["flowchart-manual-operation"] = "trapezoid"; m["flowchart-off-page-connector"] = "pentagon"
        m["notched-right-arrow"] = "rightArrow"; m["striped-right-arrow"] = "rightArrow"; m["mso-spt89"] = "upArrow"
        return m
    }()

    /// Graphic and text-area properties of a styled element (draw:style-name or presentation:style-name).
    func graphicProps(_ e: XMLElement) -> [String: String] {
        var p = props(e.a("style-name"), "graphic")
        if let ps = e.attributes?.first(where: { $0.localName == "style-name" && ($0.name ?? "").hasPrefix("presentation") })?.stringValue {
            p.merge(props(ps, "graphic")) { a, _ in a }
        }
        return p
    }

    func styleName(_ e: XMLElement) -> String? {
        e.attributes?.first { $0.localName == "style-name" && ($0.name ?? "").hasPrefix("draw") }?.stringValue
            ?? e.attributes?.first { $0.localName == "style-name" && ($0.name ?? "").hasPrefix("presentation") }?.stringValue
    }

    mutating func applyGraphics(_ g: [String: String], to o: inout SlideObject) {
        o.fill = fill(g, kind: g["fill"] ?? "none")
        if case .solid(let c) = o.fill, c.alpha < 1, o.kind != .picture {
            // Fill transparency becomes the object's opacity (as our renderer applies it).
            o.opacity = c.alpha
            o.fill = .solid(c.withAlpha(1))
            if let lc = o.line.color { o.line.color = lc.withAlpha(1) }
        }
        o.line = line(g)
        o.shadow = g["shadow"] == "visible"
    }

    func textBodyProps(_ g: [String: String], into t: inout TextBody) {
        switch g["textarea-vertical-align"] {
        case "middle": t.anchor = .middle
        case "bottom": t.anchor = .bottom
        default: t.anchor = .top
        }
        t.insets = NSEdgeInsets(top: odfPoints(g["padding-top"]) ?? odfPoints(g["padding"]) ?? 3.6,
                                left: odfPoints(g["padding-left"]) ?? odfPoints(g["padding"]) ?? 7.2,
                                bottom: odfPoints(g["padding-bottom"]) ?? odfPoints(g["padding"]) ?? 3.6,
                                right: odfPoints(g["padding-right"]) ?? odfPoints(g["padding"]) ?? 7.2)
        t.wrap = g["wrap-option"] != "no-wrap"
        if g["shrink-to-fit"] == "true" || g["fit-to-size"] == "shrink-to-fit" { t.autofit = .shrink }
        else if g["auto-grow-height"] == "true" { t.autofit = .resize }
        else { t.autofit = .none }
    }

    mutating func readShape(_ e: XMLElement, slide: Slide?) -> [SlideObject] {
        let g = graphicProps(e)
        let cls = e.a("class")
        let (frame, rotation) = geometry(e)
        var o = SlideObject(id: takeID(), kind: .shape, frame: frame)
        o.rotation = rotation
        o.name = e.a("name") ?? ""
        o.descr = e.child("desc")?.stringValue ?? ""
        switch e.localName {
        case "frame":
            o.placeholder = placeholder(cls)
            if let obj = e.child("object"), let href = obj.a("href") {
                let dir = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                if let root = xmlRoot(zip["\(dir)/content.xml"]), var m = ChartODF.read(root) {
                    var files: [String: Data] = [:]
                    for (name, data) in zip.entries where name.hasPrefix(dir + "/") { files[String(name.dropFirst(dir.count + 1))] = data }
                    m.original = ChartOriginal(model: m, part: nil, odf: files)
                    o.kind = .chart
                    o.chart = m
                    o.placeholder = nil
                    applyGraphics(g, to: &o)
                    o.shadow = false
                    return [o]
                }
            }
            if let img = e.child("image") ?? e.child("object")?.child("image"), e.child("text-box") == nil, e.child("table") == nil, e.child("plugin") == nil {
                o.kind = .picture
                if let href = img.a("href"), let data = zip[href] { o.media = deck.addMedia(data, ext: imageExtension(data)) }
                // A replacement picture of an embedded object comes after it.
                if o.media == nil, let alt = e.children("image").last, let href = alt.a("href"), let data = zip[href] { o.media = deck.addMedia(data, ext: imageExtension(data)) }
                applyGraphics(g, to: &o)
                o.fill = .none
                if let op = percent(g["image-opacity"]) { o.opacity = op }
                if o.media == nil && o.placeholder == nil { return [] }
                if e.child("object") != nil { o.unsupported = nil }
                return [o]
            }
            if let plugin = e.child("plugin"), let href = plugin.a("href"), let data = zip[href.hasPrefix("./") ? String(href.dropFirst(2)) : href] {
                o.kind = .picture
                o.placeholder = nil
                let ext = (href as NSString).pathExtension.lowercased()
                var clip = MediaClip(media: deck.addClip(data, ext: ext.isEmpty ? "mp4" : ext))
                clip.audio = MediaClip.isAudio(ext)
                for p in plugin.children("param") {
                    if p.a("name") == "Loop" { clip.loop = p.a("value") == "true" }
                    if p.a("name") == "ppt42-autoplay" { clip.autoplay = p.a("value") == "true" }
                }
                o.clip = clip
                if let img = e.child("image"), let ih = img.a("href"), let d = zip[ih] { o.media = deck.addMedia(d, ext: imageExtension(d)) }
                if o.media == nil, let poster = MediaFiles.audioPoster() { o.media = deck.addMedia(poster, ext: "png") }
                applyGraphics(g, to: &o)
                o.fill = .none
                return [o]
            }
            if e.child("object") != nil || e.child("plugin") != nil {
                o.kind = .shape
                o.unsupported = L("Object (not supported)")
                o.placeholder = nil
                return [o]
            }
            if let tbl = e.child("table") {
                o.kind = .table
                o.placeholder = nil
                o.table = readTable(tbl, slide: slide, size: frame.size)
                return [o]
            }
            o.kind = .textBox
            applyGraphics(g, to: &o)
            var t = TextBody()
            textBodyProps(g, into: &t)
            if let box = e.child("text-box") {
                t.paragraphs = readParagraphs(box, frameStyle: styleName(e), cls: cls)
            }
            if e.a("placeholder") == "true" {
                t.paragraphs = [Paragraph()]
                if o.placeholder?.isFooter == true { return [] }
            }
            o.text = t
            return [o]
        case "custom-shape", "rect", "ellipse", "circle", "polygon", "polyline", "path", "regular-polygon":
            o.kind = .shape
            if e.localName == "custom-shape", let geo = e.child("enhanced-geometry") {
                let type = geo.a("type") ?? "rectangle"
                if let mods = geo.a("modifiers"), type.hasPrefix("ooxml-") {
                    // OOXML presets: modifiers are adj, adj1, adj2… in order.
                    let vals = mods.split(separator: " ").compactMap { Double($0) }
                    let names = vals.count == 1 ? ["adj"] : (1...max(1, vals.count)).map { "adj\($0)" }
                    for (n, v) in Swift.zip(names, vals) where Shapes.defaults[String(type.dropFirst(6))] != nil { o.adjust[n] = Int(v) }
                }
                if let ours = geo.a("prst") { o.geometry = ours }
                else if type.hasPrefix("ooxml-") { o.geometry = String(type.dropFirst(6)) }
                else { o.geometry = Self.prstByType[type] ?? "rect" }
                if let mods = geo.a("modifiers"), type.hasPrefix("ooxml-"), let def = PresetDef.all[o.geometry] {
                    let vals = mods.split(separator: " ").compactMap { Double($0) }
                    for (n, v) in Swift.zip(def.adjNames, vals) { o.adjust[n] = Int(v) }
                }
                // Our own custom outlines, and shapes LibreOffice has no preset for: the literal path.
                if o.geometry == "custom" || (Self.prstByType[type] == nil && !type.hasPrefix("ooxml-")) || type == "non-primitive" {
                    if let d = geo.a("enhanced-path"), let c = Self.literalPath(d, viewBox: geo.a("viewBox"), size: frame.size) {
                        o.custom = c
                        o.geometry = "custom"
                    } else if o.geometry == "custom" {
                        o.geometry = "rect"
                    }
                }
                o.flipH = geo.a("mirror-horizontal") == "true"
                o.flipV = geo.a("mirror-vertical") == "true"
                if let adj = geo.a("adjust") {
                    for pair in adj.split(separator: ";") {
                        let kv = pair.split(separator: "=")
                        if kv.count == 2, let v = Int(kv[1]) { o.adjust[String(kv[0])] = v }
                    }
                }
                if o.geometry == "line" || o.geometry == "straightConnector1" { o.kind = .line }
            } else if e.localName == "ellipse" || e.localName == "circle" {
                o.geometry = "ellipse"
            } else if e.localName == "rect", let r = odfPoints(e.a("corner-radius")), r > 0 {
                o.geometry = "roundRect"
                o.adjust["adj"] = Int(min(50000, r / max(1, min(frame.width, frame.height)) * 100000))
            } else if e.localName == "regular-polygon" {
                let n = e.int("corners") ?? 5
                o.geometry = e.a("concave") == "true" ? "star5" : n == 3 ? "triangle" : n == 6 ? "hexagon" : n == 8 ? "octagon" : "pentagon"
            }
            if e.localName == "polyline" || e.localName == "polygon" || e.localName == "path" {
                var d = e.a("d") ?? ""
                if e.localName != "path", let pts = e.a("points") {
                    let nums = pts.replacingOccurrences(of: ",", with: " ").split(separator: " ")
                    d = "M " + nums.joined(separator: " ")
                    if e.localName == "polygon" { d += " Z" }
                }
                if let c = Self.literalPath(d, viewBox: e.a("viewBox"), size: frame.size, svg: true, open: e.localName == "polyline") {
                    o.custom = c
                    o.geometry = "custom"
                } else {
                    o.geometry = "rect"
                }
            }
            applyGraphics(g, to: &o)
            if e.localName == "polyline" { o.fill = .none }
            var t = TextBody()
            textBodyProps(g, into: &t)
            if g["textarea-vertical-align"] == nil { t.anchor = .middle }
            let paras = readParagraphs(e, frameStyle: styleName(e), cls: nil)
            t.paragraphs = paras
            o.text = t
            return [o]
        case "line", "connector", "measure":
            o.kind = .line
            o.geometry = "line"
            let a = CGPoint(x: odfPoints(e.a("x1")) ?? 0, y: odfPoints(e.a("y1")) ?? 0)
            let b = CGPoint(x: odfPoints(e.a("x2")) ?? 0, y: odfPoints(e.a("y2")) ?? 0)
            o.setLine(from: a, to: b)
            o.rotation = 0
            o.line = line(g)
            if o.line.color == nil, g["stroke"] == nil { o.line = LineStyle(color: .black, width: 1) }
            if o.line.tail != .none || o.line.head != .none { o.geometry = "straightConnector1" }
            o.shadow = g["shadow"] == "visible"
            return [o]
        case "g":
            var children: [SlideObject] = []
            for c in e.elements { children += readShape(c, slide: slide) }
            guard !children.isEmpty else { return [] }
            o.kind = .group
            o.frame = children.dropFirst().reduce(children[0].frame) { $0.union($1.frame) }
            o.rotation = 0
            o.children = children
            return [o]
        default:
            return []
        }
    }

    /// A path of plain numbers (svg:d or a draw:enhanced-path without formulas) as custom geometry in viewBox units.
    static func literalPath(_ d: String, viewBox: String?, size: CGSize, svg: Bool = false, open: Bool = false) -> CustomGeometry? {
        guard !d.contains("?"), !d.contains("$") else { return nil }
        // Tokens: command letters and numbers.
        var toks: [String] = []
        var cur = ""
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { if !cur.isEmpty { toks.append(cur); cur = "" }; toks.append(String(ch)) }
            else if ch == " " || ch == "," { if !cur.isEmpty { toks.append(cur); cur = "" } }
            else if ch == "-" && !cur.isEmpty && !(cur.last == "e" || cur.last == "E") { toks.append(cur); cur = "-" }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { toks.append(cur) }
        let vb = (viewBox ?? "").split(separator: " ").compactMap { Double($0) }
        let vx = vb.count == 4 ? vb[0] : 0, vy = vb.count == 4 ? vb[1] : 0
        let vw = vb.count == 4 && vb[2] > 0 ? vb[2] : Double(size.width * 100), vh = vb.count == 4 && vb[3] > 0 ? vb[3] : Double(size.height * 100)
        let path = CGMutablePath()
        var i = 0, cmd = "M"
        var p = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?
        var fill = true, stroke = true
        func num() -> CGFloat? {
            guard i < toks.count, let v = Double(toks[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        func pt(_ rel: Bool) -> CGPoint? {
            guard let x = num(), let y = num() else { return nil }
            return rel ? CGPoint(x: p.x + x, y: p.y + y) : CGPoint(x: x - CGFloat(vx), y: y - CGFloat(vy))
        }
        var guardCount = 0
        while i < toks.count, guardCount < 100000 {
            guardCount += 1
            if Double(toks[i]) == nil { cmd = toks[i]; i += 1 }
            let rel = svg && cmd == cmd.lowercased() && cmd != "N" && cmd != "F" && cmd != "S"
            switch cmd.uppercased() {
            case "M":
                guard let q = pt(rel) else { i += 1; continue }
                path.move(to: q); p = q; start = q
                cmd = rel ? "l" : "L"
            case "L":
                guard let q = pt(rel) else { i += 1; continue }
                if path.isEmpty { path.move(to: q) } else { path.addLine(to: q) }
                p = q
            case "H":
                guard let x = num() else { i += 1; continue }
                p = CGPoint(x: rel ? p.x + x : x - CGFloat(vx), y: p.y); path.addLine(to: p)
            case "V":
                guard let y = num() else { i += 1; continue }
                p = CGPoint(x: p.x, y: rel ? p.y + y : y - CGFloat(vy)); path.addLine(to: p)
            case "C":
                guard let a = pt(rel), let b = pt(rel), let q = pt(rel) else { i += 1; continue }
                path.addCurve(to: q, control1: a, control2: b); p = q; lastCtrl = b
                continue
            case "S":
                if !svg { stroke = false; continue }
                guard let b = pt(rel), let q = pt(rel) else { i += 1; continue }
                let a = lastCtrl.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                path.addCurve(to: q, control1: a, control2: b); p = q; lastCtrl = b
                continue
            case "Q":
                guard let a = pt(rel), let q = pt(rel) else { i += 1; continue }
                path.addQuadCurve(to: q, control: a); p = q
            case "Z":
                path.closeSubpath(); p = start
            case "N": break
            case "F": if !svg { fill = false } else { i += 1 }
            default:
                // Arcs and other commands: not literal enough.
                return nil
            }
            lastCtrl = nil
        }
        guard !path.isEmpty else { return nil }
        // Into points of the shape box, then the stored path units (1/100 pt).
        let sx = size.width / CGFloat(vw), sy = size.height / CGFloat(vh)
        var t = CGAffineTransform(scaleX: sx, y: sy)
        guard let scaled = path.copy(using: &t) else { return nil }
        return CustomGeometry(path: scaled, size: size, fill: (fill && !open) ? .norm : .none, stroke: stroke)
    }

    // MARK: Tables

    mutating func readTable(_ tbl: XMLElement, slide: Slide?, size: CGSize) -> TableModel {
        var widths: [CGFloat] = []
        var columnCellStyles: [String?] = []
        for c in tbl.descendants("table-column") {
            let w = odfPoints(props(c.a("style-name"), "table-column")["column-width"]) ?? 0
            for _ in 0..<max(1, c.int("number-columns-repeated") ?? 1) {
                widths.append(w)
                columnCellStyles.append(c.a("default-cell-style-name"))
            }
        }
        let rows = tbl.descendants("table-row")
        let cols = max(widths.count, rows.map { $0.elements.filter { $0.localName == "table-cell" || $0.localName == "covered-table-cell" }.count }.max() ?? 1)
        while widths.count < cols { widths.append(0) }
        let known = widths.filter { $0 > 0 }.reduce(0, +)
        let missing = widths.filter { $0 <= 0 }.count
        if missing > 0 { widths = widths.map { $0 > 0 ? $0 : max(20, (size.width - known) / CGFloat(missing)) } }
        var t = TableModel(rows: max(1, rows.count), columns: max(1, cols), width: widths.reduce(0, +))
        t.columns = widths.isEmpty ? [size.width] : widths
        t.firstRow = false
        t.bandRows = false
        t.borderColor = nil
        t.borderWidth = 0
        for (ri, tr) in rows.enumerated() {
            t.rows[ri] = odfPoints(props(tr.a("style-name"), "table-row")["row-height"] ?? props(tr.a("style-name"), "table-row")["min-row-height"]) ?? 28
            var ci = 0
            for c in tr.elements where c.localName == "table-cell" || c.localName == "covered-table-cell" {
                guard ci < t.columns.count else { break }
                var cell = TableCell()
                if c.localName == "covered-table-cell" {
                    cell.merged = true
                } else {
                    cell.gridSpan = c.int("number-columns-spanned") ?? 1
                    cell.rowSpan = c.int("number-rows-spanned") ?? 1
                    let sn = c.a("style-name") ?? tr.a("default-cell-style-name") ?? (columnCellStyles.indices.contains(ci) ? columnCellStyles[ci] : nil)
                    var g = props(sn, "graphic")
                    g.merge(props(sn, "table-cell")) { a, _ in a }
                    let pp = props(sn, "paragraph")
                    let f = fill(g, kind: g["fill"] ?? (g["background-color"].map { $0 == "transparent" ? "none" : "solid" } ?? "none"))
                    cell.fill = f
                    if case .none = f, let bg = hexColor(g["background-color"]) { cell.fill = .solid(bg) }
                    let border = pp["border"] ?? pp["border-top"] ?? g["border"] ?? g["border-top"]
                    if t.borderColor == nil, let b = border, b != "none" {
                        let parts = b.split(separator: " ").map(String.init)
                        t.borderWidth = odfPoints(parts.first) ?? 0.75
                        t.borderColor = hexColor(parts.last) ?? .black
                    }
                    var body = TextBody()
                    body.insets = NSEdgeInsets(top: odfPoints(pp["padding-top"] ?? g["padding-top"]) ?? 3.6, left: odfPoints(pp["padding-left"] ?? g["padding-left"]) ?? 7.2,
                                               bottom: odfPoints(pp["padding-bottom"] ?? g["padding-bottom"]) ?? 3.6, right: odfPoints(pp["padding-right"] ?? g["padding-right"]) ?? 7.2)
                    let va = g["textarea-vertical-align"] ?? g["vertical-align"]
                    body.anchor = va == "middle" ? .middle : va == "bottom" ? .bottom : .top
                    body.paragraphs = readParagraphs(c, frameStyle: nil, cls: nil)
                    cell.text = body
                }
                t.cells[ri][ci] = cell
                ci += 1
            }
        }
        return t
    }

    // MARK: Text

    struct ListContext {
        var style: XMLElement?
        var depth: Int
        var header: Bool
    }

    /// Bullet of a list level, its label width and its position (text:space-before).
    func bullet(_ list: XMLElement?, level: Int) -> (Bullet, CGFloat?, CGFloat) {
        guard let list else { return (Bullet.none, nil, 0) }
        let lv = list.elements.first { ($0.int("level") ?? 0) == level + 1 }
        guard let lv else { return (Bullet.none, nil, 0) }
        let lp = lv.child("list-level-properties")
        let label = odfPoints(lp?.a("min-label-width"))
        let before = odfPoints(lp?.a("space-before")) ?? 0
        let tp = lv.child("text-properties")
        var b: Bullet
        switch lv.localName {
        case "list-level-style-bullet":
            let ch = lv.a("bullet-char") ?? "•"
            if ch.isEmpty || ch == " " { return (Bullet.none, label, before) }
            b = Bullet(kind: .char, char: ch)
            if let f = tp?.a("font-family") { b.font = f.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            if b.font == "StarSymbol" || b.font == "OpenSymbol" { b.font = nil }
        case "list-level-style-number":
            let fmt = lv.a("num-format") ?? ""
            if fmt.isEmpty { return (Bullet.none, label, before) }
            let suffix = lv.a("num-suffix") ?? "", prefix = lv.a("num-prefix") ?? ""
            var scheme = fmt == "a" ? "alphaLc" : fmt == "A" ? "alphaUc" : fmt == "i" ? "romanLc" : fmt == "I" ? "romanUc" : "arabic"
            scheme += prefix == "(" ? "ParenBoth" : suffix == ")" ? "ParenR" : suffix.isEmpty ? "Plain" : "Period"
            b = Bullet(kind: .number, scheme: scheme, startAt: lv.int("start-value") ?? 1)
        default:
            return (Bullet.none, label, before)
        }
        if let c = hexColor(tp?.a("color")) { b.color = c }
        if let p = percent(tp?.a("font-size")), abs(p - 1) > 0.01 { b.sizePercent = p }
        return (b, label, before)
    }

    func runProps(_ p: [String: String]) -> RunProps {
        var r = RunProps()
        if let f = p["font-family"] { r.font = f.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        else if let n = p["font-name"] { r.font = fontFaces[n] ?? n }
        if let s = p["font-size"], let v = odfPoints(s) { r.size = v }
        if let w = p["font-weight"] { r.bold = w == "bold" || (Int(w) ?? 400) >= 600 }
        if let s = p["font-style"] { r.italic = s == "italic" || s == "oblique" }
        if let u = p["text-underline-style"] { r.underline = u != "none" }
        if let s = p["text-line-through-style"] { r.strike = s != "none" }
        if let c = hexColor(p["color"]) { r.color = c }
        if let pos = p["text-position"] {
            if pos.hasPrefix("super") { r.baseline = 30 } else if pos.hasPrefix("sub") { r.baseline = -25 }
            else if let v = percent(pos.split(separator: " ").first.map(String.init)), v != 0 { r.baseline = v * 100 }
        }
        return r
    }

    /// Paragraphs of a text container: text:p / text:h, lists (nested = levels), list headers (no bullet).
    func readParagraphs(_ container: XMLElement, frameStyle: String?, cls: String?) -> [Paragraph] {
        var out: [Paragraph] = []
        let frameList = embeddedList(frameStyle)
        func visit(_ el: XMLElement, list: ListContext?) {
            for c in el.elements {
                switch c.localName {
                case "p", "h":
                    out.append(paragraph(c, list: list, frameStyle: frameStyle, frameList: frameList, cls: cls))
                case "list":
                    let style = c.a("style-name").flatMap { lists[$0] } ?? list?.style
                    let depth = list.map { $0.depth + 1 } ?? 0
                    visit(c, list: ListContext(style: style, depth: depth, header: false))
                case "list-item":
                    visit(c, list: list)
                case "list-header":
                    visit(c, list: list.map { ListContext(style: $0.style, depth: $0.depth, header: true) })
                case "soft-page-break", "enhanced-geometry", "desc", "title":
                    continue
                default:
                    continue
                }
            }
        }
        visit(container, list: nil)
        return out.isEmpty ? [Paragraph()] : out
    }

    func paragraph(_ p: XMLElement, list: ListContext?, frameStyle: String?, frameList: XMLElement?, cls: String?) -> Paragraph {
        var para = Paragraph()
        let level = list?.depth ?? 0
        para.level = level
        // Base text formatting: the frame's style (outline levels use their own presentation styles), then the paragraph's.
        var baseName = frameStyle
        if cls == "outline", level > 0, style("\(masterName)-outline\(level + 1)") != nil { baseName = "\(masterName)-outline\(level + 1)" }
        var tp = props(baseName, "text")
        var pp = props(baseName, "paragraph")
        tp.merge(props(p.a("style-name"), "text")) { _, b in b }
        pp.merge(props(p.a("style-name"), "paragraph")) { _, b in b }
        let base = runProps(tp)

        var s = LevelStyle()
        switch pp["text-align"] {
        case "center": s.align = .center
        case "end", "right": s.align = .right
        case "justify": s.align = .justify
        default: s.align = .left
        }
        var marL = odfPoints(pp["margin-left"]) ?? 0
        var indent = odfPoints(pp["text-indent"]) ?? 0
        s.spaceBefore = odfPoints(pp["margin-top"]) ?? 0
        s.spaceAfter = odfPoints(pp["margin-bottom"]) ?? 0
        if let lh = pp["line-height"] {
            if let v = percent(lh) { s.lineSpacing = v } else if let v = odfPoints(lh) { s.lineSpacing = -v }
        } else if let v = percent(pp["line-height-at-least"]) { s.lineSpacing = v }
        else { s.lineSpacing = 1 }
        var b = Bullet.none
        if let list, !list.header {
            let (bu, label, before) = bullet(list.style ?? frameList, level: level)
            b = bu
            if bu.kind != .none {
                // LibreOffice: the label starts at margin + space-before, the text after the label width.
                let lw = label ?? 0
                marL = marL + before + lw
                indent = indent - lw
            }
        }
        s.bullet = b
        s.marL = marL
        s.indent = indent
        para.props = s

        // Runs
        var runs: [TextRun] = []
        func add(_ text: String, _ props: RunProps, field: String? = nil, link: String? = nil) {
            guard !text.isEmpty || field != nil else { return }
            if field == nil, let last = runs.last, last.props == props, last.field == nil, last.link == link {
                runs[runs.count - 1].text += text
            } else {
                runs.append(TextRun(text: text, props: props, field: field, link: link))
            }
        }
        func inline(_ n: XMLNode, _ rp: RunProps, link: String?) {
            if n.kind == .text {
                // Whitespace in ODF text collapses to single spaces.
                var t = n.stringValue ?? ""
                t = t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: " ")
                while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
                add(t, rp, link: link)
                return
            }
            guard let el = n as? XMLElement else { return }
            switch el.localName {
            case "span":
                let own = runProps(self.props(el.a("style-name"), "text")).over(rp)
                for c in el.children ?? [] { inline(c, own, link: link) }
            case "a":
                let href = el.a("href")
                let own = runProps(self.props(el.a("style-name"), "text")).over(rp)
                for c in el.children ?? [] { inline(c, own, link: href) }
            case "s": add(String(repeating: " ", count: max(1, el.int("c") ?? 1)), rp, link: link)
            case "tab": add("\t", rp, link: link)
            case "line-break": add("\u{0B}", rp, link: link)
            case "page-number": add(el.stringValue ?? "", rp, field: "slidenum")
            case "date", "time": add(el.stringValue ?? "", rp, field: "datetime")
            case "note", "annotation", "bookmark", "bookmark-start", "bookmark-end", "soft-page-break": break
            default:
                for c in el.children ?? [] { inline(c, rp, link: link) }
            }
        }
        for c in p.children ?? [] { inline(c, base, link: nil) }
        para.runs = runs
        para.endProps = base
        return para
    }
}

