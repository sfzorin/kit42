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
    /// Save the "Compare With…" highlights into the file (off: they are only shown).
    var keepCompareHighlights = false
    /// Outline edits, properties, page labels, initial view, attachments (written after PDFKit, see `DocumentWriter`).
    var extras = DocumentExtras()

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
        extras = DocumentExtras.read(data, pdf: doc)
        signatures = PDFSignatureVerifier.verify(data, attachments: extras.files)
    }

    override func data(ofType typeName: String) throws -> Data {
        editor?.prepareForSave()
        // Watermarks, page numbers and edited text become page content; new form fields get an /AcroForm entry.
        // Text and images under edited text, whiteout boxes and redaction marks are removed from the file.
        guard let baked = PageOverlay.bake(pdf, keepTemporary: keepCompareHighlights) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        let report = baked.report
        if report.pages.contains(where: { $0.glyphs > 0 || $0.images > 0 || $0.rasterized != nil }) {
            DispatchQueue.main.async { [weak self] in self?.editor?.showRedactionResult(report) }
        }
        return DocumentWriter.apply(AcroFormFixer.ensureFields(baked.data), extras: extras, pdf: pdf)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        let data = try data(ofType: typeName)
        try data.write(to: url)
        originalData = data
        signatures = PDFSignatureVerifier.verify(data, attachments: extras.files)
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
