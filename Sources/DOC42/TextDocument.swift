import AppKit
import Kit42

@objc(TextDocument)
final class TextDocument: NSDocument {
    let storage = NSTextStorage()

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

    override func read(from data: Data, ofType typeName: String) throws {
        if Self.isMarkdown(typeName) {
            let md = String(decoding: data, as: UTF8.self)
            let parsed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .full))) ?? AttributedString(md)
            storage.setAttributedString(MarkdownStyler.style(NSAttributedString(parsed)))
            return
        }
        let type = Self.documentType(for: typeName)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .plain { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        let source = type == .officeOpenXML ? DocxStyles.flatten(data) : data
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(data: source, options: options, documentAttributes: nil))
        if type == .officeOpenXML || type == .docFormat || type == .openDocument { ListMarkers.insert(into: text) }
        storage.setAttributedString(type == .plain ? NSAttributedString(string: text.string, attributes: Styles.normal.attributes) : text)
    }

    override func data(ofType typeName: String) throws -> Data {
        editor?.textView.breakUndoCoalescing()
        if Self.isMarkdown(typeName) { return Data(storage.string.utf8) }
        return try exportData(Self.documentType(for: typeName))
    }

    func exportData(_ type: NSAttributedString.DocumentType) throws -> Data {
        let range = NSRange(location: 0, length: storage.length)
        if type == .plain { return Data(storage.string.utf8) }
        if type == .officeOpenXML { return DocxWriter.data(storage, pageSize: printInfo.paperSize) }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        return try storage.data(from: range, documentAttributes: attrs)
    }

    /// Paginated PDF of the document (A4/Letter from page setup).
    func pdfData() -> Data {
        PaginatedPDF.render(printView(), info: pagedPrintInfo())
    }

    private func pagedPrintInfo() -> NSPrintInfo {
        let info = printInfo.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.leftMargin = 64; info.rightMargin = 64; info.topMargin = 64; info.bottomMargin = 64
        return info
    }

    private func printView() -> NSTextView {
        let info = pagedPrintInfo()
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(storage)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.backgroundColor = .white
        view.sizeToFit()
        return view
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let op = NSPrintOperation(view: printView(), printInfo: pagedPrintInfo())
        op.jobTitle = displayName
        return op
    }
}

/// Gives Markdown's semantic runs (headings, code, quotes) a document look.
enum MarkdownStyler {
    static func style(_ source: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lastIdentity: Int?
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            let intent = attrs[NSAttributedString.Key("NSPresentationIntent")] as? PresentationIntent
            let inline = attrs[NSAttributedString.Key("NSInlinePresentationIntent")] as? NSNumber
            var style = Styles.normal
            var isCode = false
            var isList = false
            for component in intent?.components ?? [] {
                switch component.kind {
                case .header(let level): style = Styles.all[min(3, max(1, level))]
                case .blockQuote: style = Styles.all[5]
                case .codeBlock: isCode = true
                case .listItem: isList = true
                default: break
                }
            }
            // A new block starts a new paragraph.
            if let id = intent?.components.first?.identity, id != lastIdentity, out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: style.attributes))
            }
            lastIdentity = intent?.components.first?.identity
            var a = style.attributes
            var font = a[.font] as! NSFont
            if let inline {
                let v = inline.uintValue
                if v & 2 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }   // stronglyEmphasized
                if v & 1 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) } // emphasized
                if v & 4 != 0 { isCode = true }                                                           // code
                if v & 32 != 0 { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if isCode { font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular); a[.backgroundColor] = NSColor(white: 0.95, alpha: 1) }
            a[.font] = font
            if let link = attrs[.link] { a[.link] = link }
            var text = source.attributedSubstring(from: range).string
            if isList, out.string.hasSuffix("\n") || out.length == 0 { text = "\t•\t" + text }
            out.append(NSAttributedString(string: text, attributes: a))
        }
        return out
    }
}

/// Paragraph styles offered in DOC42 (look only; saved as direct formatting).
struct Styles {
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
