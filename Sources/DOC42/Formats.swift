import AppKit
import Kit42

/// The system RTF and ODT converters drop pictures, page setup, header and footer. Readers patch the file
/// before the system reader sees it (pictures become text markers, see `DocxStyles.restoreImages`);
/// writers swap pictures for markers and put the real objects into the converter's output.
enum ImageMarkers {
    struct Picture {
        let png: Data
        let size: NSSize   // points
    }

    static func marker(_ n: Int) -> String { "\(DocxStyles.markerStart)\(n)\(DocxStyles.markerEnd)" }

    /// A copy of the text with every picture replaced by its marker (numbered from 1 in reading order).
    static func extract(_ text: NSAttributedString) -> (NSAttributedString, [Picture]) {
        var found: [(NSRange, Picture)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            guard let attachment = v as? NSTextAttachment else { return }
            var image = attachment.image
            if image == nil, let data = attachment.fileWrapper?.regularFileContents { image = NSImage(data: data) }
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            var size = attachment.bounds.size
            if size.width <= 0 || size.height <= 0 { size = image.size }
            found.append((r, Picture(png: png, size: size)))
        }
        let out = NSMutableAttributedString(attributedString: text)
        // List markers are already text ("\t•\t"): system lists on top would number twice.
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            guard let p = v as? NSParagraphStyle, !p.textLists.isEmpty, let m = p.mutableCopy() as? NSMutableParagraphStyle else { return }
            m.textLists = []
            out.addAttribute(.paragraphStyle, value: m, range: r)
        }
        for (n, (range, _)) in found.enumerated().reversed() {
            var attrs = text.attributes(at: range.location, effectiveRange: nil)
            attrs[.attachment] = nil
            out.replaceCharacters(in: range, with: NSAttributedString(string: marker(n + 1), attributes: attrs))
        }
        return (out, found.map(\.1))
    }

    static let pattern = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")
}

// MARK: - Lengths

/// "2cm", "0.5in", "12pt", "20mm" → points.
func odfLength(_ s: String?) -> CGFloat? {
    guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    let units: [(String, CGFloat)] = [("cm", 28.3465), ("mm", 2.83465), ("in", 72), ("pt", 1), ("pc", 12), ("px", 0.75)]
    var factor: CGFloat = 1
    for (u, f) in units where s.hasSuffix(u) {
        factor = f
        s.removeLast(u.count)
        break
    }
    return Double(s).map { CGFloat($0) * factor }
}

private func odf(_ points: CGFloat) -> String { String(format: "%.3fcm", points / 28.3465) }

// MARK: - OpenDocument Text

