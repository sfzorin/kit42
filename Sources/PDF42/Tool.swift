import Kit42
import AppKit
import PDFKit

enum Tool: Int, CaseIterable {
    case select, highlight, underline, strikeOut, ink, rectangle, oval, whiteout, text, note

    var title: String {
        switch self {
        case .select: return L("Select and Highlight Text")
        case .highlight: return L("Highlight")
        case .underline: return L("Underline")
        case .strikeOut: return L("Strikethrough")
        case .ink: return L("Pencil")
        case .rectangle: return L("Rectangle")
        case .oval: return L("Oval")
        case .whiteout: return L("Whiteout")
        case .text: return L("Text Box")
        case .note: return L("Note")
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .ink: return "scribble"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .whiteout: return "eraser"
        case .text: return "character.textbox"
        case .note: return "note.text"
        }
    }

    var defaultColor: NSColor {
        switch self {
        case .highlight, .note: return .systemYellow
        case .underline: return .systemBlue
        case .text: return .black
        case .whiteout: return .white
        default: return .systemRed
        }
    }

    var isTextMarkup: Bool { self == .highlight || self == .underline || self == .strikeOut }
}

extension PDFAnnotation {
    /// Annotation subtype without the leading slash ("Highlight", "Ink", ...).
    var kind: String {
        (type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func isKind(_ subtype: PDFAnnotationSubtype) -> Bool {
        kind == subtype.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isMarkup: Bool { isKind(.highlight) || isKind(.underline) || isKind(.strikeOut) }

    /// Annotations PDFView should keep handling itself (form fields, links, popups).
    var isSystemHandled: Bool { isKind(.widget) || isKind(.link) || isKind(.popup) }

    var isResizable: Bool { isKind(.freeText) || isKind(.square) || isKind(.circle) || isKind(.stamp) }

    var keepsAspectRatio: Bool { isKind(.stamp) }
}

extension PDFPage {
    static func blank(size: CGSize = CGSize(width: 595, height: 842)) -> PDFPage {
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        return page
    }
}

/// Stamp annotation that draws a raster image (signatures, seals). PDFKit writes the drawing
/// into the annotation's appearance stream on save, so other viewers show it too.
final class ImageStampAnnotation: PDFAnnotation {
    let image: CGImage

    init(image: CGImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}
