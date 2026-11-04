import AppKit

// MARK: - Document objects carried in attributed strings (footnotes, comments, sections, bookmarks)

/// A footnote: set as `.docNote` on its reference character.
public final class DocNote: NSObject {
    public var text: String
    public init(_ text: String) { self.text = text }
}

/// A margin comment: set as `.docComment` on the commented range.
public final class DocComment: NSObject {
    public var author: String
    public var initials: String
    public var date: Date
    public var text: String
    public var resolved: Bool
    public init(author: String, initials: String? = nil, date: Date = Date(), text: String = "", resolved: Bool = false) {
        self.author = author
        self.initials = initials ?? String(author.split(separator: " ").compactMap(\.first))
        self.date = date
        self.text = text
        self.resolved = resolved
    }
}

/// Page layout of the section that ends at a section break: set as `.docSection` on the break character (form feed).
public final class DocSection: NSObject {
    public let pageSize: NSSize
    public let margins: NSEdgeInsets
    public let columns: Int
    public let columnSpacing: CGFloat
    public init(pageSize: NSSize, margins: NSEdgeInsets, columns: Int = 1, columnSpacing: CGFloat = 36) {
        self.pageSize = pageSize
        self.margins = margins
        self.columns = max(1, columns)
        self.columnSpacing = columnSpacing
    }
}

public extension NSAttributedString.Key {
    /// DocNote on a footnote reference character.
    static let docNote = NSAttributedString.Key("Kit42.note")
    /// DocComment on a commented range.
    static let docComment = NSAttributedString.Key("Kit42.comment")
    /// Bookmark name (String) on a paragraph: target of "#name" links.
    static let docBookmark = NSAttributedString.Key("Kit42.bookmark")
    /// DocSection on a section break character.
    static let docSection = NSAttributedString.Key("Kit42.section")
    /// "dot" on a tab character: drawn and saved with a dot leader (tables of contents).
    static let docTabLeader = NSAttributedString.Key("Kit42.leader")
}

/// Writes an attributed string as .docx. Replaces the system writer, which drops tables.
/// Covers paragraphs, runs (font, size, bold/italic/underline/strike, colour, highlight),
/// alignment, spacing, indents, tabs, page breaks, tables (NSTextTable), images, hyperlinks,
/// bookmarks, footnotes, comments, sections (page size, orientation, margins, columns) and TOC fields.
public enum DocxWriter {
    public struct Options {
        public var pageSize = NSSize(width: 595, height: 842)
        public var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        public var header = ""
        public var footer = ""
        public var pageNumbers = false
        /// Text columns of the last section.
        public var columns = 1
        public var columnSpacing: CGFloat = 36
        /// Word style id for a paragraph (e.g. "Heading1"), so outlines and tables of contents work in Word.
        public var paragraphStyle: ((NSAttributedString, NSRange) -> String?)?
        public init() {}
    }

    public static func data(_ text: NSAttributedString, pageSize: NSSize) -> Data {
        var o = Options()
        o.pageSize = pageSize
        return data(text, options: o)
    }

    /// State of one write: parts collected while the body is written.
    private final class Context {
        var media: [(name: String, data: Data)] = []
        var links: [String] = []                    // external hyperlink targets → rIdLinkN
        var notes: [String] = []                    // footnote texts, ids from 1
        var comments: [DocComment] = []
        var commentIds: [ObjectIdentifier: Int] = [:]
        var commentStarts: [Int: [Int]] = [:]       // character index → comment ids starting there
        var commentEnds: [Int: [Int]] = [:]
        var bookmarks = 0
        var sectPr: (DocSection) -> String = { _ in "" }
    }

