import Kit42
import AppKit
import PDFKit
import UniformTypeIdentifiers

@objc(PDFDoc)
final class PDFDoc: NSDocument {
    var pdf: PDFDocument
    /// File bytes as read; needed to verify signatures and to add further signatures incrementally.
    private(set) var originalData: Data?
    private(set) var signatures: [SignatureInfo] = []

    override init() {
        pdf = PDFDocument()
        pdf.insert(PDFPage.blank(), at: 0)
        super.init()
    }

    convenience init(pdf: PDFDocument) {
        self.init()
        self.pdf = pdf
    }

    override class var autosavesInPlace: Bool { false }

    /// A4 page (portrait or landscape, following the image) with the image fitted inside.
    static func page(from image: NSImage) -> PDFPage? {
        let landscape = image.size.width > image.size.height
        let box = CGRect(x: 0, y: 0, width: landscape ? 842 : 595, height: landscape ? 595 : 842)
        return PDFPage(image: image, options: [.mediaBox: box, .upscaleIfSmaller: false, .compressionQuality: 0.85])
    }

    /// Text of all pages with fonts, a page break between pages (for Word/RTF export).
    static func attributedText(_ pdf: PDFDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for i in 0..<pdf.pageCount {
            guard let text = pdf.page(at: i)?.attributedString else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: "\u{000C}")) }
            out.append(text)
        }
        return out
    }

    /// Images are imported as PDF; saving always writes PDF.
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { "pdf" }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { ["com.adobe.pdf"] }

    var editor: EditorWindowController? {
        windowControllers.first as? EditorWindowController
    }

    override func makeWindowControllers() {
        let controller = EditorWindowController(pdf: pdf)
        addWindowController(controller)
        controller.documentDidLoad()
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if let type = UTType(typeName), type.conforms(to: .image), !type.conforms(to: .pdf) {
            guard let image = NSImage(data: data), let page = PDFDoc.page(from: image) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
            }
            pdf = PDFDocument()
            pdf.insert(page, at: 0)
            return
        }
        guard let doc = PDFDocument(data: data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        pdf = doc
        originalData = data
        signatures = PDFSignatureVerifier.verify(data)
    }

    override func data(ofType typeName: String) throws -> Data {
        editor?.prepareForSave()
        guard let data = pdf.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        return data
    }

    override func write(to url: URL, ofType typeName: String) throws {
        let data = try data(ofType: typeName)
        try data.write(to: url)
        originalData = data
        signatures = PDFSignatureVerifier.verify(data)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        editor?.replaceDocument(pdf)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        editor?.prepareForSave()
        guard let op = pdf.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
        return op
    }
}
