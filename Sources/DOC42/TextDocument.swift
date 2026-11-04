import AppKit
import Kit42
import PDFKit

@objc(TextDocument)
final class TextDocument: NSDocument {
    let storage = NSTextStorage()
    /// Page size, margins, header and footer (saved to .docx).
    var setup = PageSetup() { didSet { editor?.setupDidChange() } }

    override init() {
        super.init()
        storage.setAttributedString(NSAttributedString(string: "", attributes: Styles.normal.attributes))
    }

    override class var autosavesInPlace: Bool { false }

    var editor: DocWindowController? { windowControllers.first as? DocWindowController }

    override func makeWindowControllers() {
        addWindowController(DocWindowController(storage: storage))
    }

    static func documentType(for typeName: String) -> NSAttributedString.DocumentType {
        let t = typeName.lowercased()
        if t.contains("wordprocessingml") || t.hasSuffix("docx") { return .officeOpenXML }
        if t.contains("word.doc") || t == "doc" { return .docFormat }
        if t.contains("opendocument") || t.hasSuffix("odt") { return .openDocument }
        if t.contains("rtf") { return t.contains("rtfd") ? .rtfd : .rtf }
        if t.contains("html") { return .html }
        return .plain
    }

    static func isMarkdown(_ typeName: String) -> Bool {
        let t = typeName.lowercased()
        return t.contains("markdown") || t.hasSuffix(".md") || t == "md"
    }

    /// Encoding of an opened plain-text file: saved back the same way.
    var textEncoding: String.Encoding = .utf8
    /// Folder of the file being read: Markdown pictures are relative to it.
    private var readingFrom: URL?

    override func read(from url: URL, ofType typeName: String) throws {
        readingFrom = url.deletingLastPathComponent()
        defer { readingFrom = nil }
        try super.read(from: url, ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if Self.isMarkdown(typeName) {
            let (md, encoding) = TextDecoding.decode(data)
            textEncoding = encoding
            storage.setAttributedString(MarkdownReader.read(md, baseURL: readingFrom ?? fileURL?.deletingLastPathComponent()))
            return
        }
        let type = Self.documentType(for: typeName)
        if type == .plain {
            let (text, encoding) = TextDecoding.decode(data)
            textEncoding = encoding
            storage.setAttributedString(NSAttributedString(string: text, attributes: Styles.normal.attributes))
            return
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        var source = data
        var extras = DocxStyles.Extras()
        switch type {
        case .officeOpenXML: (source, extras) = DocxStyles.flattenWithExtras(data)
        case .openDocument: (source, extras) = OdtFormat.prepare(data)
        case .rtf: (source, extras) = RtfFormat.prepare(data)
        default: break
        }
        var attributes: NSDictionary?
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(data: source, options: options, documentAttributes: &attributes))
        DocxStyles.restoreImages(text, extras.images)
        DocxStyles.restoreStyles(text)
        DocxStyles.restoreLists(text, extras.lists)
        DocxStyles.restoreMarks(text, extras)
        if type == .rtf, let a = attributes as? [NSAttributedString.DocumentAttributeKey: Any], data.range(of: Data("\\paperw".utf8)) != nil,
           let paper = a[.paperSize] as? NSSize, paper.width > 0, paper.height > 0 {
            extras.hasSetup = true
            extras.setup.size = paper
            func m(_ k: NSAttributedString.DocumentAttributeKey, _ d: CGFloat) -> CGFloat { (a[k] as? NSNumber).map { CGFloat($0.doubleValue) } ?? d }
            let d = extras.setup.margins
            extras.setup.margins = NSEdgeInsets(top: m(.topMargin, d.top), left: m(.leftMargin, d.left), bottom: m(.bottomMargin, d.bottom), right: m(.rightMargin, d.right))
        }
        if extras.hasSetup { setup = extras.setup }
        if type == .officeOpenXML || type == .docFormat || type == .openDocument || type == .rtf { ListMarkers.insert(into: text) }
        storage.setAttributedString(text)
    }

    override func data(ofType typeName: String) throws -> Data {
        editor?.textView.breakUndoCoalescing()
        if Self.isMarkdown(typeName) { return markdownData() }
        return try exportData(Self.documentType(for: typeName))
    }

    /// Plain text in the file's own encoding when every character fits, else UTF-8.
    private func encode(_ s: String) -> Data {
        if textEncoding != .utf8, let d = s.data(using: textEncoding, allowLossyConversion: false) {
            if textEncoding == .utf16LittleEndian { return Data([0xFF, 0xFE]) + d }
            if textEncoding == .utf16BigEndian { return Data([0xFE, 0xFF]) + d }
            return d
        }
        return Data(s.utf8)
    }

    func markdownData() -> Data { encode(MarkdownWriter.write(Notes.flatten(storage))) }

    func exportData(_ type: NSAttributedString.DocumentType) throws -> Data {
        if type == .plain { return encode(Notes.flatten(storage).string) }
        if type == .officeOpenXML {
            var o = DocxWriter.Options()
            o.pageSize = setup.size
            o.margins = setup.margins
            o.header = setup.header
            o.footer = setup.footer
            o.pageNumbers = setup.pageNumbers
            o.columns = setup.columns
            o.columnSpacing = setup.columnSpacing
            o.paragraphStyle = Styles.wordStyle
            return DocxWriter.data(storage, options: o)
        }
        // Other formats have no footnotes: references become numbers, notes a list at the end.
        let storage = Notes.flatten(self.storage)
        let range = NSRange(location: 0, length: storage.length)
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        if type == .rtf || type == .openDocument {
            // Pictures, page setup, header and footer are added to the system writer's output.
            let (text, pictures) = ImageMarkers.extract(storage)
            attrs[.paperSize] = setup.size
            attrs[.topMargin] = setup.margins.top
            attrs[.bottomMargin] = setup.margins.bottom
            attrs[.leftMargin] = setup.margins.left
            attrs[.rightMargin] = setup.margins.right
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
            if type == .rtf { return RtfFormat.finish(data, pictures: pictures, setup: setup) }
            var borders = false
            storage.enumerateAttribute(.paragraphStyle, in: range) { v, _, stop in
                if let b = (v as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock, b.width(for: .border, edge: .minX) > 0 { borders = true; stop.pointee = true }
            }
            return OdtFormat.finish(data, pictures: pictures, setup: setup, tableBorders: borders)
        }
        return try storage.data(from: range, documentAttributes: attrs)
    }

    /// Paginated PDF of the document: exactly the pages shown on screen.
    func pdfData() -> Data {
        let view = offscreenPages()
        defer { view.detach() }
        // Sections in another size or orientation: each page as its own sheet.
        if view.hasMixedPageSizes { return view.pdfData() }
        return PaginatedPDF.render(view, info: pageInfo())
    }

    /// Paper = page size, no extra margins: each page card is one sheet.
    func pageInfo() -> NSPrintInfo {
        let info = printInfo.copy() as! NSPrintInfo
        info.paperSize = setup.size
        info.orientation = setup.size.width > setup.size.height ? .landscape : .portrait
        info.leftMargin = 0; info.rightMargin = 0; info.topMargin = 0; info.bottomMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    func debugPages() {
        let v = offscreenPages()
        for (i, c) in v.cards.enumerated() {
            for (j, tv) in c.textViews.enumerated() {
                let g = v.layoutManager.glyphRange(for: tv.textContainer!)
                let chars = v.layoutManager.characterRange(forGlyphRange: g, actualGlyphRange: nil)
                Swift.print(i, j, c.frame, "chars", chars, "notes", c.notes.map(\.0), (storage.string as NSString).substring(with: NSRange(location: chars.location, length: min(20, chars.length))).debugDescription)
            }
        }
        v.detach()
    }

    func offscreenPages() -> PagedView {
        let view = PagedView(storage: storage, setup: setup) { tv in
            tv.backgroundColor = .white
            tv.drawsBackground = false
        }
        view.layoutAll()
        return view
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let view = offscreenPages()
        if view.hasMixedPageSizes, let pdf = PDFDocument(data: view.pdfData()),
           let op = pdf.printOperation(for: pageInfo(), scalingMode: .pageScaleNone, autoRotate: true) {
            view.detach()
            op.jobTitle = displayName
            op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview, .showsPageRange])
            return op
        }
        let op = NSPrintOperation(view: view, printInfo: pageInfo())
        op.jobTitle = displayName
        op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview, .showsPageRange])
        return op
    }
}