enum OdtFormat {
    /// Patches content.xml/styles.xml for the system reader and collects what it would drop.
    static func prepare(_ data: Data) -> (data: Data, extras: DocxStyles.Extras) {
        var extras = DocxStyles.Extras()
        guard var zip = try? ZipArchive(data: data),
              let contentData = zip["content.xml"],
              let content = try? XMLDocument(data: contentData, options: [.nodePreserveWhitespace]),
              let root = content.rootElement() else { return (data, extras) }
        let stylesDoc = zip["styles.xml"].flatMap { try? XMLDocument(data: $0, options: [.nodePreserveWhitespace]) }

        // Paragraph style → parent (automatic styles point at named ones, e.g. P1 → Title).
        var parents: [String: String] = [:]
        for doc in [content, stylesDoc].compactMap({ $0 }) {
            for s in descendants(doc.rootElement(), named: "style") where s.attr("family") == "paragraph" {
                if let name = s.attr("name"), let parent = s.attr("parent-style-name") { parents[name] = parent }
            }
        }
        func isTitle(_ style: String?) -> Bool {
            var cur = style, depth = 0
            while let c = cur, depth < 10 {
                if c == "Title" { return true }
                cur = parents[c]; depth += 1
            }
            return false
        }

        // Pictures → markers.
        var n = 0
        for frame in descendants(root, named: "frame") {
            guard let image = frame.children("image").first, let href = image.attr("href"), let media = zip[href] else { continue }
            n += 1
            let size = NSSize(width: odfLength(frame.attr("width")) ?? 200, height: odfLength(frame.attr("height")) ?? 150)
            extras.images[n] = (media, size)
            if let parent = frame.parent as? XMLElement {
                parent.replaceChild(at: frame.index, with: XMLNode.text(withStringValue: ImageMarkers.marker(n)) as! XMLNode)
            }
        }

        // Comments and footnotes → markers (the system reader drops them).
        markAnnotations(root, extras: &extras)

        // Named paragraph styles; each paragraph keeps the one its (automatic) style derives from.
        let named = OdtStyles.read(stylesDoc?.rootElement())
        extras.styles = named.filter { $0.id != "Normal" }
        var namedIds: [String: String] = [:]
        for s in descendants(stylesDoc?.rootElement(), named: "style") where s.attr("family") == "paragraph" && (s.parent as? XMLElement)?.localName == "styles" {
            if let n = s.attr("name") { namedIds[n] = OdtStyles.id(n, display: s.attr("display-name")) ?? n }
        }
        func namedStyle(_ style: String?) -> String? {
            var cur = style, depth = 0
            while let c = cur, depth < 12 {
                if let id = namedIds[c] { return id }
                cur = parents[c]; depth += 1
            }
            return nil
        }
        // Headings and the title keep their Word style through the system reader.
        for p in descendants(root, named: "h") + descendants(root, named: "p") {
            var word: String?
            if let id = namedStyle(p.attr("style-name")), id != "Normal", !(p.localName == "h" && !id.hasPrefix("Heading") && id != "Title") {
                word = id
            } else if p.localName == "h" {
                let level = Int(p.attr("outline-level") ?? "1") ?? 1
                word = isTitle(p.attr("style-name")) ? "Title" : "Heading\(min(3, max(1, level)))"
            } else if isTitle(p.attr("style-name")) {
                word = "Title"
            }
            if let word { p.insertChild(XMLNode.text(withStringValue: "\u{E002}\(word)\u{E003}") as! XMLNode, at: 0) }
        }

        // Bullets drawn with symbol-font private-use characters show as boxes.
        for doc in [content, stylesDoc].compactMap({ $0 }) {
            for level in descendants(doc.rootElement(), named: "list-level-style-bullet") {
                guard let attr = level.attributes?.first(where: { $0.localName == "bullet-char" }),
                      let ch = attr.stringValue?.unicodeScalars.first else { continue }
                if (0xE000...0xF8FF).contains(ch.value) || ch.value == 0xFFFD { attr.stringValue = "•" }
            }
        }

        // Page layout, header and footer of the default master page.
        if let styles = stylesDoc?.rootElement() {
            let masters = descendants(styles, named: "master-page")
            if let master = masters.first(where: { ["Standard", "Default"].contains($0.attr("name") ?? "") }) ?? masters.first {
                if let layoutName = master.attr("page-layout-name"),
                   let layout = descendants(styles, named: "page-layout").first(where: { $0.attr("name") == layoutName }),
                   let props = layout.child("page-layout-properties") {
                    extras.hasSetup = true
                    if let w = odfLength(props.attr("page-width")), let h = odfLength(props.attr("page-height")), w > 0, h > 0 {
                        extras.setup.size = NSSize(width: w, height: h)
                    }
                    let m = extras.setup.margins
                    extras.setup.margins = NSEdgeInsets(top: odfLength(props.attr("margin-top")) ?? m.top, left: odfLength(props.attr("margin-left")) ?? m.left,
                                                        bottom: odfLength(props.attr("margin-bottom")) ?? m.bottom, right: odfLength(props.attr("margin-right")) ?? m.right)
                }
                func text(_ e: XMLElement?) -> (String, Bool) {
                    guard let e else { return ("", false) }
                    let numbered = !descendants(e, named: "page-number").isEmpty
                    let lines = descendants(e, named: "p").map { p -> String in
                        textSkipping(p, ["page-number", "page-count"])
                    }
                    return (lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " "), numbered)
                }
                let (header, _) = text(master.child("header"))
                let (footer, numbered) = text(master.child("footer"))
                extras.setup.header = header
                extras.setup.footer = footer
                extras.setup.pageNumbers = numbered
            }
            zip["styles.xml"] = stylesDoc!.xmlData(options: [.nodePreserveWhitespace])
        }
        zip["content.xml"] = content.xmlData(options: [.nodePreserveWhitespace])
        zip.storedUncompressed.insert("mimetype")
        return (zip.data(), extras)
    }

    /// Adds pictures, page layout, header and footer to the system writer's .odt.
    static func finish(_ data: Data, pictures: [ImageMarkers.Picture], setup: PageSetup, tableBorders: Bool,
                       comments: [DocComment] = [], notes: [DocNote] = [], styles sheet: StyleSheet? = nil) -> Data {
        guard var zip = try? ZipArchive(data: data), let contentData = zip["content.xml"],
              var content = String(data: contentData, encoding: .utf8) else { return data }
        // The system writer drops cell borders.
        if tableBorders {
            content = content.replacingOccurrences(of: "<style:table-cell-properties (?![^>]*fo:border)", with: "<style:table-cell-properties fo:border=\"0.5pt solid #999999\" ",
                                                   options: .regularExpression)
        }
        // Pictures
        let ns = content as NSString
        var out = ""
        var last = 0
        for m in ImageMarkers.pattern.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            guard n >= 1, n <= pictures.count else { continue }
            let p = pictures[n - 1]
            zip["Pictures/image\(n).png"] = p.png
            out += """
            <draw:frame draw:name="Image\(n)" text:anchor-type="as-char" svg:width="\(odf(p.size.width))" svg:height="\(odf(p.size.height))" draw:z-index="\(n)">\
            <draw:image xlink:href="Pictures/image\(n).png" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/></draw:frame>
            """
        }
        out += ns.substring(from: last)
        content = finishAnnotations(out, comments: comments, notes: notes)
        if sheet != nil { content = OdtStyles.apply(content).0 }
        zip["content.xml"] = Data(content.utf8)

        if !pictures.isEmpty, let manifestData = zip["META-INF/manifest.xml"], var manifest = String(data: manifestData, encoding: .utf8),
           let close = manifest.range(of: "</manifest:manifest>") {
            let entries = (1...pictures.count).map { "<manifest:file-entry manifest:full-path=\"Pictures/image\($0).png\" manifest:media-type=\"image/png\"/>" }.joined()
            manifest.replaceSubrange(close, with: entries + "</manifest:manifest>")
            zip["META-INF/manifest.xml"] = Data(manifest.utf8)
        }

        // Page layout + master page with header and footer.
        if let stylesData = zip["styles.xml"], var styles = String(data: stylesData, encoding: .utf8) {
            let m = setup.margins
            let layout = """
            <style:page-layout style:name="K42pm"><style:page-layout-properties fo:page-width="\(odf(setup.size.width))" fo:page-height="\(odf(setup.size.height))" \
            style:print-orientation="\(setup.size.width > setup.size.height ? "landscape" : "portrait")" fo:margin-top="\(odf(m.top))" fo:margin-bottom="\(odf(m.bottom))" \
            fo:margin-left="\(odf(m.left))" fo:margin-right="\(odf(m.right))"/></style:page-layout>\
            <style:style style:name="K42hf" style:family="paragraph"><style:paragraph-properties fo:text-align="center"/>\
            <style:text-properties fo:font-size="9pt" fo:color="#666666"/></style:style>
            """
            func part(_ tag: String, _ text: String, number: Bool) -> String {
                guard !text.isEmpty || number else { return "" }
                let page = number ? (text.isEmpty ? "" : " ") + "<text:page-number text:select-page=\"current\">1</text:page-number>" : ""
                return "<style:\(tag)><text:p text:style-name=\"K42hf\">\(xmlEscape(text))\(page)</text:p></style:\(tag)>"
            }
            let master = "<office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"K42pm\">"
                + part("header", setup.header, number: false) + part("footer", setup.footer, number: setup.pageNumbers)
                + "</style:master-page></office:master-styles>"
            styles = styles.replacingOccurrences(of: "<office:master-styles>[\\s\\S]*?</office:master-styles>|<office:master-styles/>", with: "", options: .regularExpression)
            if let r = styles.range(of: "</office:automatic-styles>") {
                styles.replaceSubrange(r, with: layout + "</office:automatic-styles>")
            } else if let r = styles.range(of: "<office:automatic-styles/>") {
                styles.replaceSubrange(r, with: "<office:automatic-styles>" + layout + "</office:automatic-styles>")
            } else if let r = styles.range(of: "</office:styles>") {
                styles.replaceSubrange(r, with: "</office:styles><office:automatic-styles>" + layout + "</office:automatic-styles>")
            }
            if let r = styles.range(of: "</office:document-styles>") { styles.replaceSubrange(r, with: master + "</office:document-styles>") }
            if let sheet {
                let defs = OdtStyles.definitions(sheet)
                if let r = styles.range(of: "</office:styles>") { styles.replaceSubrange(r, with: defs + "</office:styles>") }
                else if let r = styles.range(of: "<office:styles/>") { styles.replaceSubrange(r, with: "<office:styles>" + defs + "</office:styles>") }
                else if let r = styles.range(of: "<office:automatic-styles") { styles.insert(contentsOf: "<office:styles>" + defs + "</office:styles>", at: r.lowerBound) }
            }
            zip["styles.xml"] = Data(styles.utf8)
        }
        zip.storedUncompressed.insert("mimetype")
        return zip.data()
    }

    private static func textSkipping(_ e: XMLElement, _ skip: Set<String>) -> String {
        var s = ""
        for node in e.children ?? [] {
            if let el = node as? XMLElement {
                if skip.contains(el.localName ?? "") { continue }
                if el.localName == "s" { s += " "; continue }
                if el.localName == "tab" { s += "\t"; continue }
                s += textSkipping(el, skip)
            } else if node.kind == .text {
                s += node.stringValue ?? ""
            }
        }
        return s
    }

    static func descendants(_ e: XMLElement?, named name: String) -> [XMLElement] {
        guard let e else { return [] }
        var out: [XMLElement] = []
        for case let c as XMLElement in e.children ?? [] {
            if c.localName == name { out.append(c) }
            out += descendants(c, named: name)
        }
        return out
    }
}

