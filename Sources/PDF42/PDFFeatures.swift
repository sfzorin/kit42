import AppKit
import CoreText
import Kit42
import PDFKit
import Vision

extension EditorWindowController {
    // MARK: - OCR

    /// Recognises text on the selected pages (or all) and adds an invisible, searchable text layer.
    @objc func recognizeTextAction(_ sender: Any?) {
        guard let pdf, let window else { return }
        let selected = sidebar.thumbnails.selectedPages
        let pages = selected.count > 1 ? selected : (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        let alert = NSAlert()
        alert.messageText = L("Recognize Text")
        alert.informativeText = L("Scanned pages get an invisible text layer: the text can then be searched, selected and copied. Pages: %d.", pages.count)
        alert.addButton(withTitle: L("Recognize"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        banner.show(.info, L("Recognizing text…"))
        let items = pages.map { (page: $0, index: pdf.index(for: $0)) }
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(Int, PDFPage)] = []
            for (n, item) in items.enumerated() {
                if let page = Self.ocrPage(item.page) { results.append((item.index, page)) }
                DispatchQueue.main.async { self.banner.show(.info, L("Recognizing text… %d of %d", n + 1, items.count)) }
            }
            DispatchQueue.main.async {
                self.replacePages(results, name: L("Recognize Text"))
                self.banner.show(.success, L("Text recognized on %d pages", results.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.updateSignatureBanner() }
                _ = window
            }
        }
    }

    /// New page = original content + invisible text from Vision; annotations are moved over.
    static func ocrPage(_ page: PDFPage) -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        let rotation = page.rotation
        let annotations = page.annotations
        page.rotation = 0
        annotations.forEach { page.removeAnnotation($0) }
        defer {
            page.rotation = rotation
            annotations.forEach { page.addAnnotation($0) }
        }
        let scale: CGFloat = 2.5
        let thumb = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: thumb.size)
        guard let cg = thumb.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }

        let observations = recognizeText(in: cg)
        guard !observations.isEmpty else { return nil }

        let data = NSMutableData()
        var media = box
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)
        drawInvisibleText(observations, box: box, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let newPage = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        newPage.rotation = rotation
        for a in annotations { newPage.addAnnotation(a.copy() as! PDFAnnotation) }
        return newPage
    }

    /// Text lines found by Vision in a page image.
    static func recognizeText(in image: CGImage) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US", "tr-TR"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return [] }
        return request.results ?? []
    }

    /// Invisible (searchable, selectable) text over the recognised lines; `box` is the page area the image covers.
    static func drawInvisibleText(_ observations: [VNRecognizedTextObservation], box: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for o in observations {
            guard let text = o.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let b = o.boundingBox
            let r = CGRect(x: box.minX + b.minX * box.width, y: box.minY + b.minY * box.height, width: b.width * box.width, height: b.height * box.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, r.height * 0.8), nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.18)
            if width > 0 { ctx.scaleBy(x: r.width / width, y: 1) }
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Swaps pages (undoable).
    func replacePages(_ replacements: [(Int, PDFPage)], name: String) {
        guard let pdf, !replacements.isEmpty else { return }
        pdfView.selectAnnotation(nil)
        var old: [(Int, PDFPage)] = []
        for (i, page) in replacements where i < pdf.pageCount {
            if let previous = pdf.page(at: i) { old.append((i, previous)) }
            pdf.removePage(at: i)
            pdf.insert(page, at: i)
        }
        pdfView.layoutDocumentView()
        sidebar.thumbnails.reload()
        undo?.registerUndo(withTarget: self) { $0.replacePages(old, name: name) }
        undo?.setActionName(name)
    }

    // MARK: - Print selected pages

    @objc func printSelectedPagesAction(_ sender: Any?) {
        guard let pdf, let window else { return }
        prepareForSave()
        let indices = sidebar.thumbnails.selectedPages.map { pdf.index(for: $0) }.filter { $0 != NSNotFound }
        let chosen = indices.isEmpty ? [pdf.index(for: pdfView.currentPage ?? pdf.page(at: 0)!)] : indices.sorted()
        let part = PDFDocument()
        let source = PageOverlay.bakedDocument(pdf)
        for i in chosen { if let p = source.page(at: i)?.copy() as? PDFPage { part.insert(p, at: part.pageCount) } }
        guard let op = part.printOperation(for: pdfDoc?.printInfo ?? .shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
        op.jobTitle = pdfDoc?.displayName ?? "PDF42"
        op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview, .showsCopies])
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
