import AppKit
import Kit42

/// Writes a Deck as an OpenDocument presentation (.odp). Every property is written explicitly
/// (colours flattened with the theme, inherited text styles resolved), so LibreOffice shows what we draw.
enum ODPWriter {
    static func data(_ deck: Deck, template: Bool = false) -> Data {
        var w = ODPWriterImpl(deck: deck)
        w.template = template
        return w.write()
    }
}

// MARK: - Helpers

func odfLength(_ pt: CGFloat) -> String {
    let v = pt / pointsPerCm
    return String(format: "%.4fcm", abs(v) < 0.00005 ? 0 : v)
}

private func pct(_ v: CGFloat) -> String { String(format: "%.0f%%", v * 100) }

/// Text with ODF whitespace elements (runs of spaces, tabs, line breaks).
func odfText(_ s: String) -> String {
    var out = ""
    var spaces = 0
    var atStart = true
    func flush() {
        guard spaces > 0 else { return }
        if atStart || spaces > 1 {
            // A leading space or a run of spaces needs text:s.
            let first = atStart ? 0 : 1
            if first == 1 { out += " " }
            let n = spaces - first
            if n > 0 { out += n == 1 ? "<text:s/>" : "<text:s text:c=\"\(n)\"/>" }
        } else {
            out += " "
        }
        spaces = 0
    }
    for ch in s {
        switch ch {
        case " ": spaces += 1
        case "\t": flush(); out += "<text:tab/>"; atStart = false
        case "\u{0B}": flush(); out += "<text:line-break/>"; atStart = true
        case "\r", "\n", "\r\n", "\u{2028}":
            flush()
            let kind = ch == "\r" ? "cr" : ch == "\n" ? "lf" : ch == "\r\n" ? "crlf" : "ls"
            // Foreign attributes are ignored by other ODF readers, which still display a line break.
            out += "<text:line-break ppt42:character=\"\(kind)\"/>"
            atStart = true
        default:
            flush()
            out += presentationXMLEscape(String(ch))
            atStart = false
        }
    }
    flush()
    return out
}

/// Automatic styles of one part (content.xml or styles.xml), deduplicated.
private final class ODFAutoStyles {
    let prefix: String
    var xml = ""
    private var names: [String: String] = [:]
    private var counters: [String: Int] = [:]

    init(prefix: String) { self.prefix = prefix }

    func style(_ family: String, _ short: String, _ body: String, attrs: String = "") -> String {
        let key = family + "|" + attrs + "|" + body
        if let n = names[key] { return n }
        counters[short, default: 0] += 1
        let name = prefix + short + "\(counters[short]!)"
        names[key] = name
        xml += "<style:style style:name=\"\(name)\" style:family=\"\(family)\"\(attrs)>\(body)</style:style>"
        return name
    }

    func listStyle(_ body: String) -> String {
        let key = "list|" + body
        if let n = names[key] { return n }
        counters["L", default: 0] += 1
        let name = prefix + "L\(counters["L"]!)"
        names[key] = name
        xml += "<text:list-style style:name=\"\(name)\">\(body)</text:list-style>"
        return name
    }
}

/// Named drawing styles (gradients, markers, dashes, fill images) shared by both parts (office:styles).
private final class ODFShared {
    var xml = ""
    private var names: [String: String] = [:]
    var pictures: [String: String] = [:]   // media name → zip path
    /// Embedded sub-documents (charts): directory → files, plus manifest entries (path, media type).
    var files: [String: Data] = [:]
    var manifest: [(String, String)] = []
    var objectCount = 0

    func named(_ kind: String, _ make: (String) -> String) -> String {
        if let n = names[kind] { return n }
        let name = "PPT42_\(names.count + 1)"
        names[kind] = name
        xml += make(name)
        return name
    }

    func picture(_ media: String) -> String {
        if let p = pictures[media] { return p }
        let p = "Pictures/\(media)"
        pictures[media] = p
        return p
    }
}

private struct ODPWriterImpl {
    let deck: Deck
    var template = false
    var theme: Theme { deck.theme }
    let shared = ODFShared()

    init(deck: Deck) { self.deck = deck }

    // MARK: Document

    mutating func write() -> Data {
        let content = contentXML()
        let styles = stylesXML()
        var zip = ZipArchive()
        let mime = template ? "application/vnd.oasis.opendocument.presentation-template" : "application/vnd.oasis.opendocument.presentation"
        zip["mimetype"] = Data(mime.utf8)
        zip.storedUncompressed.insert("mimetype")
        zip["content.xml"] = Data(content.utf8)
        zip["styles.xml"] = Data(styles.utf8)
        zip["meta.xml"] = Data(metaXML().utf8)
        var manifest = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">"
        manifest += "<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"\(mime)\"/>"
        for f in ["content.xml", "styles.xml", "meta.xml"] { manifest += "<manifest:file-entry manifest:full-path=\"\(f)\" manifest:media-type=\"text/xml\"/>" }
        for (media, path) in shared.pictures.sorted(by: { $0.key < $1.key }) {
            guard let data = deck.media[media] else { continue }
            zip[path] = data
            let ext = (media as NSString).pathExtension.lowercased()
            let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "svg" ? "image/svg+xml" : "image/\(ext)"
            manifest += "<manifest:file-entry manifest:full-path=\"\(presentationXMLEscape(path))\" manifest:media-type=\"\(mime)\"/>"
        }
        for (path, data) in shared.files { zip[path] = data }
        for (path, type) in shared.manifest { manifest += "<manifest:file-entry manifest:full-path=\"\(presentationXMLEscape(path))\" manifest:media-type=\"\(type)\"/>" }
        manifest += "</manifest:manifest>"
        zip["META-INF/manifest.xml"] = Data(manifest.utf8)
        return zip.data()
    }