// MARK: - RTF

enum RtfFormat {
    /// Pictures (\pict) → markers, header/footer text collected.
    static func prepare(_ data: Data) -> (data: Data, extras: DocxStyles.Extras) {
        var extras = DocxStyles.Extras()
        let b = [UInt8](data)
        guard b.starts(with: Array("{\\rtf".utf8)) else { return (data, extras) }
        let source = String(decoding: b, as: UTF8.self)
        let codepage = Int(match(source, "\\\\ansicpg(\\d+)") ?? "") ?? 1252
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var n = 0
        var i = 0
        var annotationStarts = Set<String>()
        var annotationAuthor = "", annotationInitials = ""
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\\"), i + 1 < b.count {     // escaped character or control word: copy as is
                out.append(c); out.append(b[i + 1]); i += 2
                continue
            }
            guard c == UInt8(ascii: "{") else { out.append(c); i += 1; continue }
            let word = groupWord(b, i)
            switch word {
            case "*shppict", "pict":
                let end = groupEnd(b, i)
                if let (png, size) = picture(b, i..<end) {
                    n += 1
                    extras.images[n] = (png, size)
                    out += Array("{\\uc0\\u-8192 \(n)\\u-8191 }".utf8)
                }
                i = end
            case "nonshppict":
                i = groupEnd(b, i)
            // Word annotations (comments): range marks, author, then the annotation itself.
            case "*atrfstart", "*atrfend":
                let end = groupEnd(b, i)
                let id = annotationText(b, i..<end, codepage: codepage)
                if word == "*atrfstart" { annotationStarts.insert(id) }
                out += Array("{\\uc0\\u-8182 \(word == "*atrfstart" ? "c" : "C")r\(id)\\u-8181 }".utf8)
                i = end
            case "*atnid", "*atnauthor":
                let end = groupEnd(b, i)
                if word == "*atnid" { annotationInitials = annotationText(b, i..<end, codepage: codepage) } else { annotationAuthor = annotationText(b, i..<end, codepage: codepage) }
                i = end
            case "*annotation":
                let end = groupEnd(b, i)
                let source = String(decoding: b[i..<end], as: UTF8.self)
                let ref = match(source, "\\\\atnref ?([^}]*)\\}")?.trimmingCharacters(in: .whitespaces) ?? "\(annotationStarts.count + 1)"
                let when = match(source, "\\\\atndate ?(-?\\d+)").flatMap(Int.init).flatMap { RtfFormat.date(dttm: $0) } ?? Date()
                let text = annotationText(b, i..<end, codepage: codepage)
                extras.comments["r" + ref] = DocComment(author: annotationAuthor, initials: annotationInitials.isEmpty ? nil : annotationInitials, date: when, text: text)
                if !annotationStarts.contains(ref) { out += Array("{\\uc0\\u-8182 cr\(ref)\\u-8181 \\u-8182 Cr\(ref)\\u-8181 }".utf8) }
                annotationAuthor = ""; annotationInitials = ""
                i = end
            case "header", "headerr", "footer", "footerr":
                let end = groupEnd(b, i)
                let fields = String(decoding: b[i..<end], as: UTF8.self)
                let numbered = fields.range(of: "fldinst[^}]*PAGE", options: .regularExpression) != nil
                let text = plainText(b, i..<end, codepage: codepage).trimmingCharacters(in: .whitespacesAndNewlines)
                if word.hasPrefix("header") { extras.setup.header = text } else {
                    extras.setup.footer = text
                    extras.setup.pageNumbers = numbered
                }
                extras.hasSetup = true
                out += b[i..<end]
                i = end
            default:
                out.append(c); i += 1
            }
        }
        return (Data(out), extras)
    }

    /// Visible text of a {\*\destination …} group (its own control word left out).
    private static func annotationText(_ b: [UInt8], _ range: Range<Int>, codepage: Int) -> String {
        guard range.count > 2 else { return "" }
        var s = plainText(b, (range.lowerBound + 1)..<(range.upperBound - 1), codepage: codepage)
        if s.hasPrefix("*") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds pictures and header/footer to the system writer's RTF.
    static func finish(_ data: Data, pictures: [ImageMarkers.Picture], setup: PageSetup) -> Data {
        var s = String(decoding: data, as: UTF8.self)
        let marker = try! NSRegularExpression(pattern: "(?:\\\\uc0 ?)?\\\\u(?:57344|-8192) ?(\\d+)(?:\\\\uc0 ?)?\\\\u(?:57345|-8191) ?")
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in marker.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = NSMaxRange(m.range)
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            guard n >= 1, n <= pictures.count, let rep = NSBitmapImageRep(data: pictures[n - 1].png) else { continue }
            let size = pictures[n - 1].size
            let hex = pictures[n - 1].png.map { String(format: "%02x", $0) }.joined()
            var wrapped = ""
            for (k, ch) in hex.enumerated() {
                if k > 0, k % 128 == 0 { wrapped += "\n" }
                wrapped.append(ch)
            }
            out += "{\\pict\\pngblip\\picw\(rep.pixelsWide)\\pich\(rep.pixelsHigh)\\picwgoal\(Int(size.width * 20))\\pichgoal\(Int(size.height * 20))\n\(wrapped)}"
        }
        out += ns.substring(from: last)
        s = out
        func part(_ tag: String, _ text: String, number: Bool) -> String {
            guard !text.isEmpty || number else { return "" }
            let page = number ? (text.isEmpty ? "" : " ") + "{\\field{\\*\\fldinst PAGE}{\\fldrslt 1}}" : ""
            return "{\\\(tag)\\pard\\qc\\fs18\\cf0\\uc1 \(rtfEscape(text))\(page)\\par}\n"
        }
        // AppKit omits paper size and margins equal to its defaults. State every value explicitly:
        // DOC42's default paper differs, and missing fields must not change a saved document on reopening.
        func twips(_ points: CGFloat) -> Int {
            let value = points * 20
            guard value.isFinite else { return 0 }
            return Int(min(max(0, value), CGFloat(Int32.max)).rounded())
        }
        let m = setup.margins
        let geometry = "\\paperw\(twips(setup.size.width))\\paperh\(twips(setup.size.height))" +
            "\\margl\(twips(m.left))\\margr\(twips(m.right))\\margt\(twips(m.top))\\margb\(twips(m.bottom))\n"
        if let start = s.range(of: "^\\{\\\\rtf\\d+\\s*", options: .regularExpression) { s.insert(contentsOf: geometry, at: start.upperBound) }
        let headers = part("header", setup.header, number: false) + part("footer", setup.footer, number: setup.pageNumbers)
        if let r = s.range(of: "\\pard") { s.insert(contentsOf: headers, at: r.lowerBound) }
        else if let end = s.lastIndex(of: "}") { s.insert(contentsOf: headers, at: end) }
        return Data(s.utf8)
    }

    static func rtfEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\\", "{", "}": out += "\\" + String(u)
            case "\t": out += "\\tab "
            case "\n": out += "\\line "
            default:
                if u.value < 128 { out.unicodeScalars.append(u) } else {
                    for unit in String(u).utf16 { out += "\\u\(Int16(bitPattern: unit))?" }
                }
            }
        }
        return out
    }

    // MARK: Scanner

    /// The control word that opens the group at `i` ("*shppict" for {\*\shppict).
    private static func groupWord(_ b: [UInt8], _ i: Int) -> String {
        var j = i + 1
        while j < b.count, b[j] == 10 || b[j] == 13 { j += 1 }
        guard j < b.count, b[j] == UInt8(ascii: "\\") else { return "" }
        var prefix = ""
        if j + 2 < b.count, b[j + 1] == UInt8(ascii: "*"), b[j + 2] == UInt8(ascii: "\\") { prefix = "*"; j += 2 }
        j += 1
        var w = ""
        while j < b.count, (b[j] >= 97 && b[j] <= 122) { w.append(Character(UnicodeScalar(b[j]))); j += 1 }
        return prefix + w
    }

    /// Index just past the group that starts at `i`.
    private static func groupEnd(_ b: [UInt8], _ i: Int) -> Int {
        var depth = 0
        var j = i
        while j < b.count {
            switch b[j] {
            case UInt8(ascii: "\\"): j += 1
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return j + 1 }
            default: break
            }
            j += 1
        }
        return b.count
    }

    private struct Token {
        var word: String?
        var param: Int?
        var char: UInt8?
        var open = false, close = false
    }

    private static func tokens(_ b: [UInt8], _ range: Range<Int>, _ body: (Token, Int) -> Void) {
        var j = range.lowerBound
        var depth = 0
        while j < range.upperBound {
            let c = b[j]
            if c == UInt8(ascii: "{") { depth += 1; body(Token(open: true), depth); j += 1; continue }
            if c == UInt8(ascii: "}") { body(Token(close: true), depth); depth -= 1; j += 1; continue }
            if c == 10 || c == 13 { j += 1; continue }
            if c == UInt8(ascii: "\\"), j + 1 < range.upperBound {
                let d = b[j + 1]
                if d == UInt8(ascii: "'"), j + 3 < range.upperBound, let v = UInt8(String(decoding: b[(j + 2)...(j + 3)], as: UTF8.self), radix: 16) {
                    body(Token(word: "'", param: Int(v)), depth); j += 4; continue
                }
                if !(d >= 97 && d <= 122) { body(Token(char: d), depth); j += 2; continue }
                var k = j + 1
                var w = ""
                while k < range.upperBound, b[k] >= 97, b[k] <= 122 { w.append(Character(UnicodeScalar(b[k]))); k += 1 }
                var num = ""
                if k < range.upperBound, b[k] == UInt8(ascii: "-") { num = "-"; k += 1 }
                while k < range.upperBound, b[k] >= 48, b[k] <= 57 { num.append(Character(UnicodeScalar(b[k]))); k += 1 }
                if k < range.upperBound, b[k] == UInt8(ascii: " ") { k += 1 }
                body(Token(word: w, param: Int(num)), depth)
                j = k
                continue
            }
            body(Token(char: c), depth)
            j += 1
        }
    }

    /// Visible text of a group: \uN, \'hh, plain characters; skips {\*…} destinations, field instructions and pictures.
    static func plainText(_ b: [UInt8], _ range: Range<Int>, codepage: Int) -> String {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(UInt32(codepage))))
        var out = ""
        var skipDepth: Int?
        var pendingDestination = false
        var uc = 1, skipChars = 0
        var bytes: [UInt8] = []
        func flush() {
            if !bytes.isEmpty { out += String(data: Data(bytes), encoding: encoding) ?? String(decoding: bytes, as: UTF8.self); bytes = [] }
        }
        tokens(b, range) { t, depth in
            if let s = skipDepth {
                if t.close, depth == s { skipDepth = nil }
                return
            }
            if t.open { pendingDestination = true; return }
            let first = pendingDestination
            pendingDestination = false
            if t.close { return }
            if let w = t.word {
                if first, ["*", "fldinst", "pict", "fonttbl", "colortbl", "stylesheet", "info"].contains(w) { skipDepth = depth; return }
                switch w {
                case "uc": uc = t.param ?? 1
                case "u":
                    flush()
                    if let v = t.param { out += String(utf16CodeUnits: [UInt16(bitPattern: Int16(truncatingIfNeeded: v))], count: 1) }
                    skipChars = uc
                case "'":
                    if skipChars > 0 { skipChars -= 1 } else if let v = t.param { bytes.append(UInt8(v)) }
                case "tab": flush(); out += "\t"
                case "par", "line": flush(); out += "\n"
                default: break
                }
                return
            }
            if let c = t.char {
                if first, c == UInt8(ascii: "*") { skipDepth = depth; return }
                if skipChars > 0 { skipChars -= 1; return }
                bytes.append(c)
            }
        }
        flush()
        return out
    }

    /// PNG/JPEG data and display size of the \pict group inside `range`.
    private static func picture(_ b: [UInt8], _ range: Range<Int>) -> (Data, NSSize)? {
        var params: [String: Int] = [:]
        var kind = ""
        var hex: [UInt8] = []
        var pictDepth: Int?
        tokens(b, range) { t, depth in
            if let w = t.word, w == "pict" { pictDepth = depth; return }
            guard let pd = pictDepth, depth == pd else { return }
            if let w = t.word {
                if ["pngblip", "jpegblip", "emfblip", "wmetafile", "macpict", "dibitmap", "wbitmap"].contains(w) { kind = w }
                if let p = t.param { params[w] = p }
            } else if let c = t.char {
                if (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) { hex.append(c) }
            }
        }
        guard kind == "pngblip" || kind == "jpegblip", hex.count >= 2 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var k = 0
        while k + 1 < hex.count {
            data.append(UInt8(String(decoding: hex[k...(k + 1)], as: UTF8.self), radix: 16) ?? 0)
            k += 2
        }
        guard let image = NSImage(data: data) else { return nil }
        var size = image.size
        if let w = params["picwgoal"], let h = params["pichgoal"], w > 0, h > 0 { size = NSSize(width: CGFloat(w) / 20, height: CGFloat(h) / 20) }
        size.width *= CGFloat(params["picscalex"] ?? 100) / 100
        size.height *= CGFloat(params["picscaley"] ?? 100) / 100
        return (data, size)
    }

    private static func match(_ s: String, _ pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let g = Range(r.range(at: 1), in: s) else { return nil }
        return String(s[g])
    }
}
