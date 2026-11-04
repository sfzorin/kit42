import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Continuity Camera and file import: what comes from an iPhone ("Take Photo" gives an image,
/// "Scan Documents" a PDF already cropped by the phone) or from Finder becomes raw pages.
enum ContinuityImport {
    static let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)]
    static let returnTypes: [NSPasteboard.PasteboardType] = [.pdf] + imageTypes

    static func accepts(_ type: NSPasteboard.PasteboardType) -> Bool {
        returnTypes.contains(type) || (UTType(type.rawValue)?.conforms(to: .image) ?? false)
    }

    struct Imported {
        var pages: [RawScan]
        /// A PDF from "Scan Documents": the phone already cropped and straightened it.
        var isDocumentScan: Bool
    }

    static func read(_ pboard: NSPasteboard) -> Imported? {
        if let data = pboard.data(forType: .pdf), let doc = PDFDocument(data: data) {
            return Imported(pages: rasterize(doc), isDocumentScan: true)
        }
        for type in imageTypes + (pboard.types ?? []) where accepts(type) {
            if let data = pboard.data(forType: type), let raw = image(data) { return Imported(pages: [raw], isDocumentScan: false) }
        }
        return nil
    }

    static func image(_ data: Data) -> RawScan? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Phone photos carry an EXIF orientation: apply it.
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 6000]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 72.5 ? $0 : nil } ?? estimatedDPI(image)
        return RawScan(image: image, dpi: dpi)
    }

    /// Photos have no real resolution: assume the long side is an A4 page's height.
    static func estimatedDPI(_ image: CGImage) -> Double {
        max(72, min(600, Double(max(image.width, image.height)) / 11.69))
    }

    static func rasterize(_ doc: PDFDocument, dpi: Double = 250) -> [RawScan] {
        (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            let box = page.bounds(for: .mediaBox)
            let size = CGSize(width: box.width * dpi / 72, height: box.height * dpi / 72)
            let ns = page.thumbnail(of: size, for: .mediaBox)
            var r = CGRect(origin: .zero, size: ns.size)
            guard let cg = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
            return RawScan(image: cg, dpi: Double(cg.width) / (box.width / 72))
        }
    }

    /// Images and PDF pages from files (File › Import, drops).
    static func load(_ urls: [URL]) -> [(RawScan, Bool)] {
        var out: [(RawScan, Bool)] = []
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true, let doc = PDFDocument(url: url) {
                out += rasterize(doc).map { ($0, true) }
            } else if let data = try? Data(contentsOf: url), let raw = image(data) {
                out.append((raw, false))
            }
        }
        return out
    }
}