    public static func data(_ text: NSAttributedString, options: Options = Options()) -> Data {
        styleProvider = options.paragraphStyle
        let ctx = Context()
        var body = ""
        let ns = text.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Comment ranges, start and end moved off paragraph marks.
        text.enumerateAttribute(.docComment, in: full) { v, r, _ in
            guard let c = v as? DocComment else { return }
            let key = ObjectIdentifier(c)
            if ctx.commentIds[key] == nil {
                ctx.comments.append(c)
                ctx.commentIds[key] = ctx.comments.count - 1
            }
        }
        for (k, c) in ctx.comments.enumerated() {
            var start = Int.max, end = 0
            text.enumerateAttribute(.docComment, in: full) { v, r, _ in
                if (v as? DocComment) === c { start = min(start, r.location); end = max(end, NSMaxRange(r)) }
            }
            while start < end, isParagraphMark(ns.character(at: start)) { start += 1 }
            while end > start, isParagraphMark(ns.character(at: end - 1)) { end -= 1 }
            ctx.commentStarts[start, default: []].append(k)
            ctx.commentEnds[end, default: []].append(k)
        }

        // Paragraph ranges; a section break ends its paragraph.
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            var start = r.location
            text.enumerateAttribute(.docSection, in: r) { v, sr, _ in
                guard v is DocSection else { return }
                paragraphs.append(NSRange(location: start, length: NSMaxRange(sr) - start))
                start = NSMaxRange(sr)
            }
            if start < NSMaxRange(r) || start == r.location { paragraphs.append(NSRange(location: start, length: NSMaxRange(r) - start)) }
        }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: 0, length: 0)] }

        func style(at r: NSRange) -> NSParagraphStyle? {
            guard text.length > 0 else { return nil }
            return text.attribute(.paragraphStyle, at: min(r.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle
        }

        let twip = { (pt: CGFloat) in Int((pt * 20).rounded()) }
        let hasHeader = !options.header.isEmpty
        let hasFooter = !options.footer.isEmpty || options.pageNumbers
        ctx.sectPr = { s in
            var x = "<w:sectPr>"
            if hasHeader { x += "<w:headerReference w:type=\"default\" r:id=\"rIdHeader\"/>" }
            if hasFooter { x += "<w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/>" }
            let m = s.margins
            x += "<w:pgSz w:w=\"\(twip(s.pageSize.width))\" w:h=\"\(twip(s.pageSize.height))\"\(s.pageSize.width > s.pageSize.height ? " w:orient=\"landscape\"" : "")/>"
            x += "<w:pgMar w:top=\"\(twip(m.top))\" w:right=\"\(twip(m.right))\" w:bottom=\"\(twip(m.bottom))\" w:left=\"\(twip(m.left))\" w:header=\"567\" w:footer=\"567\" w:gutter=\"0\"/>"
            if s.columns > 1 { x += "<w:cols w:num=\"\(s.columns)\" w:space=\"\(twip(s.columnSpacing))\"/>" }
            return x + "</w:sectPr>"
        }

        func isTOCEntry(_ r: NSRange) -> Bool {
            guard let s = styleProvider?(text, r) else { return false }
            return s.hasPrefix("TOC") && s != "TOCHeading"
        }

        var i = 0
        while i < paragraphs.count {
            let r = paragraphs[i]
            if let block = style(at: r)?.textBlocks.last as? NSTextTableBlock {
                // Collect the whole table
                let table = block.table
                var cells: [[Int: [NSRange]]] = []   // row → col → paragraphs
                var columns = table.numberOfColumns
                while i < paragraphs.count, let b = style(at: paragraphs[i])?.textBlocks.last as? NSTextTableBlock, b.table === table {
                    while cells.count <= b.startingRow { cells.append([:]) }
                    cells[b.startingRow][b.startingColumn, default: []].append(paragraphs[i])
                    columns = max(columns, b.startingColumn + b.columnSpan)
                    i += 1
                }
                body += tableXML(cells, columns: columns, text: text, ctx: ctx, border: block)
                continue
            }
            // A table of contents is one field around its entries.
            let toc = isTOCEntry(r)
            let begin = toc && (i == 0 || !isTOCEntry(paragraphs[i - 1]))
            let end = toc && (i + 1 == paragraphs.count || !isTOCEntry(paragraphs[i + 1]))
            body += paragraphXML(r, text: text, ctx: ctx, fieldBegin: begin ? " TOC \\o \"1-3\" \\h \\z \\u " : nil, fieldEnd: end)
            i += 1
        }

        body += ctx.sectPr(DocSection(pageSize: options.pageSize, margins: options.margins, columns: options.columns, columnSpacing: options.columnSpacing))

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """

        let hasNotes = !ctx.notes.isEmpty, hasComments = !ctx.comments.isEmpty
        let hasResolved = ctx.comments.contains(where: \.resolved)
        var zip = ZipArchive()
        var types = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
        <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        """
        let wml = "application/vnd.openxmlformats-officedocument.wordprocessingml."
        if hasNotes {
            types += "<Override PartName=\"/word/footnotes.xml\" ContentType=\"\(wml)footnotes+xml\"/>"
            types += "<Override PartName=\"/word/settings.xml\" ContentType=\"\(wml)settings+xml\"/>"
        }
        if hasComments { types += "<Override PartName=\"/word/comments.xml\" ContentType=\"\(wml)comments+xml\"/>" }
        if hasResolved { types += "<Override PartName=\"/word/commentsExtended.xml\" ContentType=\"\(wml)commentsExtended+xml\"/>" }
        zip["[Content_Types].xml"] = Data((types + "\n</Types>").utf8)
        zip["_rels/.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """.utf8)
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for (n, m) in ctx.media.enumerated() {
            rels += "<Relationship Id=\"rIdImg\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(m.name)\"/>"
            zip["word/media/\(m.name)"] = m.data
        }
        for (n, url) in ctx.links.enumerated() {
            rels += "<Relationship Id=\"rIdLink\(n + 1)\" Type=\"\(relType)hyperlink\" Target=\"\(xmlEscape(url))\" TargetMode=\"External\"/>"
        }
        if hasHeader {
            rels += "<Relationship Id=\"rIdHeader\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>"
            zip["word/header1.xml"] = Data(headerFooterXML("hdr", text: options.header, pageNumber: false).utf8)
        }
        if hasFooter {
            rels += "<Relationship Id=\"rIdFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>"
            zip["word/footer1.xml"] = Data(headerFooterXML("ftr", text: options.footer, pageNumber: options.pageNumbers).utf8)
        }
        let wNS = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        if hasNotes {
            rels += "<Relationship Id=\"rIdNotes\" Type=\"\(relType)footnotes\" Target=\"footnotes.xml\"/>"
            rels += "<Relationship Id=\"rIdSettings\" Type=\"\(relType)settings\" Target=\"settings.xml\"/>"
            var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:footnotes \(wNS)>"
            x += "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote>"
            x += "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
            for (k, note) in ctx.notes.enumerated() {
                x += "<w:footnote w:id=\"\(k + 1)\">"
                for (line, s) in note.components(separatedBy: "\n").enumerated() {
                    x += "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>"
                    if line == 0 { x += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/><w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteRef/></w:r>" }
                    x += "<w:r><w:t xml:space=\"preserve\">\(line == 0 ? " " : "")\(xmlEscape(s))</w:t></w:r></w:p>"
                }
                x += "</w:footnote>"
            }
            zip["word/footnotes.xml"] = Data((x + "</w:footnotes>").utf8)
            zip["word/settings.xml"] = Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:settings \(wNS)><w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr></w:settings>
            """.utf8)
        }
        if hasComments {
            rels += "<Relationship Id=\"rIdComments\" Type=\"\(relType)comments\" Target=\"comments.xml\"/>"
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:comments \(wNS) xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\">"
            var extended = ""
            for (k, c) in ctx.comments.enumerated() {
                x += "<w:comment w:id=\"\(k)\" w:author=\"\(xmlEscape(c.author))\" w:date=\"\(iso.string(from: c.date))\" w:initials=\"\(xmlEscape(c.initials))\">"
                let lines = c.text.components(separatedBy: "\n")
                let paraId = String(format: "%08X", 0x10000000 + k)
                for (line, s) in lines.enumerated() {
                    x += "<w:p\(line == lines.count - 1 ? " w14:paraId=\"\(paraId)\"" : "")><w:pPr><w:pStyle w:val=\"CommentText\"/></w:pPr>"
                    if line == 0 { x += "<w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:annotationRef/></w:r>" }
                    x += "<w:r><w:t xml:space=\"preserve\">\(xmlEscape(s))</w:t></w:r></w:p>"
                }
                x += "</w:comment>"
                extended += "<w15:commentEx w15:paraId=\"\(paraId)\" w15:done=\"\(c.resolved ? 1 : 0)\"/>"
            }
            zip["word/comments.xml"] = Data((x + "</w:comments>").utf8)
            if hasResolved {
                rels += "<Relationship Id=\"rIdCommentsEx\" Type=\"http://schemas.microsoft.com/office/2011/relationships/commentsExtended\" Target=\"commentsExtended.xml\"/>"
                zip["word/commentsExtended.xml"] = Data("""
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w15:commentsEx xmlns:w15="http://schemas.microsoft.com/office/word/2012/wordml">\(extended)</w15:commentsEx>
                """.utf8)
            }
        }
        rels += "</Relationships>"
        zip["word/_rels/document.xml.rels"] = Data(rels.utf8)
        zip["word/styles.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Helvetica Neue" w:eastAsia="Helvetica Neue"/>\
        <w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="2"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/></w:style>
        <w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="TOC1"><w:name w:val="toc 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="TOC2"><w:name w:val="toc 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="TOC3"><w:name w:val="toc 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/></w:style>
        <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="CommentText"><w:name w:val="annotation text"/><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style>
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/></w:style>
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="CommentReference"><w:name w:val="annotation reference"/><w:rPr><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr></w:style>
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblCellMar>\
        <w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
        </w:styles>
        """.utf8)
        zip["word/document.xml"] = Data(document.utf8)
        return zip.data()
    }

    private static func isParagraphMark(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2029 }

    // MARK: - Paragraphs

    private static var styleProvider: ((NSAttributedString, NSRange) -> String?)?

    private static func headerFooterXML(_ tag: String, text: String, pageNumber: Bool) -> String {
        var p = "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
        if !text.isEmpty { p += "<w:r><w:rPr><w:sz w:val=\"18\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(text))\(pageNumber ? "  " : "")</w:t></w:r>" }
        if pageNumber { p += "<w:fldSimple w:instr=\" PAGE \"><w:r><w:rPr><w:sz w:val=\"18\"/></w:rPr><w:t>1</w:t></w:r></w:fldSimple>" }
        p += "</w:p>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:\(tag) xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(p)</w:\(tag)>"
    }

    private static func paragraphXML(_ r: NSRange, text: NSAttributedString, ctx: Context, fieldBegin: String? = nil, fieldEnd: Bool = false) -> String {
        var x = "<w:p>"
        var bookmark: (Int, String)?
        if text.length > 0 {
            let at = min(r.location, text.length - 1)
            let p = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            var leader = false
            if r.length > 0 { text.enumerateAttribute(.docTabLeader, in: r) { v, _, stop in if v != nil { leader = true; stop.pointee = true } } }
            // A section break at the end of the paragraph: its sectPr closes the section.
            var sect: String?
            if r.length > 0, let s = text.attribute(.docSection, at: NSMaxRange(r) - 1, effectiveRange: nil) as? DocSection { sect = ctx.sectPr(s) }
            x += paragraphProperties(p, style: styleProvider?(text, r), leader: leader, sectPr: sect)
            if let name = text.attribute(.docBookmark, at: at, effectiveRange: nil) as? String, !name.isEmpty {
                ctx.bookmarks += 1
                bookmark = (ctx.bookmarks, name)
                x += "<w:bookmarkStart w:id=\"\(ctx.bookmarks)\" w:name=\"\(xmlEscape(name))\"/>"
            }
        }
        if let instr = fieldBegin {
            x += "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText xml:space=\"preserve\">\(xmlEscape(instr))</w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
        }
        func commentMarks(_ at: Int, end: Bool) -> String {
            let ids = (end ? ctx.commentEnds : ctx.commentStarts)[at] ?? []
            return ids.map { id in
                end ? "<w:commentRangeEnd w:id=\"\(id)\"/><w:r><w:rPr><w:rStyle w:val=\"CommentReference\"/></w:rPr><w:commentReference w:id=\"\(id)\"/></w:r>"
                    : "<w:commentRangeStart w:id=\"\(id)\"/>"
            }.joined()
        }
        var openLink: String?
        func setLink(_ link: String?) {
            guard link != openLink else { return }
            if openLink != nil { x += "</w:hyperlink>" }
            openLink = link
            guard let link else { return }
            if link.hasPrefix("#") {
                x += "<w:hyperlink w:anchor=\"\(xmlEscape(String(link.dropFirst())))\" w:history=\"1\">"
            } else {
                let n = (ctx.links.firstIndex(of: link) ?? { ctx.links.append(link); return ctx.links.count - 1 }()) + 1
                x += "<w:hyperlink r:id=\"rIdLink\(n)\" w:history=\"1\">"
            }
        }
        if r.length == 0 {
            x += commentMarks(r.location, end: false) + commentMarks(r.location, end: true)
        } else {
            text.enumerateAttributes(in: r) { attrs, run, _ in
                let link = (attrs[.link] as? URL)?.absoluteString ?? (attrs[.link] as? String)
                if attrs[.docSection] != nil { return }   // the break itself is the sectPr
                if ctx.commentStarts[run.location] != nil { setLink(nil); x += commentMarks(run.location, end: false) }
                setLink(link)
                if let note = attrs[.docNote] as? DocNote {
                    ctx.notes.append(note.text)
                    x += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/><w:vertAlign w:val=\"superscript\"/></w:rPr><w:footnoteReference w:id=\"\(ctx.notes.count)\"/></w:r>"
                } else if let attachment = attrs[.attachment] as? NSTextAttachment {
                    x += imageXML(attachment, ctx: ctx)
                } else {
                    let s = (text.string as NSString).substring(with: run)
                    x += runXML(s, attrs, style: link == nil || link!.hasPrefix("#") ? nil : "Hyperlink")
                }
                if ctx.commentEnds[NSMaxRange(run)] != nil { setLink(nil); x += commentMarks(NSMaxRange(run), end: true) }
            }
            setLink(nil)
        }
        if fieldEnd { x += "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>" }
        if let (id, _) = bookmark { x += "<w:bookmarkEnd w:id=\"\(id)\"/>" }
        return x + "</w:p>"
    }

    private static func paragraphProperties(_ p: NSParagraphStyle?, style: String? = nil, leader: Bool = false, sectPr: String? = nil) -> String {
        guard let p else {
            if style == nil && sectPr == nil { return "" }
            return "<w:pPr>" + (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + (sectPr ?? "") + "</w:pPr>"
        }
        var x = "<w:pPr>"
        if let style { x += "<w:pStyle w:val=\"\(style)\"/>" }
        let twip = { (pt: CGFloat) in Int((pt * 20).rounded()) }
        if leader, let stop = p.tabStops.last(where: { $0.alignment == .right }) ?? p.tabStops.last {
            x += "<w:tabs><w:tab w:val=\"\(stop.alignment == .right ? "right" : "left")\" w:leader=\"dot\" w:pos=\"\(twip(stop.location))\"/></w:tabs>"
        }
        if p.minimumLineHeight > 0, p.minimumLineHeight == p.maximumLineHeight {
            x += "<w:spacing w:before=\"\(twip(p.paragraphSpacingBefore))\" w:after=\"\(twip(p.paragraphSpacing))\" w:line=\"\(twip(p.minimumLineHeight))\" w:lineRule=\"exact\"/>"
        } else {
            let line = p.lineHeightMultiple > 0 ? Int((p.lineHeightMultiple * 240).rounded()) : 240
            x += "<w:spacing w:before=\"\(twip(p.paragraphSpacingBefore))\" w:after=\"\(twip(p.paragraphSpacing))\" w:line=\"\(line)\" w:lineRule=\"auto\"/>"
        }
        if p.headIndent > 0 || p.firstLineHeadIndent > 0 || p.tailIndent < 0 {
            let left = twip(p.headIndent)
            let first = twip(p.firstLineHeadIndent) - left
            x += "<w:ind w:left=\"\(left)\"" + (p.tailIndent < 0 ? " w:right=\"\(twip(-p.tailIndent))\"" : "")
                + (first < 0 ? " w:hanging=\"\(-first)\"" : first > 0 ? " w:firstLine=\"\(first)\"" : "") + "/>"
        }
        switch p.alignment {
        case .center: x += "<w:jc w:val=\"center\"/>"
        case .right: x += "<w:jc w:val=\"right\"/>"
        case .justified: x += "<w:jc w:val=\"both\"/>"
        default: break
        }
        return x + (sectPr ?? "") + "</w:pPr>"
    }

    private static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private static func runXML(_ s: String, _ attrs: [NSAttributedString.Key: Any], style: String? = nil) -> String {
        var pr = style.map { "<w:rStyle w:val=\"\($0)\"/>" } ?? ""
        if let font = attrs[.font] as? NSFont {
            let family = xmlEscape(font.familyName ?? font.fontName)
            pr += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:cs=\"\(family)\" w:eastAsia=\"\(family)\"/>"
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { pr += "<w:b/><w:bCs/>" }
            if traits.contains(.italicFontMask) { pr += "<w:i/><w:iCs/>" }
        }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { pr += "<w:strike/>" }
        if let c = attrs[.foregroundColor] as? NSColor { pr += "<w:color w:val=\"\(hex(c))\"/>" }
        if let font = attrs[.font] as? NSFont {
            let half = Int((font.pointSize * 2).rounded())
            pr += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        }
        if (attrs[.underlineStyle] as? Int ?? 0) != 0 { pr += "<w:u w:val=\"single\"/>" }
        if let bg = attrs[.backgroundColor] as? NSColor { pr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex(bg))\"/>" }
        if let sup = attrs[.superscript] as? Int, sup != 0 { pr += "<w:vertAlign w:val=\"\(sup > 0 ? "superscript" : "subscript")\"/>" }

        var x = ""
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            x += "<w:r>\(pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>")<w:t xml:space=\"preserve\">\(xmlEscape(chunk))</w:t></w:r>"
            chunk = ""
        }
        func special(_ xml: String) {
            flush()
            x += "<w:r>\(pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>")\(xml)</w:r>"
        }
        for ch in s {
            switch ch {
            case "\t": special("<w:tab/>")
            case "\u{2028}": special("<w:br/>")
            case "\u{000C}": special("<w:br w:type=\"page\"/>")
            case "\n", "\r", "\u{2029}", "\u{FFFC}": break
            default: chunk.append(ch)
            }
        }
        flush()
        return x
    }

    // MARK: - Images

    private static func imageXML(_ attachment: NSTextAttachment, ctx: Context) -> String {
        var image = attachment.image
        if image == nil, let data = attachment.fileWrapper?.regularFileContents { image = NSImage(data: data) }
        guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return "" }
        ctx.media.append((name: "image\(ctx.media.count + 1).png", data: png))
        let n = ctx.media.count
        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 { size = image.size }
        let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(n)" name="Image \(n)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(n)" name="image\(n).png"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdImg\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    // MARK: - Tables

    private static func tableXML(_ rows: [[Int: [NSRange]]], columns: Int, text: NSAttributedString,
                                 ctx: Context, border: NSTextTableBlock) -> String {
        let color = hex(border.borderColor(for: .minX) ?? .gray)
        let width = border.width(for: .border, edge: .minX)
        let sz = max(2, Int((width * 8).rounded()))
        let edges = ["top", "left", "bottom", "right", "insideH", "insideV"]
            .map { "<w:\($0) w:val=\"\(width > 0 ? "single" : "nil")\" w:sz=\"\(sz)\" w:space=\"0\" w:color=\"\(color)\"/>" }.joined()
        var x = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>\(edges)</w:tblBorders>"
        x += "<w:tblLayout w:type=\"autofit\"/></w:tblPr><w:tblGrid>"
        for _ in 0..<columns { x += "<w:gridCol w:w=\"\(9000 / max(1, columns))\"/>" }
        x += "</w:tblGrid>"
        for row in rows {
            x += "<w:tr>"
            var c = 0
            while c < columns {
                let paragraphs = row[c] ?? []
                var span = 1
                if let first = paragraphs.first,
                   let b = (text.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock {
                    span = max(1, b.columnSpan)
                }
                x += "<w:tc><w:tcPr><w:tcW w:w=\"\(5000 * span / max(1, columns))\" w:type=\"pct\"/>\(span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")</w:tcPr>"
                if paragraphs.isEmpty { x += "<w:p/>" }
                for p in paragraphs { x += paragraphXML(p, text: text, ctx: ctx) }
                x += "</w:tc>"
                c += span
            }
            x += "</w:tr>"
        }
        return x + "</w:tbl>"
    }
}
