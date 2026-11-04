import AppKit
import Kit42
import PDFKit

/// Last resort for pages whose content cannot be rewritten safely (unsupported fonts or images):
/// the page is rendered at 300 dpi with the areas filled, and becomes that picture plus an
/// invisible OCR text layer. Crop box, rotation and annotations are kept.
enum RedactionRaster {
    static let dpi: CGFloat = 300

    static func page(_ page: PDFPage, areas: [RedactionArea], overlay: (CGContext) -> Void) -> PDFPage? {
        let media = page.bounds(for: .mediaBox), crop = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let annotations = page.annotations
        annotations.forEach { page.removeAnnotation($0) }
        page.rotation = 0
        defer { page.rotation = rotation }
        let scale = dpi / 72
        let w = Int((media.width * scale).rounded()), h = Int((media.height * scale).rounded())
        guard w > 0, h > 0, w * h < 300_000_000,
              let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            annotations.forEach { page.addAnnotation($0) }
            return nil
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.interpolationQuality = .high
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -media.minX, y: -media.minY)
        bitmap.saveGState()
        page.draw(with: .mediaBox, to: bitmap)
        bitmap.restoreGState()
        for a in areas {
            bitmap.setFillColor(red: a.fill.r, green: a.fill.g, blue: a.fill.b, alpha: 1)
            bitmap.fill(a.rect)
        }
        overlay(bitmap)
        guard let image = bitmap.makeImage() else {
            annotations.forEach { page.addAnnotation($0) }
            return nil
        }
        // JPEG keeps a 300 dpi page at a sensible size; Quartz embeds it as is.
        let jpeg = NSMutableData()
        var picture = image
        if let dest = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: jpeg),
               let j = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) { picture = j }
        }
        let observations = EditorWindowController.recognizeText(in: image)
        let data = NSMutableData()
        var box = media
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            annotations.forEach { page.addAnnotation($0) }
            return nil
        }
        ctx.beginPDFPage(nil)
        ctx.draw(picture, in: media)
        EditorWindowController.drawInvisibleText(observations, box: media, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let newPage = PDFDocument(data: data as Data)?.page(at: 0) else {
            annotations.forEach { page.addAnnotation($0) }
            return nil
        }
        newPage.setBounds(crop, for: .cropBox)
        newPage.rotation = rotation
        annotations.forEach { newPage.addAnnotation($0) }
        return newPage
    }
}

extension EditorWindowController {
    /// Redaction marks waiting to be applied.
    var pendingRedactions: [(RedactOverlay, PDFPage)] {
        guard let pdf else { return [] }
        return (0..<pdf.pageCount).flatMap { i -> [(RedactOverlay, PDFPage)] in
            guard let page = pdf.page(at: i) else { return [] }
            return page.annotations.compactMap { $0 as? RedactOverlay }.map { ($0, page) }
        }
    }

    /// Markup › Apply Redactions: removes what is under every redaction mark now (after a warning).
    @objc func applyRedactionsAction(_ sender: Any?) {
        guard let pdf, let window else { return }
        let marks = pendingRedactions
        guard !marks.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("Nothing to redact")
            alert.informativeText = L("Mark areas with the Redact tool first.")
            alert.beginSheetModal(for: window)
            return
        }
        prepareForSave()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Apply %d redactions?", marks.count)
        alert.informativeText = L("Text, images and annotations under the marked areas will be removed from the document. Once the document is saved this cannot be undone: the removed content is not in the file anymore.")
        alert.addButton(withTitle: L("Apply Redactions"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            // Other overlays (edited text, watermarks) stay editable: move them onto the new pages.
            let others: [(PDFAnnotation, Int)] = (0..<pdf.pageCount).flatMap { i -> [(PDFAnnotation, Int)] in
                (pdf.page(at: i)?.annotations ?? []).filter { ($0 is PageOverlay && !($0 is RedactOverlay)) || $0 is TemporaryHighlight }.map { ($0, i) }
            }
            guard let result = PageOverlay.bake(pdf, only: { $0 is RedactOverlay }),
                  let redacted = PDFDocument(data: result.data) else {
                banner.show(.error, L("The redactions could not be applied."))
                return
            }
            for (overlay, i) in others {
                overlay.page?.removeAnnotation(overlay)
                redacted.page(at: i)?.addAnnotation(overlay)
            }
            replaceDocument(redacted)
            undo?.removeAllActions()
            pdfDoc?.updateChangeCount(.changeDone)
            showRedactionResult(result.report, applied: marks.count)
        }
    }

    func showRedactionResult(_ report: RedactionReport, applied: Int? = nil) {
        let glyphs = report.pages.reduce(0) { $0 + $1.glyphs }
        let images = report.pages.reduce(0) { $0 + $1.images }
        let raster = report.rasterizedPages
        var text = applied.map { L("Redactions applied: %d.", $0) } ?? L("Redacted content removed from the file.")
        text += " " + L("Characters removed: %d, images cleared: %d.", glyphs, images)
        if !raster.isEmpty {
            text += " " + L("Pages %@ could not be edited safely and were turned into images with recognized text.",
                            raster.map { "\($0 + 1)" }.joined(separator: ", "))
        }
        banner.show(raster.isEmpty ? .success : .warning, text)
    }
}