    static let ns = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
    xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
    xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0" \
    xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:smil="urn:oasis:names:tc:opendocument:xmlns:smil-compatible:1.0" \
    xmlns:anim="urn:oasis:names:tc:opendocument:xmlns:animation:1.0" xmlns:officeooo="http://openoffice.org/2009/office" xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" xmlns:ppt42="urn:sfzorin:ppt42" office:version="1.3"
    """

    func metaXML() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-meta \(Self.ns)><office:meta><meta:generator>PPT42</meta:generator>"
            + "<dc:title>\(presentationXMLEscape(deck.slides.first?.title.replacingOccurrences(of: "\u{0B}", with: " ") ?? ""))</dc:title><meta:creation-date>\(now)</meta:creation-date><dc:date>\(now)</dc:date></office:meta></office:document-meta>"
    }

    func contentXML() -> String {
        let auto = ODFAutoStyles(prefix: "")
        var body = ""
        for (i, slide) in deck.slides.enumerated() {
            body += page(slide, index: i, styles: auto)
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content \(Self.ns)><office:automatic-styles>\(auto.xml)</office:automatic-styles>"
            + "<office:body><office:presentation>\(body)<presentation:settings presentation:mouse-visible=\"true\"/></office:presentation></office:body></office:document-content>"
    }

    func stylesXML() -> String {
        let auto = ODFAutoStyles(prefix: "M")
        // Master page: background and the master's decorative shapes.
        let bg = drawingPageProps(deck.master.background, slide: nil)
        let masterDP = auto.style("drawing-page", "dp", "<style:drawing-page-properties draw:background-size=\"full\"\(bg)/>")
        var masterShapes = ""
        for o in deck.master.objects { masterShapes += object(o, slide: nil, number: deck.firstSlideNumber, styles: auto) }
        let pageLayout = "<style:page-layout style:name=\"PM1\"><style:page-layout-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:page-width=\"\(odfLength(deck.size.width))\" fo:page-height=\"\(odfLength(deck.size.height))\" style:print-orientation=\"\(deck.size.width >= deck.size.height ? "landscape" : "portrait")\"/></style:page-layout>"
            + "<style:page-layout style:name=\"PM2\"><style:page-layout-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:page-width=\"21cm\" fo:page-height=\"29.7cm\" style:print-orientation=\"portrait\"/></style:page-layout>"

        // Presentation styles of the master: neutral, no automatic bullets (content lists carry their own).
        let noBullets = (1...9).map { "<text:list-level-style-number text:level=\"\($0)\" style:num-format=\"\"><style:list-level-properties/></text:list-level-style-number>" }.joined()
        let neutral = "<style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\" draw:auto-grow-height=\"false\" fo:min-height=\"0cm\"><text:list-style>\(noBullets)</text:list-style></style:graphic-properties>"
        var common = "<style:default-style style:family=\"graphic\"><style:graphic-properties draw:stroke=\"none\" draw:fill=\"none\" draw:shadow=\"hidden\"/><style:paragraph-properties fo:margin-top=\"0cm\" fo:margin-bottom=\"0cm\"/><style:text-properties fo:font-size=\"18pt\" fo:font-family=\"'\(presentationXMLEscape(theme.minorFont))'\" fo:color=\"#000000\"/></style:default-style>"
        common += "<style:style style:name=\"standard\" style:family=\"graphic\">\(neutral)</style:style>"
        for name in ["title", "subtitle", "notes", "backgroundobjects", "background"] {
            common += "<style:style style:name=\"Default-\(name)\" style:family=\"presentation\">\(neutral)</style:style>"
        }
        common += "<style:style style:name=\"Default-outline1\" style:family=\"presentation\">\(neutral)</style:style>"
        for i in 2...9 { common += "<style:style style:name=\"Default-outline\(i)\" style:family=\"presentation\" style:parent-style-name=\"Default-outline\(i - 1)\"/>" }
        // Layout master pages first: their styles and named fills belong in the lists below.
        let layoutPages = layoutMasters(auto)
        common += markers()
        common += shared.xml

        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles \(Self.ns)><office:styles>\(common)</office:styles>"
            + "<office:automatic-styles>\(pageLayout)\(auto.xml)</office:automatic-styles>"
            + "<office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"PM1\" draw:style-name=\"\(masterDP)\">\(masterShapes)"
            + notesMaster + "</style:master-page>" + layoutPages + "</office:master-styles></office:document-styles>"
    }

    var notesMaster: String {
        "<presentation:notes style:page-layout-name=\"PM2\"><draw:page-thumbnail presentation:class=\"page\" svg:width=\"17cm\" svg:height=\"\(odfLength(17 * pointsPerCm * deck.size.height / deck.size.width))\" svg:x=\"2cm\" svg:y=\"2cm\"/>"
            + "<draw:frame presentation:class=\"notes\" presentation:placeholder=\"true\" svg:width=\"17cm\" svg:height=\"12cm\" svg:x=\"2cm\" svg:y=\"14.5cm\"><draw:text-box/></draw:frame></presentation:notes>"
    }

    /// One master page per layout (as LibreOffice shows PowerPoint layouts): master and layout shapes, placeholder frames.
    func layoutMasters(_ auto: ODFAutoStyles) -> String {
        var x = ""
        for (i, l) in deck.layouts.enumerated() {
            let bg = drawingPageProps(l.background ?? deck.master.background, slide: nil)
            let dp = auto.style("drawing-page", "dp", "<style:drawing-page-properties draw:background-size=\"full\"\(bg)/>")
            x += "<style:master-page style:name=\"PPT42-L\(i + 1)\" style:display-name=\"\(presentationXMLEscape(Themes.displayName(l)))\" style:page-layout-name=\"PM1\" draw:style-name=\"\(dp)\">"
            if l.showMasterShapes {
                for o in deck.master.objects { x += object(o, slide: nil, number: deck.firstSlideNumber, styles: auto).replacingOccurrences(of: "draw:layer=\"layout\"", with: "draw:layer=\"backgroundobjects\"") }
            }
            // LibreOffice shows only the background objects layer of master pages.
            for o in l.objects { x += object(o, slide: nil, number: deck.firstSlideNumber, styles: auto).replacingOccurrences(of: "draw:layer=\"layout\"", with: "draw:layer=\"backgroundobjects\"") }
            var outline = 0
            for p in l.placeholders {
                guard let ph = p.placeholder, !ph.isFooter else { continue }
                let cls = presentationClass(ph)
                guard ["title", "subtitle", "outline", "graphic"].contains(cls) else { continue }
                if cls == "outline" { outline += 1 }
                let st = auto.style("presentation", "pr", "<style:graphic-properties draw:fill=\"none\" draw:stroke=\"none\" draw:auto-grow-height=\"false\"/>",
                                    attrs: " style:parent-style-name=\"\(parentStyle(cls))\"")
                x += "<draw:frame presentation:style-name=\"\(st)\" draw:layer=\"backgroundobjects\"\(position(p.frame, rotation: p.rotation)) presentation:class=\"\(cls)\" presentation:placeholder=\"true\"\(p.name.isEmpty ? "" : " draw:name=\"\(presentationXMLEscape(p.name))\"")>\(cls == "graphic" ? "<draw:image/>" : "<draw:text-box/>")</draw:frame>"
            }
            x += notesMaster + "</style:master-page>"
        }
        return x
    }

    func markers() -> String {
        """
        <draw:marker draw:name="Arrow" svg:viewBox="0 0 20 30" svg:d="M10 0l-10 30h20z"/>\
        <draw:marker draw:name="Stealth" svg:viewBox="0 0 20 30" svg:d="M10 0l-10 30 10-9 10 9z"/>\
        <draw:marker draw:name="Line_Arrow" svg:viewBox="0 0 1122 2243" svg:d="M0 2108v17 17l12 42 30 34 38 21 43 4 29-8 30-21 25-26 13-34 343-1532 339 1520 13 42 29 34 39 21 42 4 42-12 34-30 21-42v-39-12l-4 4-440-1998-9-42-25-39-38-25-43-8-42 8-38 25-26 39-8 42z"/>\
        <draw:marker draw:name="Circle" svg:viewBox="0 0 1131 1131" svg:d="M462 1118l-102-29-102-51-93-72-72-93-51-102-29-102-13-105 13-102 29-106 51-102 72-89 93-72 102-50 102-34 106-9 101 9 106 34 98 50 93 72 72 89 51 102 29 106 13 102-13 105-29 102-51 102-72 93-93 72-98 51-106 29-101 13z"/>\
        <draw:marker draw:name="Diamond" svg:viewBox="0 0 1131 1131" svg:d="M0 564l564 567 567-567-567-564z"/>
        """
    }

    // MARK: Pages

    func page(_ slide: Slide, index: Int, styles: ODFAutoStyles) -> String {
        var props = " presentation:background-visible=\"true\" presentation:background-objects-visible=\"\(slide.showMasterShapes && (deck.layout(of: slide)?.showMasterShapes ?? true))\""
        props += " presentation:display-footer=\"true\" presentation:display-page-number=\"false\" presentation:display-date-time=\"true\""
        if slide.hidden { props += " presentation:visibility=\"hidden\"" }
        if let bg = slide.background ?? deck.layout(of: slide)?.background { props += " draw:background-size=\"full\"" + drawingPageProps(bg, slide: slide) }
        props += transitionProps(slide.transition)
        let dp = styles.style("drawing-page", "dp", "<style:drawing-page-properties\(props)/>")
        let number = Renderer.number(of: index, deck: deck)
        let pid = "page\(index + 1)"
        let masterPage = deck.layouts.indices.contains(slide.layout) ? "PPT42-L\(slide.layout + 1)" : "Default"
        var x = "<draw:page draw:name=\"\(pid)\" draw:style-name=\"\(dp)\" draw:master-page-name=\"\(masterPage)\" presentation:presentation-page-layout-name=\"\(layoutName(slide))\" ppt42:layout=\"\(presentationXMLEscape(deck.layout(of: slide)?.type ?? ""))\" xml:id=\"\(pid)\" draw:id=\"\(pid)\">"

        for o in slide.objects {
            var shape = object(o, slide: slide, number: number, styles: styles)
            if slide.animations.contains(where: { $0.target == o.id }), let space = shape.firstIndex(of: " "), let close = shape.firstIndex(of: ">"), space < close {
                // Build targets need an id.
                shape.insert(contentsOf: " xml:id=\"\(pid)s\(o.id)\" draw:id=\"\(pid)s\(o.id)\"", at: space)
            }
            x += shape
        }
        x += annotations(slide)
        x += timing(slide, pageID: pid)
        x += notes(slide, index: index, styles: styles)
        return x + "</draw:page>"
    }

    /// Comments as LibreOffice Impress annotations (replies follow their comment).
    func annotations(_ s: Slide) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var x = ""
        for c in s.comments {
            for (k, item) in ([c] + c.replies).enumerated() {
                var date = df.string(from: item.date)
                if date.hasSuffix("Z") { date.removeLast() }
                x += "<officeooo:annotation svg:x=\"\(odfLength(c.position.x))\" svg:y=\"\(odfLength(c.position.y))\" svg:width=\"0.35cm\" svg:height=\"0.35cm\""
                if k == 0 { x += " ppt42:resolved=\"\(c.resolved)\"" } else { x += " ppt42:reply=\"true\"" }
                x += "><dc:creator>\(presentationXMLEscape(item.author))</dc:creator><dc:date>\(date)</dc:date><meta:creator-initials>\(presentationXMLEscape(item.initials))</meta:creator-initials>"
                x += item.text.components(separatedBy: "\n").map { "<text:p>\(odfText($0))</text:p>" }.joined()
                x += "</officeooo:annotation>"
            }
        }
        return x
    }

    func layoutName(_ s: Slide) -> String {
        switch deck.layout(of: s)?.type ?? "" {
        case "title": return "AL1T0"
        case "obj": return "AL1T1"
        case "twoObj": return "AL1T3"
        case "titleOnly": return "AL1T19"
        case "blank": return "AL1T20"
        default: return "AL1T1"
        }
    }

    func notes(_ s: Slide, index: Int, styles: ODFAutoStyles) -> String {
        let pageH = 29.7 * pointsPerCm
        let scale = min(17 * pointsPerCm / deck.size.width, pageH * 0.42 / deck.size.height)
        let thumbW = deck.size.width * scale, thumbH = deck.size.height * scale
        var x = "<presentation:notes draw:style-name=\"\(styles.style("drawing-page", "dp", "<style:drawing-page-properties presentation:display-header=\"true\" presentation:display-footer=\"true\" presentation:display-page-number=\"false\" presentation:display-date-time=\"true\"/>"))\">"
        x += "<draw:page-thumbnail presentation:class=\"page\" draw:page-number=\"\(index + 1)\" svg:width=\"\(odfLength(thumbW))\" svg:height=\"\(odfLength(thumbH))\" svg:x=\"2cm\" svg:y=\"2cm\"/>"
        let top = 2 * pointsPerCm + thumbH + 1 * pointsPerCm
        let ps = styles.style("paragraph", "P", "<style:text-properties fo:font-size=\"12pt\" fo:font-family=\"'Helvetica Neue'\" fo:color=\"#000000\"/>")
        let paras = s.notes.isEmpty ? "" : s.notes.components(separatedBy: "\n").map { "<text:p text:style-name=\"\(ps)\">\(odfText($0))</text:p>" }.joined()
        let ns = styles.style("presentation", "pr", "<style:graphic-properties draw:fill=\"none\" draw:stroke=\"none\"/>", attrs: " style:parent-style-name=\"Default-notes\"")
        x += "<draw:frame presentation:style-name=\"\(ns)\" draw:layer=\"layout\" presentation:class=\"notes\" presentation:placeholder=\"\(s.notes.isEmpty)\" svg:width=\"17cm\" svg:height=\"\(odfLength(pageH - top - 2 * pointsPerCm))\" svg:x=\"2cm\" svg:y=\"\(odfLength(top))\"><draw:text-box>\(paras)</draw:text-box></draw:frame>"
        return x + "</presentation:notes>"
    }

    /// Transition (anim:transitionFilter, as LibreOffice writes it) and the animations.
    func timing(_ s: Slide, pageID: String) -> String {
        let seq = AnimationODF.mainSequence(s, target: { "\(pageID)s\($0)" }, hex: { color($0) })
        guard s.transition.kind != .none || !seq.isEmpty else { return "" }
        var x = "<anim:par presentation:node-type=\"timing-root\">"
        if s.transition.kind != .none {
            x += "<anim:par smil:begin=\"\(pageID).begin\"><anim:transitionFilter smil:dur=\"\(String(format: "%.2f", s.transition.duration))s\"\(smilTransition(s.transition))/></anim:par>"
        }
        return x + seq + "</anim:par>"
    }

    func smilTransition(_ t: Transition) -> String {
        func from(_ d: String) -> String { ["l": "fromRight", "r": "fromLeft", "u": "fromBottom", "d": "fromTop"][d] ?? "fromRight" }
        switch t.kind {
        case .none: return ""
        case .fade: return " smil:type=\"fade\" smil:subtype=\"crossfade\""
        case .push: return " smil:type=\"pushWipe\" smil:subtype=\"\(from(t.direction))\""
        case .cover: return " smil:type=\"slideWipe\" smil:subtype=\"\(from(t.direction))\""
        case .wipe:
            switch t.direction {
            case "l": return " smil:type=\"barWipe\" smil:subtype=\"leftToRight\" smil:direction=\"reverse\""
            case "u": return " smil:type=\"barWipe\" smil:subtype=\"topToBottom\" smil:direction=\"reverse\""
            case "d": return " smil:type=\"barWipe\" smil:subtype=\"topToBottom\""
            default: return " smil:type=\"barWipe\" smil:subtype=\"leftToRight\""
            }
        case .dissolve: return " smil:type=\"dissolve\" smil:subtype=\"defaultDissolve\""
        case .split: return " smil:type=\"barnDoorWipe\" smil:subtype=\"horizontal\""
        case .zoom: return " smil:type=\"irisWipe\" smil:subtype=\"rectangle\""
        }
    }

    func transitionProps(_ t: Transition) -> String {
        var x = ""
        if let adv = t.advanceAfter {
            x += " presentation:transition-type=\"automatic\" presentation:duration=\"PT\(String(format: "%.2f", adv))S\""
        }
        guard t.kind != .none else { return x }
        x += smilTransition(t)
        x += " presentation:transition-speed=\"\(t.duration <= 0.5 ? "fast" : t.duration <= 0.85 ? "medium" : "slow")\""
        return x
    }

    // MARK: Fills

    func color(_ c: PColor) -> String { "#" + c.flattened(theme).hex.lowercased() }

    func gradient(_ g: Gradient) -> String {
        let a = g.stops.first?.color ?? .black, b = g.stops.last?.color ?? .white
        // ODF: 0° runs top → bottom, counter-clockwise; OOXML: 0° runs left → right, clockwise.
        var angle = Int((90 - g.angle).rounded()) % 360
        if angle < 0 { angle += 360 }
        let key = "grad|\(color(a))|\(color(b))|\(angle)|\(g.radial)|\(a.alpha)|\(b.alpha)"
        return shared.named(key) { name in
            var x = "<draw:gradient draw:name=\"\(name)\" draw:display-name=\"\(name)\" draw:style=\"\(g.radial ? "radial" : "linear")\""
            if g.radial { x += " draw:cx=\"50%\" draw:cy=\"50%\"" }
            x += " draw:start-color=\"\(color(a))\" draw:end-color=\"\(color(b))\" draw:start-intensity=\"100%\" draw:end-intensity=\"100%\" draw:angle=\"\(angle)deg\" draw:border=\"0%\""
            if g.stops.count > 2 {
                x += ">" + g.stops.map { "<loext:gradient-stop svg:offset=\"\($0.position)\" loext:color-type=\"rgb\" loext:color-value=\"\(color($0.color))\"/>" }.joined() + "</draw:gradient>"
            } else {
                x += "/>"
            }
            return x
        }
    }

    func fillImage(_ media: String) -> String {
        let path = shared.picture(media)
        return shared.named("img|\(media)") { name in
            "<draw:fill-image draw:name=\"\(name)\" xlink:href=\"\(presentationXMLEscape(path))\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>"
        }
    }

    func dash(_ d: Dash, width: CGFloat) -> String {
        shared.named("dash|\(d.rawValue)") { name in
            switch d {
            case .dot: return "<draw:stroke-dash draw:name=\"\(name)\" draw:style=\"rect\" draw:dots1=\"1\" draw:dots1-length=\"100%\" draw:distance=\"200%\"/>"
            case .dashDot: return "<draw:stroke-dash draw:name=\"\(name)\" draw:style=\"rect\" draw:dots1=\"1\" draw:dots1-length=\"400%\" draw:dots2=\"1\" draw:dots2-length=\"100%\" draw:distance=\"200%\"/>"
            case .lgDash: return "<draw:stroke-dash draw:name=\"\(name)\" draw:style=\"rect\" draw:dots1=\"1\" draw:dots1-length=\"800%\" draw:distance=\"300%\"/>"
            default: return "<draw:stroke-dash draw:name=\"\(name)\" draw:style=\"rect\" draw:dots1=\"1\" draw:dots1-length=\"400%\" draw:distance=\"300%\"/>"
            }
        }
    }

    func fillProps(_ f: Fill, opacity: CGFloat = 1) -> String {
        switch f {
        case .none: return " draw:fill=\"none\""
        case .solid(let c):
            let a = c.alpha * opacity
            return " draw:fill=\"solid\" draw:fill-color=\"\(color(c))\"" + (a < 0.999 ? " draw:opacity=\"\(pct(a))\"" : "")
        case .gradient(let g):
            return " draw:fill=\"gradient\" draw:fill-gradient-name=\"\(gradient(g))\" draw:fill-color=\"\(color(g.stops.first?.color ?? .white))\"" + (opacity < 0.999 ? " draw:opacity=\"\(pct(opacity))\"" : "")
        case .picture(let m):
            return " draw:fill=\"bitmap\" draw:fill-image-name=\"\(fillImage(m))\" style:repeat=\"stretch\"" + (opacity < 0.999 ? " draw:opacity=\"\(pct(opacity))\"" : "")
        }
    }

    func drawingPageProps(_ f: Fill, slide: Slide?) -> String { fillProps(f) }

    func markerName(_ a: Arrowhead) -> String? {
        switch a {
        case .none: return nil
        case .triangle: return "Arrow"
        case .stealth: return "Stealth"
        case .arrow: return "Line_Arrow"
        case .oval: return "Circle"
        case .diamond: return "Diamond"
        }
    }

    func strokeProps(_ l: LineStyle, opacity: CGFloat = 1) -> String {
        guard let c = l.color else { return " draw:stroke=\"none\"" }
        var x = l.dash == .solid ? " draw:stroke=\"solid\"" : " draw:stroke=\"dash\" draw:stroke-dash=\"\(dash(l.dash, width: l.width))\""
        x += " svg:stroke-color=\"\(color(c))\" svg:stroke-width=\"\(odfLength(l.width))\" draw:stroke-linejoin=\"round\""
        let a = c.alpha * opacity
        if a < 0.999 { x += " svg:stroke-opacity=\"\(pct(a))\"" }
        // LibreOffice markers keep their aspect: the width follows the arrowhead's width.
        func mw(_ s: ArrowSize) -> String { odfLength(Shapes.arrowMetrics(s, width: l.width).1 * 2) }
        if let m = markerName(l.head) { x += " draw:marker-start=\"\(m)\" draw:marker-start-width=\"\(mw(l.headSize))\" draw:marker-start-center=\"\(l.head == .oval || l.head == .diamond)\"" }
        if let m = markerName(l.tail) { x += " draw:marker-end=\"\(m)\" draw:marker-end-width=\"\(mw(l.tailSize))\" draw:marker-end-center=\"\(l.tail == .oval || l.tail == .diamond)\"" }
        return x
    }

    let shadowProps = " draw:shadow=\"visible\" draw:shadow-offset-x=\"0.09cm\" draw:shadow-offset-y=\"0.09cm\" draw:shadow-color=\"#000000\" draw:shadow-opacity=\"38%\" loext:shadow-blur=\"0.18cm\""

    // MARK: Geometry

    /// svg:x/y/width/height or draw:transform for a rotated box.
    func position(_ f: CGRect, rotation: CGFloat) -> String {
        var x = " svg:width=\"\(odfLength(f.width))\" svg:height=\"\(odfLength(f.height))\""
        if rotation == 0 { return x + " svg:x=\"\(odfLength(f.minX))\" svg:y=\"\(odfLength(f.minY))\"" }
        // ODF (as LibreOffice reads it): rotate counter-clockwise about the box's top-left corner, then translate.
        let t = -rotation * .pi / 180
        let w = f.width / 2, h = f.height / 2
        let cx = w * cos(t) + h * sin(t), cy = -w * sin(t) + h * cos(t)
        let tx = f.midX - cx, ty = f.midY - cy
        x += String(format: " draw:transform=\"rotate (%.8f) translate (%@ %@)\"", t, odfLength(tx), odfLength(ty))
        return x
    }

    static let odfTypes: [String: String] = [
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
    ]

    /// draw:enhanced-path from our outline (exact geometry whatever LibreOffice's preset looks like).
    func enhancedPath(_ path: CGPath, scale: CGFloat) -> String {
        var s = ""
        func p(_ pt: CGPoint) -> String { "\(Int((pt.x * scale).rounded())) \(Int((pt.y * scale).rounded()))" }
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: s += "M \(p(el.points[0])) "
            case .addLineToPoint: s += "L \(p(el.points[0])) "
            case .addQuadCurveToPoint: s += "Q \(p(el.points[0])) \(p(el.points[1])) "
            case .addCurveToPoint: s += "C \(p(el.points[0])) \(p(el.points[1])) \(p(el.points[2])) "
            case .closeSubpath: s += "Z "
            @unknown default: break
            }
        }
        return s + "N"
    }

    // MARK: Objects

    func object(_ o: SlideObject, slide: Slide?, number: Int, styles: ODFAutoStyles) -> String {
        // Empty placeholders are hints only.
        if let ph = o.placeholder, o.kind != .table, o.kind != .picture || o.media == nil, (o.text?.isEmpty ?? true), o.media == nil {
            return emptyPlaceholder(o, ph: ph, styles: styles)
        }
        switch o.kind {
        case .group:
            var x = "<draw:g>"
            for c in o.children { x += object(c, slide: slide, number: number, styles: styles) }
            return x + "</draw:g>"
        case .line:
            return line(o, styles: styles)
        case .picture:
            return picture(o, styles: styles)
        case .table:
            return table(o, slide: slide, number: number, styles: styles)
        case .chart:
            return chartFrame(o, styles: styles)
        case .shape, .textBox:
            if o.placeholder != nil || (o.kind == .textBox && o.geometry == "rect") { return frame(o, slide: slide, number: number, styles: styles) }
            return customShape(o, slide: slide, number: number, styles: styles)
        }
    }

    func presentationClass(_ ph: Placeholder) -> String {
        switch ph.type {
        case "title", "ctrTitle": return "title"
        case "subTitle": return "subtitle"
        case "pic": return "graphic"
        case "dt": return "date-time"
        case "ftr": return "footer"
        case "sldNum": return "page-number"
        case "tbl": return "table"
        default: return "outline"
        }
    }

    func parentStyle(_ cls: String) -> String {
        switch cls {
        case "title": return "Default-title"
        case "subtitle": return "Default-subtitle"
        case "outline": return "Default-outline1"
        default: return "Default-backgroundobjects"
        }
    }

    func emptyPlaceholder(_ o: SlideObject, ph: Placeholder, styles: ODFAutoStyles) -> String {
        let cls = presentationClass(ph)
        guard ["title", "subtitle", "outline", "graphic"].contains(cls) else { return "" }
        let st = styles.style("presentation", "pr", "<style:graphic-properties draw:fill=\"none\" draw:stroke=\"none\" draw:auto-grow-height=\"false\"/>",
                              attrs: " style:parent-style-name=\"\(parentStyle(cls))\"")
        let inner = cls == "graphic" ? "<draw:image/>" : "<draw:text-box/>"
        return "<draw:frame presentation:style-name=\"\(st)\" draw:layer=\"layout\"\(position(o.frame, rotation: o.rotation)) presentation:class=\"\(cls)\" presentation:placeholder=\"true\" presentation:user-transformed=\"true\">\(inner)</draw:frame>"
    }

    func textAreaProps(_ t: TextBody?) -> String {
        guard let t else { return "" }
        let va = t.anchor == .top ? "top" : t.anchor == .middle ? "middle" : "bottom"
        var x = " draw:textarea-vertical-align=\"\(va)\" draw:textarea-horizontal-align=\"justify\""
        x += " fo:padding-top=\"\(odfLength(t.insets.top))\" fo:padding-bottom=\"\(odfLength(t.insets.bottom))\" fo:padding-left=\"\(odfLength(t.insets.left))\" fo:padding-right=\"\(odfLength(t.insets.right))\""
        x += " fo:wrap-option=\"\(t.wrap ? "wrap" : "no-wrap")\""
        switch t.autofit {
        case .resize: x += " draw:auto-grow-height=\"true\" draw:auto-grow-width=\"false\""
        case .shrink: x += " draw:auto-grow-height=\"false\" draw:auto-grow-width=\"false\" draw:fit-to-size=\"false\" style:shrink-to-fit=\"true\""
        case .none: x += " draw:auto-grow-height=\"false\" draw:auto-grow-width=\"false\" draw:fit-to-size=\"false\""
        }
        x += " fo:min-height=\"0cm\""
        return x
    }

    func graphicStyle(_ o: SlideObject, styles: ODFAutoStyles, family: String = "graphic", parent: String? = nil) -> String {
        var g = fillProps(o.fill, opacity: o.opacity) + strokeProps(o.line, opacity: o.opacity)
        g += o.shadow ? shadowProps : " draw:shadow=\"hidden\""
        g += textAreaProps(o.text)
        let attrs = parent.map { " style:parent-style-name=\"\($0)\"" } ?? ""
        return styles.style(family, family == "graphic" ? "gr" : "pr", "<style:graphic-properties\(g)/>", attrs: attrs)
    }

    func frame(_ o: SlideObject, slide: Slide?, number: Int, styles: ODFAutoStyles) -> String {
        var x = "<draw:frame"
        if let ph = o.placeholder {
            let cls = presentationClass(ph)
            let st = graphicStyle(o, styles: styles, family: "presentation", parent: parentStyle(cls))
            x += " presentation:style-name=\"\(st)\" draw:layer=\"layout\""
            x += position(o.frame, rotation: o.rotation)
            x += " presentation:class=\"\(cls)\" presentation:placeholder=\"false\" presentation:user-transformed=\"true\""
        } else {
            x += " draw:style-name=\"\(graphicStyle(o, styles: styles))\" draw:layer=\"layout\"" + position(o.frame, rotation: o.rotation)
        }
        if !o.name.isEmpty { x += " draw:name=\"\(presentationXMLEscape(o.name))\"" }
        x += ">"
        x += "<draw:text-box>" + text(o.text ?? TextBody(), object: o, slide: slide, number: number, styles: styles) + "</draw:text-box>"
        if !o.descr.isEmpty { x += "<svg:desc>\(presentationXMLEscape(o.descr))</svg:desc>" }
        return x + "</draw:frame>"
    }

    func customShape(_ o: SlideObject, slide: Slide?, number: Int, styles: ODFAutoStyles) -> String {
        var x = "<draw:custom-shape draw:style-name=\"\(graphicStyle(o, styles: styles))\" draw:layer=\"layout\"" + position(o.frame, rotation: o.rotation)
        if !o.name.isEmpty { x += " draw:name=\"\(presentationXMLEscape(o.name))\"" }
        x += ">"
        if let t = o.text, !t.isEmpty { x += text(t, object: o, slide: slide, number: number, styles: styles) }
        let scale: CGFloat = 100
        let vb = "0 0 \(Int((o.frame.width * scale).rounded())) \(Int((o.frame.height * scale).rounded()))"
        // OOXML preset name (LibreOffice writes it back to pptx as that preset) with our exact outline as the path.
        // No draw:text-areas: with ooxml-* types LibreOffice misplaces the text when they are absolute.
        let type = o.custom != nil ? "non-primitive" : "ooxml-\(o.geometry)"
        // Every sub-path, with its own no-fill / no-stroke (smiley mouths, callout lines, scroll curls).
        let path = Shapes.subpaths(o).map { sp -> String in
            var s = enhancedPath(sp.path, scale: scale)
            s.removeLast()
            if sp.fill == .none { s += "F " }
            if !sp.stroke { s += "S " }
            return s + "N"
        }.joined(separator: " ")
        x += "<draw:enhanced-geometry svg:viewBox=\"\(vb)\" draw:type=\"\(type)\" ppt42:prst=\"\(presentationXMLEscape(o.geometry))\" draw:enhanced-path=\"\(path)\""
        if o.flipH { x += " draw:mirror-horizontal=\"true\"" }
        if o.flipV { x += " draw:mirror-vertical=\"true\"" }
        if !o.adjust.isEmpty {
            let keys = o.adjust.keys.sorted()
            x += " draw:modifiers=\"\(keys.map { "\(o.adjust[$0]!)" }.joined(separator: " "))\""
            x += " ppt42:adjust=\"\(keys.map { "\($0)=\(o.adjust[$0]!)" }.joined(separator: ";"))\""
        }
        x += "/>"
        if !o.descr.isEmpty { x += "<svg:desc>\(presentationXMLEscape(o.descr))</svg:desc>" }
        return x + "</draw:custom-shape>"
    }

    func line(_ o: SlideObject, styles: ODFAutoStyles) -> String {
        var a = o.lineStart, b = o.lineEnd
        if o.rotation != 0 {
            let c = CGPoint(x: o.frame.midX, y: o.frame.midY), r = o.rotation * .pi / 180
            func rot(_ p: CGPoint) -> CGPoint {
                CGPoint(x: c.x + (p.x - c.x) * cos(r) - (p.y - c.y) * sin(r), y: c.y + (p.x - c.x) * sin(r) + (p.y - c.y) * cos(r))
            }
            a = rot(a); b = rot(b)
        }
        var g = strokeProps(o.line, opacity: o.opacity)
        g += o.shadow ? shadowProps : " draw:shadow=\"hidden\""
        let st = styles.style("graphic", "gr", "<style:graphic-properties draw:fill=\"none\"\(g)/>")
        return "<draw:line draw:style-name=\"\(st)\" draw:layer=\"layout\" svg:x1=\"\(odfLength(a.x))\" svg:y1=\"\(odfLength(a.y))\" svg:x2=\"\(odfLength(b.x))\" svg:y2=\"\(odfLength(b.y))\"><text:p/></draw:line>"
    }

    /// A chart as an embedded chart sub-document with a replacement picture.
    func chartFrame(_ o: SlideObject, styles: ODFAutoStyles) -> String {
        guard let m = o.chart else { return "" }
        shared.objectCount += 1
        let dir = "Object \(shared.objectCount)"
        if let files = m.untouchedODF {
            for (name, data) in files { shared.files["\(dir)/\(name)"] = data }
            for name in files.keys.sorted() where name.hasSuffix(".xml") { shared.manifest.append(("\(dir)/\(name)", "text/xml")) }
        } else {
            let content = ChartODF.content(m, size: o.frame.size, font: theme.minorFont) { color($0) }
            shared.files["\(dir)/content.xml"] = Data(content.utf8)
            shared.files["\(dir)/styles.xml"] = Data(ChartODF.styles().utf8)
            shared.manifest += [("\(dir)/content.xml", "text/xml"), ("\(dir)/styles.xml", "text/xml")]
        }
        shared.manifest.append(("\(dir)/", "application/vnd.oasis.opendocument.chart"))
        var replacement = ""
        if let png = chartPNG(o) {
            shared.files["ObjectReplacements/\(dir)"] = png
            shared.manifest.append(("ObjectReplacements/\(dir)", "image/png"))
            replacement = "<draw:image xlink:href=\"./ObjectReplacements/\(dir)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>"
        }
        var g = fillProps(o.fill) + strokeProps(o.line)
        g += " draw:shadow=\"hidden\""
        var x = "<draw:frame draw:style-name=\"\(styles.style("graphic", "gr", "<style:graphic-properties\(g)/>"))\" draw:layer=\"layout\"" + position(o.frame, rotation: o.rotation)
        if !o.name.isEmpty { x += " draw:name=\"\(presentationXMLEscape(o.name))\"" }
        x += "><draw:object draw:notify-on-update-of-ranges=\"\" xlink:href=\"./\(dir)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>\(replacement)"
        if !o.descr.isEmpty { x += "<svg:desc>\(presentationXMLEscape(o.descr))</svg:desc>" }
        return x + "</draw:frame>"
    }

    func chartPNG(_ o: SlideObject) -> Data? {
        guard let m = o.chart else { return nil }
        let scale: CGFloat = 2
        let w = max(1, Int(o.frame.width * scale)), h = max(1, Int(o.frame.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ChartRenderer.draw(m, deck: deck, in: CGRect(origin: .zero, size: o.frame.size), ctx: ctx)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func picture(_ o: SlideObject, styles: ODFAutoStyles) -> String {
        guard let media = o.media else { return "" }
        let path = shared.picture(media)
        var g = " draw:fill=\"none\"" + strokeProps(o.line) + (o.shadow ? shadowProps : " draw:shadow=\"hidden\"")
        if o.opacity < 1 { g += " draw:image-opacity=\"\(pct(o.opacity))\"" }
        let c = o.crop
        if c.left != 0 || c.top != 0 || c.right != 0 || c.bottom != 0, let img = MediaCache.image(media, deck.media[media]) {
            let s = img.size
            g += " fo:clip=\"rect(\(odfLength(s.height * c.top)), \(odfLength(s.width * c.right)), \(odfLength(s.height * c.bottom)), \(odfLength(s.width * c.left)))\""
        }
        var x = "<draw:frame"
        if let ph = o.placeholder {
            let st = styles.style("presentation", "pr", "<style:graphic-properties\(g)/>", attrs: " style:parent-style-name=\"Default-backgroundobjects\"")
            x += " presentation:style-name=\"\(st)\" draw:layer=\"layout\"" + position(o.frame, rotation: o.rotation)
            x += " presentation:class=\"\(presentationClass(ph))\" presentation:placeholder=\"false\" presentation:user-transformed=\"true\""
        } else {
            x += " draw:style-name=\"\(styles.style("graphic", "gr", "<style:graphic-properties\(g)/>"))\" draw:layer=\"layout\"" + position(o.frame, rotation: o.rotation)
        }
        if !o.name.isEmpty { x += " draw:name=\"\(presentationXMLEscape(o.name))\"" }
        let ext = (media as NSString).pathExtension.lowercased()
        let mime = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : ext == "svg" ? "image/svg+xml" : "image/\(ext)"
        if let clip = o.clip, let data = deck.media[clip.media] {
            let path = "Media/\(clip.media)"
            shared.files[path] = data
            shared.manifest.append((path, MediaClip.mime(clip.ext)))
            x += "><draw:plugin xlink:href=\"\(presentationXMLEscape(path))\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"application/vnd.sun.star.media\">"
            x += "<draw:param draw:name=\"Loop\" draw:value=\"\(clip.loop)\"/><draw:param draw:name=\"Mute\" draw:value=\"false\"/><draw:param draw:name=\"VolumeDB\" draw:value=\"0\"/><draw:param draw:name=\"Zoom\" draw:value=\"fit\"/>"
            x += "<draw:param draw:name=\"ppt42-autoplay\" draw:value=\"\(clip.autoplay)\"/></draw:plugin"
        }
        x += "><draw:image xlink:href=\"\(presentationXMLEscape(path))\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"\(mime)\"><text:p/></draw:image>"
        if !o.descr.isEmpty { x += "<svg:desc>\(presentationXMLEscape(o.descr))</svg:desc>" }
        return x + "</draw:frame>"
    }

    func table(_ o: SlideObject, slide: Slide?, number: Int, styles: ODFAutoStyles) -> String {
        guard let t = o.table else { return "" }
        let frameStyle = styles.style("graphic", "gr", "<style:graphic-properties draw:fill=\"none\" draw:stroke=\"none\"/>")
        var x = "<draw:frame draw:style-name=\"\(frameStyle)\" draw:layer=\"layout\"" + position(o.frame, rotation: o.rotation)
        if !o.name.isEmpty { x += " draw:name=\"\(presentationXMLEscape(o.name))\"" }
        x += "><table:table>"
        for w in t.columns {
            let cs = styles.style("table-column", "co", "<style:table-column-properties style:column-width=\"\(odfLength(w))\" style:use-optimal-column-width=\"false\"/>")
            x += "<table:table-column table:style-name=\"\(cs)\"/>"
        }
        let border: String = {
            guard let c = t.borderColor, t.borderWidth > 0 else { return "none" }
            // Border controls use points; centimetre rounding needlessly changed exact widths on reopen.
            return "\(Double(t.borderWidth))pt solid \(color(c))"
        }()
        for (ri, row) in t.cells.enumerated() {
            let rs = styles.style("table-row", "ro", "<style:table-row-properties style:row-height=\"\(odfLength(t.rows[ri]))\" style:use-optimal-row-height=\"false\"/>")
            x += "<table:table-row table:style-name=\"\(rs)\">"
            for (ci, cell) in row.enumerated() {
                if cell.merged { x += "<table:covered-table-cell/>"; continue }
                let ins = cell.text.insets
                let va = cell.text.anchor == .top ? "top" : cell.text.anchor == .middle ? "middle" : "bottom"
                var g = fillProps(cell.fill ?? t.defaultFill(row: ri))
                g += " draw:textarea-vertical-align=\"\(va)\""
                g += " fo:padding-top=\"\(odfLength(ins.top))\" fo:padding-bottom=\"\(odfLength(ins.bottom))\" fo:padding-left=\"\(odfLength(ins.left))\" fo:padding-right=\"\(odfLength(ins.right))\""
                // LibreOffice keeps table cell graphics in loext:graphic-properties.
                let st = styles.style("table-cell", "ce", "<loext:graphic-properties\(g)/><style:paragraph-properties fo:border=\"\(border)\"/>")
                var attrs = " table:style-name=\"\(st)\""
                if cell.gridSpan > 1 { attrs += " table:number-columns-spanned=\"\(cell.gridSpan)\"" }
                if cell.rowSpan > 1 { attrs += " table:number-rows-spanned=\"\(cell.rowSpan)\"" }
                let ctx = TextContext(deck: deck, slide: slide, object: o, number: number, scale: 1, cellDefaults: Renderer.cellDefaults(t, row: ri))
                x += "<table:table-cell\(attrs)>" + paragraphs(cell.text.paragraphs, ctx: ctx, styles: styles) + "</table:table-cell>"
                _ = ci
            }
            x += "</table:table-row>"
        }
        return x + "</table:table></draw:frame>"
    }

    // MARK: Text

    func text(_ body: TextBody, object o: SlideObject, slide: Slide?, number: Int, styles: ODFAutoStyles) -> String {
        let ctx = TextContext(deck: deck, slide: slide, object: o, number: number)
        return paragraphs(body.paragraphs, ctx: ctx, styles: styles)
    }

    func textProps(_ r: RunProps, link: Bool = false) -> String {
        var x = ""
        let family = theme.font(r.font) ?? theme.minorFont
        x += " fo:font-family=\"'\(presentationXMLEscape(family))'\" style:font-family-asian=\"'\(presentationXMLEscape(family))'\" style:font-family-complex=\"'\(presentationXMLEscape(family))'\""
        let size = r.size ?? 18
        x += " fo:font-size=\"\(String(format: "%.1f", size))pt\" style:font-size-asian=\"\(String(format: "%.1f", size))pt\" style:font-size-complex=\"\(String(format: "%.1f", size))pt\""
        let bold = r.bold ?? false, italic = r.italic ?? false
        x += " fo:font-weight=\"\(bold ? "bold" : "normal")\" style:font-weight-asian=\"\(bold ? "bold" : "normal")\" style:font-weight-complex=\"\(bold ? "bold" : "normal")\""
        x += " fo:font-style=\"\(italic ? "italic" : "normal")\" style:font-style-asian=\"\(italic ? "italic" : "normal")\" style:font-style-complex=\"\(italic ? "italic" : "normal")\""
        if r.underline == true || link {
            x += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\""
        } else {
            x += " style:text-underline-style=\"none\""
        }
        x += " style:text-line-through-style=\"\((r.strike ?? false) ? "solid" : "none")\""
        let c = link ? PColor(scheme: "hlink") : (r.color ?? PColor(scheme: "tx1"))
        x += " fo:color=\"\(color(c))\""
        if let b = r.baseline, b != 0 { x += " style:text-position=\"\(b > 0 ? "super" : "sub") 58%\"" }
        return x
    }

    func paragraphProps(_ s: LevelStyle, bulleted: Bool) -> String {
        var x = ""
        switch s.align ?? .left {
        case .left: x += " fo:text-align=\"start\""
        case .center: x += " fo:text-align=\"center\""
        case .right: x += " fo:text-align=\"end\""
        case .justify: x += " fo:text-align=\"justify\""
        }
        let marL = s.marL ?? 0, indent = s.indent ?? 0
        // Bulleted paragraphs keep their indents in the list level (text:space-before / min-label-width), as LibreOffice does.
        x += " fo:margin-left=\"\(odfLength(bulleted ? 0 : max(0, marL)))\" fo:margin-right=\"0cm\" fo:text-indent=\"\(odfLength(bulleted ? 0 : (marL + indent < 0 ? -marL : indent)))\""
        func spc(_ v: CGFloat?) -> CGFloat { guard let v else { return 0 }; return v < 0 ? -v * (s.run.size ?? 18) * 1.2 : v }
        x += " fo:margin-top=\"\(odfLength(spc(s.spaceBefore)))\" fo:margin-bottom=\"\(odfLength(spc(s.spaceAfter)))\""
        if let ls = s.lineSpacing {
            x += ls < 0 ? " fo:line-height=\"\(odfLength(-ls))\"" : " fo:line-height=\"\(pct(ls))\""
        } else {
            x += " fo:line-height=\"100%\""
        }
        return x
    }

    /// Paragraphs, with consecutive bulleted ones grouped into (nested) text:list elements.
    func paragraphs(_ paras: [Paragraph], ctx: TextContext, styles: ODFAutoStyles) -> String {
        let resolved: [LevelStyle] = paras.map { $0.props.over(TextRender.levelStyle(ctx, level: $0.level)) }
        func bulleted(_ i: Int) -> Bool { (resolved[i].bullet?.kind ?? .none) != .none && !paras[i].text.isEmpty }
        var out = ""
        var i = 0
        while i < paras.count {
            if !bulleted(i) {
                out += paragraph(paras[i], style: resolved[i], ctx: ctx, styles: styles, bulleted: false)
                i += 1
                continue
            }
            // One list per run of paragraphs whose bullet at each level stays the same.
            var j = i
            var levels: [Int: (Bullet, LevelStyle, RunProps)] = [:]
            while j < paras.count, bulleted(j) {
                let lvl = paras[j].level
                if let known = levels[lvl] {
                    if known.0 != resolved[j].bullet! { break }
                } else {
                    let first = (paras[j].runs.first?.props ?? paras[j].endProps).over(resolved[j].run)
                    levels[lvl] = (resolved[j].bullet!, resolved[j], first)
                }
                j += 1
            }
            let listName = styles.listStyle(listStyleBody(levels))
            var idx = i
            out += list(paras, resolved, &idx, end: j, level: 0, name: listName, ctx: ctx, styles: styles)
            i = j
        }
        return out
    }

    func list(_ paras: [Paragraph], _ resolved: [LevelStyle], _ idx: inout Int, end: Int, level: Int, name: String?,
              ctx: TextContext, styles: ODFAutoStyles) -> String {
        var s = name.map { "<text:list text:style-name=\"\($0)\">" } ?? "<text:list>"
        while idx < end, paras[idx].level >= level {
            if paras[idx].level == level {
                s += "<text:list-item>" + paragraph(paras[idx], style: resolved[idx], ctx: ctx, styles: styles, bulleted: true)
                idx += 1
                if idx < end, paras[idx].level > level {
                    s += list(paras, resolved, &idx, end: end, level: level + 1, name: nil, ctx: ctx, styles: styles)
                }
                s += "</text:list-item>"
            } else {
                s += "<text:list-item>" + list(paras, resolved, &idx, end: end, level: level + 1, name: nil, ctx: ctx, styles: styles) + "</text:list-item>"
            }
        }
        return s + "</text:list>"
    }

    func listStyleBody(_ levels: [Int: (Bullet, LevelStyle, RunProps)]) -> String {
        var x = ""
        for lvl in 0..<9 {
            guard let (b, s, run) = levels[lvl] else {
                x += "<text:list-level-style-number text:level=\"\(lvl + 1)\" style:num-format=\"\"><style:list-level-properties/></text:list-level-style-number>"
                continue
            }
            let marL = s.marL ?? 0, indent = s.indent ?? 0
            let label = max(0, -indent), before = max(0, marL + min(0, indent))
            let props = "<style:list-level-properties text:space-before=\"\(odfLength(before))\" text:min-label-width=\"\(odfLength(label))\"\(b.kind == .number ? " text:min-label-distance=\"0.15cm\"" : "")/>"
            var tp = " fo:font-size=\"\(pct(b.sizePercent ?? 1))\""
            tp += " fo:color=\"\(color(b.color ?? run.color ?? PColor(scheme: "tx1")))\""
            if b.kind == .char {
                var ch = b.char.isEmpty ? "•" : b.char
                if let f = b.font, f.contains("Wingdings") || f.contains("Symbol") { ch = "•" }
                let fam = (b.font.flatMap { $0.contains("Wingdings") || $0.contains("Symbol") || $0.hasPrefix("+") ? nil : $0 }) ?? (theme.font(run.font) ?? theme.minorFont)
                tp += " fo:font-family=\"'\(presentationXMLEscape(fam))'\""
                x += "<text:list-level-style-bullet text:level=\"\(lvl + 1)\" text:bullet-char=\"\(presentationXMLEscape(String(ch.prefix(1))))\">\(props)<style:text-properties\(tp)/></text:list-level-style-bullet>"
            } else {
                let sch = b.scheme
                let format = sch.hasPrefix("alphaLc") ? "a" : sch.hasPrefix("alphaUc") ? "A" : sch.hasPrefix("romanLc") ? "i" : sch.hasPrefix("romanUc") ? "I" : "1"
                let suffix = sch.hasSuffix("ParenR") || sch.hasSuffix("ParenBoth") ? ")" : sch.hasSuffix("Plain") ? "" : "."
                let prefix = sch.hasSuffix("ParenBoth") ? " style:num-prefix=\"(\"" : ""
                tp += " fo:font-family=\"'\(presentationXMLEscape(theme.font(run.font) ?? theme.minorFont))'\""
                x += "<text:list-level-style-number text:level=\"\(lvl + 1)\" style:num-format=\"\(format)\"\(prefix) style:num-suffix=\"\(suffix)\" text:start-value=\"\(b.startAt)\">\(props)<style:text-properties\(tp)/></text:list-level-style-number>"
            }
        }
        return x
    }

    func paragraph(_ p: Paragraph, style: LevelStyle, ctx: TextContext, styles: ODFAutoStyles, bulleted: Bool) -> String {
        let end = p.endProps.over(style.run)
        let ps = styles.style("paragraph", "P", "<style:paragraph-properties\(paragraphProps(style, bulleted: bulleted))/><style:text-properties\(textProps(end))/>")
        var x = "<text:p text:style-name=\"\(ps)\">"
        for r in p.runs {
            let props = r.props.over(style.run)
            let ts = styles.style("text", "T", "<style:text-properties\(textProps(props, link: r.link != nil))/>")
            var inner: String
            switch r.field {
            case "slidenum": inner = "<text:page-number text:select-page=\"current\">\(ctx.number)</text:page-number>"
            case let f? where f.hasPrefix("datetime"): inner = "<text:date>\(odfText(TextRender.fieldText(f, fallback: r.text, number: ctx.number)))</text:date>"
            default: inner = odfText(r.text)
            }
            if let link = r.link { inner = "<text:a xlink:type=\"simple\" xlink:href=\"\(presentationXMLEscape(link))\">\(inner)</text:a>" }
            x += "<text:span text:style-name=\"\(ts)\">\(inner)</text:span>"
        }
        return x + "</text:p>"
    }
}
