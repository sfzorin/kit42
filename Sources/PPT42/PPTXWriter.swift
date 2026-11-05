import AppKit
import Kit42

/// Writes a Deck as PresentationML (.pptx): master, layouts, theme, slides, notes, media.
struct PPTXWriter {
    let deck: Deck
    private var zip = ZipArchive()
    /// Extra parts written while writing slides (charts, workbooks, diagrams, media), with their content types.
    let sink = PartSink()

    final class PartSink {
        var files: [String: Data] = [:]
        var overrides: [String: String] = [:]
        var defaults: [String: String] = [:]
        var counters: [String: Int] = [:]

        /// A free path "folder/stemN.ext" (or the preferred name when free).
        func path(folder: String, stem: String, ext: String, preferred: String? = nil) -> String {
            if let p = preferred, files["\(folder)/\(p)"] == nil { return "\(folder)/\(p)" }
            var n = counters[folder + stem, default: 0]
            var p: String
            repeat { n += 1; p = "\(folder)/\(stem)\(n).\(ext)" } while files[p] != nil
            counters[folder + stem] = n
            return p
        }

        func add(_ path: String, _ data: Data, type: String?) {
            files[path] = data
            let ext = (path as NSString).pathExtension.lowercased()
            guard let type, type != "application/octet-stream" || ext != "xml" else { return }
            if ext == "xml" { overrides["/" + path] = type } else if defaults[ext] == nil { defaults[ext] = type }
        }

        /// Writes a kept part and the parts it refers to; returns its path.
        func write(_ p: PackagePart, at path: String) -> String {
            var rels: [(String, String, String, Bool)] = []
            for r in p.rels {
                if let ext = r.external { rels.append((r.id, r.type, ext, true)); continue }
                guard let child = r.part else { continue }
                let folder = (child.name as NSString).deletingLastPathComponent
                let name = (child.name as NSString).lastPathComponent
                let ext = (name as NSString).pathExtension
                let childPath = self.path(folder: folder, stem: (name as NSString).deletingPathExtension, ext: ext, preferred: files["\(folder)/\(name)"] == nil ? name : nil)
                _ = write(child, at: childPath)
                rels.append((r.id, r.type, relative(from: path, to: childPath), false))
            }
            add(path, p.data, type: p.contentType)
            if !rels.isEmpty {
                var x = PPTXWriter.head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                for r in rels { x += "<Relationship Id=\"\(r.0)\" Type=\"\(r.1)\" Target=\"\(xmlEscape(r.2))\"\(r.3 ? " TargetMode=\"External\"" : "")/>" }
                files[relsPath(path)] = Data((x + "</Relationships>").utf8)
            }
            return path
        }

        func relative(from a: String, to b: String) -> String {
            let fa = a.split(separator: "/").dropLast().map(String.init), fb = b.split(separator: "/").map(String.init)
            var i = 0
            while i < fa.count, i < fb.count - 1, fa[i] == fb[i] { i += 1 }
            return (Array(repeating: "..", count: fa.count - i) + fb[i...]).joined(separator: "/")
        }
    }

    static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static var ns: String { "xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\"" }
    static let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static func data(_ deck: Deck) -> Data {
        var w = PPTXWriter(deck: deck)
        return w.write()
    }

    init(deck: Deck) { self.deck = deck }

    /// Relationships of one part being written.
    final class Rels {
        var items: [(id: String, type: String, target: String, external: Bool)] = []
        private var media: [String: String] = [:]

        func add(_ type: String, _ target: String, external: Bool = false) -> String {
            if let e = items.first(where: { $0.type == type && $0.target == target }) { return e.id }
            let id = "rId\(items.count + 1)"
            items.append((id, type, target, external))
            return id
        }

        func media(_ name: String) -> String {
            if let id = media[name] { return id }
            let id = add("\(PPTXWriter.relBase)/image", "../media/\(name)")
            media[name] = id
            return id
        }