/// Paragraph styles offered in DOC42; saved as direct formatting plus the matching Word style.
struct Styles {
    /// Word style id for a paragraph: from the explicit style mark, else by its look.
    static func wordStyle(_ text: NSAttributedString, _ range: NSRange) -> String? {
        guard text.length > 0 else { return nil }
        let at = min(range.location, text.length - 1)
        if let name = text.attribute(styleKey, at: at, effectiveRange: nil) as? String { return name }
        guard let font = text.attribute(.font, at: at, effectiveRange: nil) as? NSFont else { return nil }
        let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        switch font.pointSize {
        case 24...: return "Title"
        case 18..<24 where bold: return "Heading1"
        case 15..<18 where bold: return "Heading2"
        case 13..<15 where bold: return "Heading3"
        default: return nil
        }
    }

    static let styleKey = NSAttributedString.Key("DOC42.style")
    static let wordIds = ["Title", "Heading1", "Heading2", "Heading3", nil, "Quote"]

    let name: String
    let size: CGFloat
    let weight: NSFont.Weight
    let spacingBefore: CGFloat
    let spacingAfter: CGFloat
    let color: NSColor
    let italic: Bool

    static let normal = Styles(name: L("Body"), size: 12, weight: .regular, spacingBefore: 0, spacingAfter: 6, color: .black, italic: false)
    static let all: [Styles] = [
        Styles(name: L("Title"), size: 26, weight: .bold, spacingBefore: 0, spacingAfter: 12, color: .black, italic: false),
        Styles(name: L("Heading 1"), size: 20, weight: .bold, spacingBefore: 18, spacingAfter: 6, color: .black, italic: false),
        Styles(name: L("Heading 2"), size: 16, weight: .semibold, spacingBefore: 14, spacingAfter: 4, color: .black, italic: false),
        Styles(name: L("Heading 3"), size: 13, weight: .semibold, spacingBefore: 10, spacingAfter: 2, color: NSColor(white: 0.25, alpha: 1), italic: false),
        normal,
        Styles(name: L("Quote"), size: 12, weight: .regular, spacingBefore: 6, spacingAfter: 6, color: NSColor(white: 0.35, alpha: 1), italic: true),
    ]

    static var defaultFamily: String { NSFont(name: "Helvetica Neue", size: 12) != nil ? "Helvetica Neue" : NSFont.systemFont(ofSize: 12).familyName ?? "Helvetica" }

    var font: NSFont {
        var font = NSFontManager.shared.font(withFamily: Self.defaultFamily, traits: [], weight: weight == .bold ? 9 : weight == .semibold ? 8 : 5, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacingAfter
        p.lineHeightMultiple = 1.15
        if italic { p.headIndent = 24; p.firstLineHeadIndent = 24 }
        return p
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraph, .foregroundColor: color]
    }
}