        var xml: String {
            var s = PPTXWriter.head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            for r in items {
                s += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(xmlEscape(r.target))\"\(r.external ? " TargetMode=\"External\"" : "")/>"
            }
            return s + "</Relationships>"
        }
    }

    mutating func put(_ name: String, _ s: String) { zip[name] = Data(s.utf8) }

    mutating func write() -> Data {
        let n = deck.slides.count
        let hasNotes = deck.slides.contains { !$0.notes.isEmpty }
        writeMaster()
        for i in deck.layouts.indices { writeLayout(i) }
        for i in 0..<n { writeSlide(i) }
        if hasNotes { writeNotesMaster() }
        for (name, data) in deck.media { zip["ppt/media/\(name)"] = data }
        for (path, data) in sink.files { zip[path] = data }
        var types = Self.head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        types += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        types += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for (ext, mime) in [("png", "image/png"), ("jpeg", "image/jpeg"), ("jpg", "image/jpeg"), ("gif", "image/gif"), ("bmp", "image/bmp"),
                            ("tiff", "image/tiff"), ("svg", "image/svg+xml")] {
            types += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
        }
        for (ext, mime) in sink.defaults.sorted(by: { $0.key < $1.key }) where !["png", "jpeg", "jpg", "gif", "bmp", "tiff", "svg", "xml", "rels"].contains(ext) {
            types += "<Default Extension=\"\(ext)\" ContentType=\"\(mime)\"/>"
        }
        for (part, mime) in sink.overrides.sorted(by: { $0.key < $1.key }) { types += "<Override PartName=\"\(xmlEscape(part))\" ContentType=\"\(mime)\"/>" }
        let pml = "application/vnd.openxmlformats-officedocument.presentationml"
        types += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(pml).presentation.main+xml\"/>"
        types += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"\(pml).slideMaster+xml\"/>"
        for i in deck.layouts.indices { types += "<Override PartName=\"/ppt/slideLayouts/slideLayout\(i + 1).xml\" ContentType=\"\(pml).slideLayout+xml\"/>" }
        for i in 0..<n { types += "<Override PartName=\"/ppt/slides/slide\(i + 1).xml\" ContentType=\"\(pml).slide+xml\"/>" }
        if hasNotes {
            types += "<Override PartName=\"/ppt/notesMasters/notesMaster1.xml\" ContentType=\"\(pml).notesMaster+xml\"/>"
            types += "<Override PartName=\"/ppt/theme/theme2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
            for (i, s) in deck.slides.enumerated() where !s.notes.isEmpty {
                types += "<Override PartName=\"/ppt/notesSlides/notesSlide\(i + 1).xml\" ContentType=\"\(pml).notesSlide+xml\"/>"
            }
        }
        types += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        types += "<Override PartName=\"/ppt/presProps.xml\" ContentType=\"\(pml).presProps+xml\"/>"
        types += "<Override PartName=\"/ppt/viewProps.xml\" ContentType=\"\(pml).viewProps+xml\"/>"
        types += "<Override PartName=\"/ppt/tableStyles.xml\" ContentType=\"\(pml).tableStyles+xml\"/>"
        types += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        types += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        if !commentAuthors.isEmpty { types += "<Override PartName=\"/ppt/commentAuthors.xml\" ContentType=\"\(pml).commentAuthors+xml\"/>" }
        types += "</Types>"
        put("[Content_Types].xml", types)

        put("_rels/.rels", Self.head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(Self.relBase)/officeDocument\" Target=\"ppt/presentation.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
            + "<Relationship Id=\"rId3\" Type=\"\(Self.relBase)/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>")
        let now = ISO8601DateFormatter().string(from: Date())
        put("docProps/core.xml", Self.head + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
            + "<dc:title>\(xmlEscape(deck.slides.first?.title ?? ""))</dc:title><dc:creator>PPT42</dc:creator>"
            + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified></cp:coreProperties>")
        put("docProps/app.xml", Self.head + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>PPT42</Application><Slides>\(n)</Slides><PresentationFormat>On-screen Show</PresentationFormat></Properties>")

        // presentation.xml
        let pres = Rels()
        let masterRel = pres.add("\(Self.relBase)/slideMaster", "slideMasters/slideMaster1.xml")
        var slideIDs = ""
        for i in 0..<n {
            let id = pres.add("\(Self.relBase)/slide", "slides/slide\(i + 1).xml")
            slideIDs += "<p:sldId id=\"\(256 + i)\" r:id=\"\(id)\"/>"
        }
        var notesList = ""
        if hasNotes { notesList = "<p:notesMasterIdLst><p:notesMasterId r:id=\"\(pres.add("\(Self.relBase)/notesMaster", "notesMasters/notesMaster1.xml"))\"/></p:notesMasterIdLst>" }
        _ = pres.add("\(Self.relBase)/presProps", "presProps.xml")
        _ = pres.add("\(Self.relBase)/viewProps", "viewProps.xml")
        _ = pres.add("\(Self.relBase)/theme", "theme/theme1.xml")
        _ = pres.add("\(Self.relBase)/tableStyles", "tableStyles.xml")
        if !commentAuthors.isEmpty {
            _ = pres.add("\(Self.relBase)/commentAuthors", "commentAuthors.xml")
            var x = Self.head + "<p:cmAuthorLst \(Self.ns)>"
            for (i, a) in commentAuthors.enumerated() {
                let last = deck.slides.flatMap { $0.comments.flatMap { [$0] + $0.replies } }.filter { $0.author == a.0 }.count
                x += "<p:cmAuthor id=\"\(i)\" name=\"\(xmlEscape(a.0))\" initials=\"\(xmlEscape(a.1))\" lastIdx=\"\(last)\" clrIdx=\"\(i % 8)\"/>"
            }
            put("ppt/commentAuthors.xml", x + "</p:cmAuthorLst>")
        }
        let cx = emu(deck.size.width), cy = emu(deck.size.height)
        let sizeType = abs(deck.size.width / deck.size.height - 16.0 / 9) < 0.01 ? (cx == 12192000 ? "" : " type=\"screen16x9\"") : abs(deck.size.width / deck.size.height - 4.0 / 3) < 0.01 ? " type=\"screen4x3\"" : " type=\"custom\""
        var p = Self.head + "<p:presentation \(Self.ns) saveSubsetFonts=\"1\"\(deck.firstSlideNumber != 1 ? " firstSlideNum=\"\(deck.firstSlideNumber)\"" : "")>"
        p += "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"\(masterRel)\"/></p:sldMasterIdLst>" + notesList
        p += n > 0 ? "<p:sldIdLst>\(slideIDs)</p:sldIdLst>" : ""
        p += "<p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"\(sizeType)/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
        p += "<p:defaultTextStyle>" + levels(deck.master.otherStyle, rels: pres, prefix: "a", full: true) + "</p:defaultTextStyle>"
        p += "</p:presentation>"
        put("ppt/presentation.xml", p)
        put("ppt/_rels/presentation.xml.rels", pres.xml)
        put("ppt/presProps.xml", Self.head + "<p:presentationPr \(Self.ns)/>")
        put("ppt/viewProps.xml", Self.head + "<p:viewPr \(Self.ns)><p:normalViewPr><p:restoredLeft sz=\"15620\"/><p:restoredTop sz=\"94660\"/></p:normalViewPr><p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>")
        put("ppt/tableStyles.xml", Self.head + "<a:tblStyleLst xmlns:a=\"\(Self.nsA)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>")
        put("ppt/theme/theme1.xml", themeXML(deck.theme))
        return zip.data()
    }

    // MARK: - Parts

    mutating func writeMaster() {
        let rels = Rels()
        var ids = ""
        for i in deck.layouts.indices {
            let r = rels.add("\(Self.relBase)/slideLayout", "../slideLayouts/slideLayout\(i + 1).xml")
            ids += "<p:sldLayoutId id=\"\(2147483649 + i)\" r:id=\"\(r)\"/>"
        }
        _ = rels.add("\(Self.relBase)/theme", "../theme/theme1.xml")
        var x = Self.head + "<p:sldMaster \(Self.ns)><p:cSld>"
        x += background(deck.master.background, rels: rels)
        x += tree(deck.master.placeholders + deck.master.objects, rels: rels, slide: nil, master: true)
        x += "</p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        x += "<p:sldLayoutIdLst>\(ids)</p:sldLayoutIdLst><p:txStyles>"
        x += "<p:titleStyle>" + levels(deck.master.titleStyle, rels: rels, prefix: "a", full: true) + "</p:titleStyle>"
        x += "<p:bodyStyle>" + levels(deck.master.bodyStyle, rels: rels, prefix: "a", full: true) + "</p:bodyStyle>"
        x += "<p:otherStyle>" + levels(deck.master.otherStyle, rels: rels, prefix: "a", full: true) + "</p:otherStyle>"
        x += "</p:txStyles></p:sldMaster>"
        put("ppt/slideMasters/slideMaster1.xml", x)
        put("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels.xml)
    }

    mutating func writeLayout(_ i: Int) {
        let l = deck.layouts[i]
        let rels = Rels()
        _ = rels.add("\(Self.relBase)/slideMaster", "../slideMasters/slideMaster1.xml")
        var x = Self.head + "<p:sldLayout \(Self.ns) type=\"\(xmlEscape(l.type))\" preserve=\"1\"\(l.showMasterShapes ? "" : " showMasterSp=\"0\"")>"
        x += "<p:cSld name=\"\(xmlEscape(l.name))\">"
        if let bg = l.background { x += background(bg, rels: rels) }
        x += tree(l.placeholders + l.objects, rels: rels, slide: nil, master: true)
        x += "</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        put("ppt/slideLayouts/slideLayout\(i + 1).xml", x)
        put("ppt/slideLayouts/_rels/slideLayout\(i + 1).xml.rels", rels.xml)
    }

    mutating func writeSlide(_ i: Int) {
        let s = deck.slides[i]
        let rels = Rels()
        _ = rels.add("\(Self.relBase)/slideLayout", "../slideLayouts/slideLayout\(min(max(s.layout, 0), max(0, deck.layouts.count - 1)) + 1).xml")
        var x = Self.head + "<p:sld \(Self.ns)\(s.hidden ? " show=\"0\"" : "")\(s.showMasterShapes ? "" : " showMasterSp=\"0\"")><p:cSld>"
        if let bg = s.background { x += background(bg, rels: rels) }
        x += tree(s.objects, rels: rels, slide: s, master: false)
        x += "</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
        x += transition(s.transition)
        x += timing(s)
        x += "</p:sld>"
        if !s.notes.isEmpty {
            _ = rels.add("\(Self.relBase)/notesSlide", "../notesSlides/notesSlide\(i + 1).xml")
            writeNotes(i)
        }
        if !s.comments.isEmpty {
            _ = rels.add("\(Self.relBase)/comments", "../comments/comment\(i + 1).xml")
            put("ppt/comments/comment\(i + 1).xml", commentsXML(s.comments))
            sink.overrides["/ppt/comments/comment\(i + 1).xml"] = "application/vnd.openxmlformats-officedocument.presentationml.comments+xml"
        }
        put("ppt/slides/slide\(i + 1).xml", x)
        put("ppt/slides/_rels/slide\(i + 1).xml.rels", rels.xml)
    }

    /// Authors of all comments in order of appearance: (name, initials).
    var commentAuthors: [(String, String)] {
        var out: [(String, String)] = []
        for s in deck.slides { for c in s.comments.flatMap({ [$0] + $0.replies }) where !out.contains(where: { $0.0 == c.author }) { out.append((c.author, c.initials)) } }
        return out
    }

    /// Legacy comments (p:cmLst) with PowerPoint 2013 threading for replies and our resolved flag.
    func commentsXML(_ list: [Comment]) -> String {
        let authors = commentAuthors
        var counters: [String: Int] = [:]
        // Indexes continue through the deck per author.
        for s in deck.slides {
            if s.comments == list { break }
            for c in s.comments.flatMap({ [$0] + $0.replies }) { counters[c.author, default: 0] += 1 }
        }
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var x = Self.head + "<p:cmLst \(Self.ns)>"
        func one(_ c: Comment, parent: (Int, Int)?) -> (Int, Int) {
            let aid = authors.firstIndex { $0.0 == c.author } ?? 0
            counters[c.author, default: 0] += 1
            let idx = counters[c.author]!
            var date = df.string(from: c.date)
            if date.hasSuffix("Z") { date.removeLast() }
            x += "<p:cm authorId=\"\(aid)\" dt=\"\(date)\" idx=\"\(idx)\"><p:pos x=\"\(Int(c.position.x * 8))\" y=\"\(Int(c.position.y * 8))\"/><p:text>\(xmlEscape(c.text))</p:text>"
            var ext = ""
            if let parent {
                ext += "<p:ext uri=\"{C676402C-5697-4E1C-873F-D02D1690AC5C}\"><p15:threadingInfo xmlns:p15=\"http://schemas.microsoft.com/office/powerpoint/2012/main\" timeZoneBias=\"0\"><p15:parentCm authorId=\"\(parent.0)\" idx=\"\(parent.1)\"/></p15:threadingInfo></p:ext>"
            }
            if c.resolved || c.objectID != nil {
                ext += "<p:ext uri=\"{5E1A3C42-0B7D-4F3E-9A42-0C11A5E0FF42}\"><ppt42:comment xmlns:ppt42=\"urn:sfzorin:ppt42\" resolved=\"\(c.resolved ? 1 : 0)\"\(c.objectID.map { " object=\"\($0)\"" } ?? "")/></p:ext>"
            }
            if !ext.isEmpty { x += "<p:extLst>\(ext)</p:extLst>" }
            x += "</p:cm>"
            return (aid, idx)
        }
        for c in list {
            let p = one(c, parent: nil)
            for r in c.replies { _ = one(r, parent: p) }
        }
        return x + "</p:cmLst>"
    }

    mutating func writeNotes(_ i: Int) {
        let rels = Rels()
        _ = rels.add("\(Self.relBase)/notesMaster", "../notesMasters/notesMaster1.xml")
        _ = rels.add("\(Self.relBase)/slide", "../slides/slide\(i + 1).xml")
        let paras = deck.slides[i].notes.components(separatedBy: "\n").map {
            $0.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p>" : "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(xmlEscape($0))</a:t></a:r></a:p>"
        }.joined()
        var x = Self.head + "<p:notes \(Self.ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
        x += "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"sldImg\"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>"
        x += "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:spPr/>"
        x += "<p:txBody><a:bodyPr/><a:lstStyle/>\(paras)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
        put("ppt/notesSlides/notesSlide\(i + 1).xml", x)
        put("ppt/notesSlides/_rels/notesSlide\(i + 1).xml.rels", rels.xml)
    }

    mutating func writeNotesMaster() {
        let rels = Rels()
        _ = rels.add("\(Self.relBase)/theme", "../theme/theme2.xml")
        let imgW = 5486400, imgH = Int(5486400 * deck.size.height / deck.size.width)
        var x = Self.head + "<p:notesMaster \(Self.ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
        x += "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Slide Image Placeholder 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\" noRot=\"1\" noChangeAspect=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"sldImg\" idx=\"2\"/></p:nvPr></p:nvSpPr>"
        x += "<p:spPr><a:xfrm><a:off x=\"685800\" y=\"914400\"/><a:ext cx=\"\(imgW)\" cy=\"\(imgH)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln w=\"12700\"><a:solidFill><a:prstClr val=\"black\"/></a:solidFill></a:ln></p:spPr></p:sp>"
        x += "<p:sp><p:nvSpPr><p:cNvPr id=\"3\" name=\"Notes Placeholder 2\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"body\" sz=\"quarter\" idx=\"3\"/></p:nvPr></p:nvSpPr>"
        x += "<p:spPr><a:xfrm><a:off x=\"685800\" y=\"4800600\"/><a:ext cx=\"5486400\" cy=\"3600450\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert=\"horz\" lIns=\"91440\" tIns=\"45720\" rIns=\"91440\" bIns=\"45720\" rtlCol=\"0\"/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>"
        x += "</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        x += "<p:notesStyle><a:lvl1pPr marL=\"0\" algn=\"l\" defTabSz=\"914400\" rtl=\"0\" eaLnBrk=\"1\" latinLnBrk=\"0\" hangingPunct=\"1\"><a:defRPr sz=\"1200\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl1pPr></p:notesStyle></p:notesMaster>"
        put("ppt/notesMasters/notesMaster1.xml", x)
        put("ppt/notesMasters/_rels/notesMaster1.xml.rels", rels.xml)
        put("ppt/theme/theme2.xml", themeXML(deck.theme))
    }

    // MARK: - Theme

    func themeXML(_ t: Theme) -> String {
        var x = Self.head + "<a:theme xmlns:a=\"\(Self.nsA)\" name=\"\(xmlEscape(t.name))\"><a:themeElements><a:clrScheme name=\"\(xmlEscape(t.name))\">"
        for slot in Theme.slots {
            let v = t.colors[slot] ?? t.color(slot)
            x += "<a:\(slot)><a:srgbClr val=\"\(String(format: "%06X", v))\"/></a:\(slot)>"
        }
        x += "</a:clrScheme><a:fontScheme name=\"\(xmlEscape(t.name))\">"
        x += "<a:majorFont><a:latin typeface=\"\(xmlEscape(t.majorFont))\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
        x += "<a:minorFont><a:latin typeface=\"\(xmlEscape(t.minorFont))\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
        x += """
        <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:lumMod val="110000"/><a:satMod val="105000"/><a:tint val="67000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:lumMod val="105000"/><a:satMod val="109000"/><a:tint val="81000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:satMod val="103000"/><a:lumMod val="102000"/><a:tint val="94000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:lumMod val="99000"/><a:satMod val="120000"/><a:shade val="78000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst><a:outerShdw blurRad="57150" dist="19050" dir="5400000" algn="ctr" rotWithShape="0"><a:srgbClr val="000000"><a:alpha val="63000"/></a:srgbClr></a:outerShdw></a:effectLst></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/><a:satMod val="170000"/></a:schemeClr></a:solidFill><a:gradFill rotWithShape="1"><a:gsLst><a:gs pos="0"><a:schemeClr val="phClr"><a:tint val="93000"/><a:satMod val="150000"/><a:shade val="98000"/><a:lumMod val="102000"/></a:schemeClr></a:gs><a:gs pos="100000"><a:schemeClr val="phClr"><a:shade val="63000"/><a:satMod val="120000"/></a:schemeClr></a:gs></a:gsLst><a:lin ang="5400000" scaled="0"/></a:gradFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """
        return x
    }

    // MARK: - Shapes

    func emu(_ v: CGFloat) -> Int { Int((v * emuPerPoint).rounded()) }

    func tree(_ objects: [SlideObject], rels: Rels, slide: Slide?, master: Bool) -> String {
        var x = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        x += "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        for o in objects { x += object(o, rels: rels, slide: slide) }
        return x + "</p:spTree>"
    }

    func xfrm(_ o: SlideObject, prefix: String = "a") -> String {
        var attrs = ""
        if o.rotation != 0 { attrs += " rot=\"\(Int((o.rotation * 60000).rounded()))\"" }
        if o.flipH { attrs += " flipH=\"1\"" }
        if o.flipV { attrs += " flipV=\"1\"" }
        return "<\(prefix):xfrm\(attrs)><a:off x=\"\(emu(o.frame.minX))\" y=\"\(emu(o.frame.minY))\"/><a:ext cx=\"\(emu(o.frame.width))\" cy=\"\(emu(o.frame.height))\"/></\(prefix):xfrm>"
    }

    func geometry(_ o: SlideObject) -> String {
        if let c = o.custom { return custGeom(c) }
        var prst = o.geometry
        if prst == "arrow" { prst = "straightConnector1" }
        if o.adjust.isEmpty { return "<a:prstGeom prst=\"\(prst)\"><a:avLst/></a:prstGeom>" }
        let gd = o.adjust.sorted { $0.key < $1.key }.map { "<a:gd name=\"\($0.key)\" fmla=\"val \($0.value)\"/>" }.joined()
        return "<a:prstGeom prst=\"\(prst)\"><a:avLst>\(gd)</a:avLst></a:prstGeom>"
    }

    func custGeom(_ c: CustomGeometry) -> String {
        func gds(_ l: [GeoGuide]) -> String { l.map { "<a:gd name=\"\(xmlEscape($0.name))\" fmla=\"\(xmlEscape($0.fmla))\"/>" }.joined() }
        var x = "<a:custGeom><a:avLst>\(gds(c.adjust))</a:avLst><a:gdLst>\(gds(c.guides))</a:gdLst><a:ahLst/><a:cxnLst/>"
        let r = c.rect ?? ["l", "t", "r", "b"]
        x += "<a:rect l=\"\(r[0])\" t=\"\(r[1])\" r=\"\(r[2])\" b=\"\(r[3])\"/><a:pathLst>"
        func pt(_ a: String, _ b: String) -> String { "<a:pt x=\"\(a)\" y=\"\(b)\"/>" }
        for p in c.paths {
            var attrs = ""
            if let w = p.w { attrs += " w=\"\(Int(w))\"" }
            if let h = p.h { attrs += " h=\"\(Int(h))\"" }
            if p.fill != .norm { attrs += " fill=\"\(p.fill.rawValue)\"" }
            if !p.stroke { attrs += " stroke=\"0\"" }
            x += "<a:path\(attrs)>"
            for cmd in p.commands {
                switch cmd {
                case .move(let a, let b): x += "<a:moveTo>\(pt(a, b))</a:moveTo>"
                case .line(let a, let b): x += "<a:lnTo>\(pt(a, b))</a:lnTo>"
                case .arc(let wR, let hR, let st, let sw): x += "<a:arcTo wR=\"\(wR)\" hR=\"\(hR)\" stAng=\"\(st)\" swAng=\"\(sw)\"/>"
                case .quad(let a, let b, let c, let d): x += "<a:quadBezTo>\(pt(a, b))\(pt(c, d))</a:quadBezTo>"
                case .cubic(let a, let b, let c, let d, let e, let f): x += "<a:cubicBezTo>\(pt(a, b))\(pt(c, d))\(pt(e, f))</a:cubicBezTo>"
                case .close: x += "<a:close/>"
                }
            }
            x += "</a:path>"
        }
        return x + "</a:pathLst></a:custGeom>"
    }

    func nv(_ o: SlideObject, kind: String, extra: String = "", ph: Bool = true) -> String {
        var x = "<p:nv\(kind)Pr><p:cNvPr id=\"\(o.id)\" name=\"\(xmlEscape(o.name.isEmpty ? defaultName(o) : o.name))\"\(o.descr.isEmpty ? "" : " descr=\"\(xmlEscape(o.descr))\"")/>"
        x += extra
        if ph, let p = o.placeholder {
            x += "<p:nvPr><p:ph" + (p.type == "obj" ? "" : " type=\"\(p.type)\"") + (p.idx.map { " idx=\"\($0)\"" } ?? "") + "/></p:nvPr>"
        } else {
            x += "<p:nvPr/>"
        }
        return x + "</p:nv\(kind)Pr>"
    }

    func defaultName(_ o: SlideObject) -> String {
        switch o.kind {
        case .textBox: return "TextBox \(o.id)"
        case .picture: return "Picture \(o.id)"
        case .table: return "Table \(o.id)"
        case .chart: return "Chart \(o.id)"
        case .group: return "Group \(o.id)"
        case .line: return "Connector \(o.id)"
        case .shape: return "Shape \(o.id)"
        }
    }

    /// SmartArt written back with its parts (texts patched in), or nil when its shapes changed otherwise.
    func diagramFrame(_ o: SlideObject, rels: Rels) -> String? {
        guard let d = o.diagram else { return nil }
        let ch = Diagram.change(o)
        guard ch != .other else { return nil }
        var drawingData = d.drawing?.data, dataData = d.data?.data
        if ch == .text {
            let p = Diagram.patched(o, writer: self, rels: rels)
            drawingData = p.drawing ?? drawingData
            dataData = p.data ?? dataData
        }
        func put(_ part: PackagePart?, data: Data?, stem: String) -> String? {
            guard let part else { return nil }
            let p = PackagePart(name: part.name, data: data ?? part.data, contentType: part.contentType, rels: part.rels)
            return sink.write(p, at: sink.path(folder: "ppt/diagrams", stem: stem, ext: "xml"))
        }
        func rel(_ type: String, _ path: String?) -> String? { path.map { rels.add(type, sink.relative(from: "ppt/slides/slide1.xml", to: $0)) } }
        let drawRel = rel(Diagram.relDrawing, put(d.drawing, data: drawingData, stem: "drawing"))
        if let drawRel, var s = dataData.map({ String(decoding: $0, as: UTF8.self) }),
           let r = s.range(of: "relId=\"[^\"]*\"", options: .regularExpression, range: s.range(of: "dataModelExt").map { $0.lowerBound..<s.endIndex }) {
            s.replaceSubrange(r, with: "relId=\"\(drawRel)\"")
            dataData = Data(s.utf8)
        }
        let dm = rel("\(Self.relBase)/diagramData", put(d.data, data: dataData, stem: "data"))
        let lo = rel("\(Self.relBase)/diagramLayout", put(d.layout, data: nil, stem: "layout"))
        let qs = rel("\(Self.relBase)/diagramQuickStyle", put(d.style, data: nil, stem: "quickStyle"))
        let cs = rel("\(Self.relBase)/diagramColors", put(d.colors, data: nil, stem: "colors"))
        var x = "<p:graphicFrame>" + nv(o, kind: "GraphicFrame", extra: "<p:cNvGraphicFramePr/>", ph: false) + xfrm(o, prefix: "p")
        x += "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/diagram\"><dgm:relIds xmlns:dgm=\"\(Diagram.nsDgm)\""
        for (k, v) in [("dm", dm), ("lo", lo), ("qs", qs), ("cs", cs)] { if let v { x += " r:\(k)=\"\(v)\"" } }
        return x + "/></a:graphicData></a:graphic></p:graphicFrame>"
    }

    func object(_ o: SlideObject, rels: Rels, slide: Slide?) -> String {
        switch o.kind {
        case .group:
            if let x = diagramFrame(o, rels: rels) { return x }
            var x = "<p:grpSp>" + nv(o, kind: "GrpSp", extra: "<p:cNvGrpSpPr/>", ph: false)
            let rot = o.rotation != 0 ? " rot=\"\(Int(o.rotation * 60000))\"" : ""
            let f = o.frame
            x += "<p:grpSpPr><a:xfrm\(rot)><a:off x=\"\(emu(f.minX))\" y=\"\(emu(f.minY))\"/><a:ext cx=\"\(emu(f.width))\" cy=\"\(emu(f.height))\"/>"
            x += "<a:chOff x=\"\(emu(f.minX))\" y=\"\(emu(f.minY))\"/><a:chExt cx=\"\(emu(f.width))\" cy=\"\(emu(f.height))\"/></a:xfrm></p:grpSpPr>"
            for c in o.children { x += object(c, rels: rels, slide: slide) }
            return x + "</p:grpSp>"
        case .picture:
            guard let media = o.media else {
                // Empty picture placeholder.
                return "<p:sp>" + nv(o, kind: "Sp", extra: "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>") + "<p:spPr>\(xfrm(o))</p:spPr></p:sp>"
            }
            var x = "<p:pic>"
            if let clip = o.clip {
                let target = "../media/\(clip.media)"
                let embed = rels.add("http://schemas.microsoft.com/office/2007/relationships/media", target)
                let link = rels.add("\(Self.relBase)/\(clip.audio ? "audio" : "video")", target)
                sink.defaults[clip.ext] = MediaClip.mime(clip.ext)
                x += "<p:nvPicPr><p:cNvPr id=\"\(o.id)\" name=\"\(xmlEscape(o.name.isEmpty ? defaultName(o) : o.name))\"><a:hlinkClick r:id=\"\" action=\"ppaction://media\"/></p:cNvPr>"
                x += "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr><a:\(clip.audio ? "audioFile" : "videoFile") r:link=\"\(link)\"/>"
                x += "<p:extLst><p:ext uri=\"{DAA4B4D4-6D71-4841-9C94-3DE04A35F2DA}\"><p14:media xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\" r:embed=\"\(embed)\"/></p:ext>"
                x += "<p:ext uri=\"{6C1E4F2B-7A3D-4B8E-9F42-0C11A5E0FF42}\"><ppt42:clip xmlns:ppt42=\"urn:sfzorin:ppt42\" autoplay=\"\(clip.autoplay ? 1 : 0)\" loop=\"\(clip.loop ? 1 : 0)\"/></p:ext></p:extLst></p:nvPr></p:nvPicPr>"
            } else {
                x += nv(o, kind: "Pic", extra: "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr>")
            }
            x += "<p:blipFill><a:blip r:embed=\"\(rels.media(media))\">"
            if o.opacity < 1 { x += "<a:alphaModFix amt=\"\(Int(o.opacity * 100000))\"/>" }
            x += "</a:blip>"
            let c = o.crop
            if c.left != 0 || c.top != 0 || c.right != 0 || c.bottom != 0 {
                x += "<a:srcRect l=\"\(Int(c.left * 100000))\" t=\"\(Int(c.top * 100000))\" r=\"\(Int(c.right * 100000))\" b=\"\(Int(c.bottom * 100000))\"/>"
            }
            x += "<a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(xfrm(o))\(geometry(o))\(line(o.line, rels: rels))\(o.shadow ? shadow : "")</p:spPr></p:pic>"
            return x
        case .table:
            guard let t = o.table else { return "" }
            var x = "<p:graphicFrame>" + nv(o, kind: "GraphicFrame", extra: "<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr>", ph: false)
            x += xfrm(o, prefix: "p") + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\">"
            x += table(t, rels: rels, slide: slide, object: o)
            return x + "</a:graphicData></a:graphic></p:graphicFrame>"
        case .chart:
            guard let m = o.chart else { return "" }
            let path: String
            if let part = m.untouchedPart {
                path = sink.write(part, at: sink.path(folder: "ppt/charts", stem: "chart", ext: "xml"))
            } else {
                path = sink.path(folder: "ppt/charts", stem: "chart", ext: "xml")
                let wb = sink.path(folder: "ppt/embeddings", stem: "Microsoft_Excel_Worksheet", ext: "xlsx")
                sink.add(wb, ChartXML.workbook(m), type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                let relXML = Self.head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(Self.relBase)/package\" Target=\"\(sink.relative(from: path, to: wb))\"/></Relationships>"
                sink.files[relsPath(path)] = Data(relXML.utf8)
                sink.add(path, Data(ChartXML.write(m, color: { color($0) }, workbookRel: "rId1").utf8), type: "application/vnd.openxmlformats-officedocument.drawingml.chart+xml")
            }
            let rid = rels.add("\(Self.relBase)/chart", sink.relative(from: "ppt/slides/slide1.xml", to: path))
            var x = "<p:graphicFrame>" + nv(o, kind: "GraphicFrame", extra: "<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr>", ph: false)
            x += xfrm(o, prefix: "p") + "<a:graphic><a:graphicData uri=\"\(ChartXML.nsC)\"><c:chart xmlns:c=\"\(ChartXML.nsC)\" r:id=\"\(rid)\"/></a:graphicData></a:graphic>"
            return x + "</p:graphicFrame>"
        case .line:
            var x = "<p:cxnSp>" + nv(o, kind: "CxnSp", extra: "<p:cNvCxnSpPr/>", ph: false)
            x += "<p:spPr>\(xfrm(o))\(geometry(o))<a:noFill/>\(line(o.line, rels: rels))\(o.shadow ? shadow : "")</p:spPr></p:cxnSp>"
            return x
        case .shape, .textBox:
            let extra = o.kind == .textBox && o.placeholder == nil ? "<p:cNvSpPr txBox=\"1\"/>" : o.placeholder != nil ? "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>" : "<p:cNvSpPr/>"
            var x = "<p:sp>" + nv(o, kind: "Sp", extra: extra)
            x += "<p:spPr>\(xfrm(o))\(geometry(o))"
            if !(o.placeholder != nil && o.fill.isNone) { x += fill(o.fill, rels: rels, alpha: o.opacity) }
            if !(o.placeholder != nil && o.line.color == nil) { x += line(o.line, rels: rels, alpha: o.opacity) }
            if o.shadow { x += shadow }
            x += "</p:spPr>"
            if let t = o.text { x += textBody(t, rels: rels, tag: "p:txBody") }
            return x + "</p:sp>"
        }
    }

    let shadow = "<a:effectLst><a:outerShdw blurRad=\"63500\" dist=\"38100\" dir=\"2700000\" algn=\"tl\" rotWithShape=\"0\"><a:prstClr val=\"black\"><a:alpha val=\"40000\"/></a:prstClr></a:outerShdw></a:effectLst>"

    func color(_ c: PColor, alpha: CGFloat = 1) -> String {
        var c = c
        if alpha < 1 { c = c.withAlpha(c.alpha * alpha) }
        let mods = c.mods.map { "<a:\($0.name) val=\"\($0.val)\"/>" }.joined()
        if let s = c.scheme { return mods.isEmpty ? "<a:schemeClr val=\"\(s)\"/>" : "<a:schemeClr val=\"\(s)\">\(mods)</a:schemeClr>" }
        return mods.isEmpty ? "<a:srgbClr val=\"\(c.hex)\"/>" : "<a:srgbClr val=\"\(c.hex)\">\(mods)</a:srgbClr>"
    }

    func fill(_ f: Fill, rels: Rels, alpha: CGFloat = 1) -> String {
        switch f {
        case .none: return "<a:noFill/>"
        case .solid(let c): return "<a:solidFill>\(color(c, alpha: alpha))</a:solidFill>"
        case .gradient(let g):
            let stops = g.stops.map { "<a:gs pos=\"\(Int($0.position * 100000))\">\(color($0.color, alpha: alpha))</a:gs>" }.joined()
            let shape = g.radial ? "<a:path path=\"circle\"><a:fillToRect l=\"50000\" t=\"50000\" r=\"50000\" b=\"50000\"/></a:path>" : "<a:lin ang=\"\(Int(g.angle * 60000))\" scaled=\"0\"/>"
            return "<a:gradFill rotWithShape=\"1\"><a:gsLst>\(stops)</a:gsLst>\(shape)</a:gradFill>"
        case .picture(let m):
            return "<a:blipFill dpi=\"0\" rotWithShape=\"1\"><a:blip r:embed=\"\(rels.media(m))\"/><a:srcRect/><a:stretch><a:fillRect/></a:stretch></a:blipFill>"
        }
    }

    func line(_ l: LineStyle, rels: Rels, alpha: CGFloat = 1) -> String {
        guard let c = l.color else { return "<a:ln><a:noFill/></a:ln>" }
        var x = "<a:ln w=\"\(emu(l.width))\"><a:solidFill>\(color(c, alpha: alpha))</a:solidFill>"
        if l.dash != .solid { x += "<a:prstDash val=\"\(l.dash == .dot ? "sysDot" : l.dash.rawValue)\"/>" }
        func sz(_ s: ArrowSize) -> String { s == ArrowSize() ? "" : " w=\"\(ArrowSize.names[s.w])\" len=\"\(ArrowSize.names[s.len])\"" }
        if l.head != .none { x += "<a:headEnd type=\"\(l.head.rawValue)\"\(sz(l.headSize))/>" }
        if l.tail != .none { x += "<a:tailEnd type=\"\(l.tail.rawValue)\"\(sz(l.tailSize))/>" }
        return x + "</a:ln>"
    }

    func background(_ f: Fill, rels: Rels) -> String {
        "<p:bg><p:bgPr>\(fill(f, rels: rels))<a:effectLst/></p:bgPr></p:bg>"
    }

    // MARK: - Text

    func runProps(_ r: RunProps, tag: String = "a:rPr", rels: Rels, link: String? = nil, lang: Bool = true) -> String {
        var attrs = lang ? " lang=\"en-US\"" : ""
        if let s = r.size { attrs += " sz=\"\(Int((s * 100).rounded()))\"" }
        if let b = r.bold { attrs += " b=\"\(b ? 1 : 0)\"" }
        if let i = r.italic { attrs += " i=\"\(i ? 1 : 0)\"" }
        if let u = r.underline { attrs += " u=\"\(u ? "sng" : "none")\"" }
        if let s = r.strike { attrs += " strike=\"\(s ? "sngStrike" : "noStrike")\"" }
        if let b = r.baseline, b != 0 { attrs += " baseline=\"\(Int(b * 1000))\"" }
        if tag == "a:rPr" || tag == "a:endParaRPr" { attrs += " dirty=\"0\"" }
        var kids = ""
        if let c = r.color { kids += "<a:solidFill>\(color(c))</a:solidFill>" }
        if let f = r.font { kids += "<a:latin typeface=\"\(xmlEscape(f))\"/>" + (f.hasPrefix("+mj") ? "<a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/>" : f.hasPrefix("+mn") ? "<a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/>" : "<a:cs typeface=\"\(xmlEscape(f))\"/>") }
        if let link { kids += "<a:hlinkClick r:id=\"\(rels.add("\(Self.relBase)/hyperlink", link, external: true))\"/>" }
        return kids.isEmpty ? "<\(tag)\(attrs)/>" : "<\(tag)\(attrs)>\(kids)</\(tag)>"
    }

    /// pPr or lvlNpPr content.
    func levelProps(_ s: LevelStyle, tag: String, rels: Rels, level: Int? = nil, withRun: Bool) -> String {
        var attrs = ""
        if let m = s.marL { attrs += " marL=\"\(emu(m))\"" }
        if let l = level, l > 0 { attrs += " lvl=\"\(l)\"" }
        if let i = s.indent { attrs += " indent=\"\(emu(i))\"" }
        if let a = s.align { attrs += " algn=\"\(a.rawValue)\"" }
        var kids = ""
        if let ls = s.lineSpacing {
            kids += ls < 0 ? "<a:lnSpc><a:spcPts val=\"\(Int(-ls * 100))\"/></a:lnSpc>" : "<a:lnSpc><a:spcPct val=\"\(Int((ls * 100000).rounded()))\"/></a:lnSpc>"
        }
        func spc(_ v: CGFloat) -> String { v < 0 ? "<a:spcPct val=\"\(Int((-v * 100000).rounded()))\"/>" : "<a:spcPts val=\"\(Int(v * 100))\"/>" }
        if let b = s.spaceBefore { kids += "<a:spcBef>\(spc(b))</a:spcBef>" }
        if let a = s.spaceAfter { kids += "<a:spcAft>\(spc(a))</a:spcAft>" }
        if let b = s.bullet {
            switch b.kind {
            case .none: kids += "<a:buNone/>"
            case .char:
                if let c = b.color { kids += "<a:buClr>\(color(c))</a:buClr>" }
                if let p = b.sizePercent { kids += "<a:buSzPct val=\"\(Int(p * 100000))\"/>" }
                kids += "<a:buFont typeface=\"\(xmlEscape(b.font ?? "Arial"))\"/><a:buChar char=\"\(xmlEscape(b.char))\"/>"
            case .number:
                if let c = b.color { kids += "<a:buClr>\(color(c))</a:buClr>" }
                if let p = b.sizePercent { kids += "<a:buSzPct val=\"\(Int(p * 100000))\"/>" }
                if let f = b.font { kids += "<a:buFont typeface=\"\(xmlEscape(f))\"/>" }
                kids += "<a:buAutoNum type=\"\(b.scheme)\"\(b.startAt != 1 ? " startAt=\"\(b.startAt)\"" : "")/>"
            }
        }
        if withRun, !s.run.isEmpty { kids += runProps(s.run, tag: "a:defRPr", rels: rels, lang: false) }
        if attrs.isEmpty && kids.isEmpty { return "" }
        return kids.isEmpty ? "<\(tag)\(attrs)/>" : "<\(tag)\(attrs)>\(kids)</\(tag)>"
    }

    func levels(_ l: ListStyle, rels: Rels, prefix: String, full: Bool) -> String {
        var x = ""
        for i in 0..<9 where !l[i].isEmpty || full {
            x += levelProps(l[i], tag: "\(prefix):lvl\(i + 1)pPr", rels: rels, withRun: true)
        }
        return x
    }

    func textBody(_ t: TextBody, rels: Rels, tag: String, defaults: RunProps? = nil) -> String {
        var bp = " wrap=\"\(t.wrap ? "square" : "none")\" lIns=\"\(emu(t.insets.left))\" tIns=\"\(emu(t.insets.top))\" rIns=\"\(emu(t.insets.right))\" bIns=\"\(emu(t.insets.bottom))\" anchor=\"\(t.anchor.rawValue)\" rtlCol=\"0\""
        if t.vertical { bp += " vert=\"vert\"" }
        let fit: String
        switch t.autofit {
        case .none: fit = "<a:noAutofit/>"
        case .shrink: fit = "<a:normAutofit/>"
        case .resize: fit = "<a:spAutoFit/>"
        }
        var x = "<\(tag)><a:bodyPr\(bp)>\(fit)</a:bodyPr>"
        let lst = levels(t.listStyle, rels: rels, prefix: "a", full: false)
        x += lst.isEmpty ? "<a:lstStyle/>" : "<a:lstStyle>\(lst)</a:lstStyle>"
        for p in t.paragraphs { x += paragraph(p, rels: rels, defaults: defaults) }
        return x + "</\(tag)>"
    }

    func paragraph(_ p: Paragraph, rels: Rels, defaults: RunProps?) -> String {
        var x = "<a:p>"
        var props = p.props
        props.run = RunProps()
        x += levelProps(props, tag: "a:pPr", rels: rels, level: p.level, withRun: false)
        if x == "<a:p>", p.level > 0 { x += "<a:pPr lvl=\"\(p.level)\"/>" }
        for r in p.runs {
            let rp = defaults.map { r.props.over($0) } ?? r.props
            if let f = r.field {
                x += "<a:fld id=\"{\(UUID().uuidString)}\" type=\"\(f == "slidenum" ? "slidenum" : "datetime1")\">\(runProps(rp, rels: rels))<a:t>\(xmlEscape(r.text.isEmpty ? "‹#›" : r.text))</a:t></a:fld>"
                continue
            }
            let pieces = r.text.components(separatedBy: "\u{0B}")
            for (k, piece) in pieces.enumerated() {
                if k > 0 { x += "<a:br>\(runProps(rp, rels: rels))</a:br>" }
                if !piece.isEmpty { x += "<a:r>\(runProps(rp, rels: rels, link: r.link))<a:t>\(xmlEscape(piece))</a:t></a:r>" }
            }
        }
        let end = defaults.map { p.endProps.over($0) } ?? p.endProps
        x += runProps(end, tag: "a:endParaRPr", rels: rels)
        return x + "</a:p>"
    }

    func table(_ t: TableModel, rels: Rels, slide: Slide?, object o: SlideObject) -> String {
        var x = "<a:tbl><a:tblPr firstRow=\"\(t.firstRow ? 1 : 0)\" bandRow=\"\(t.bandRows ? 1 : 0)\"/><a:tblGrid>"
        for w in t.columns { x += "<a:gridCol w=\"\(emu(w))\"/>" }
        x += "</a:tblGrid>"
        let border: String = {
            guard let c = t.borderColor, t.borderWidth > 0 else { return "<a:noFill/>" }
            return "<a:solidFill>\(color(c))</a:solidFill>"
        }()
        let bw = t.borderColor == nil ? 0 : emu(t.borderWidth)
        for (ri, row) in t.cells.enumerated() {
            x += "<a:tr h=\"\(emu(t.rows[ri]))\">"
            for cell in row {
                var attrs = ""
                if cell.gridSpan > 1 { attrs += " gridSpan=\"\(cell.gridSpan)\"" }
                if cell.rowSpan > 1 { attrs += " rowSpan=\"\(cell.rowSpan)\"" }
                if cell.merged { attrs += " hMerge=\"1\"" }
                x += "<a:tc\(attrs)>"
                // Header look is written out so other apps show it without our table style.
                x += textBody(cell.text, rels: rels, tag: "a:txBody", defaults: Renderer.cellDefaults(t, row: ri))
                let ins = cell.text.insets
                x += "<a:tcPr marL=\"\(emu(ins.left))\" marR=\"\(emu(ins.right))\" marT=\"\(emu(ins.top))\" marB=\"\(emu(ins.bottom))\" anchor=\"\(cell.text.anchor.rawValue)\">"
                for side in ["lnL", "lnR", "lnT", "lnB"] { x += "<a:\(side) w=\"\(bw)\">\(border)</a:\(side)>" }
                x += fill(cell.fill ?? t.defaultFill(row: ri), rels: rels)
                x += "</a:tcPr></a:tc>"
            }
            x += "</a:tr>"
        }
        return x + "</a:tbl>"
    }

    // MARK: - Transitions and builds

    func transition(_ t: Transition) -> String {
        guard t.kind != .none || t.advanceAfter != nil else { return "" }
        let spd = t.duration <= 0.5 ? "fast" : t.duration <= 0.85 ? "med" : "slow"
        var x = "<p:transition spd=\"\(spd)\"\(t.advanceAfter.map { " advTm=\"\(Int($0 * 1000))\"" } ?? "")>"
        switch t.kind {
        case .none: break
        case .fade: x += "<p:fade/>"
        case .push: x += "<p:push dir=\"\(t.direction)\"/>"
        case .wipe: x += "<p:wipe dir=\"\(t.direction)\"/>"
        case .cover: x += "<p:cover dir=\"\(t.direction)\"/>"
        case .dissolve: x += "<p:dissolve/>"
        case .split: x += "<p:split orient=\"horz\" dir=\"out\"/>"
        case .zoom: x += "<p:zoom/>"
        }
        return x + "</p:transition>"
    }

    func timing(_ s: Slide) -> String { TimingXML.write(s) { color($0) } }
}
