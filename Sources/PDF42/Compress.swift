import AppKit
import Kit42
import PDFKit
import Quartz

/// Smaller PDFs the way Preview's "Reduce File Size" does it, with sane settings: pictures are
/// downsampled to a target resolution and re-encoded as JPEG through a Quartz filter; text and
/// vector graphics stay as they are (searchable, sharp). Never returns a file bigger than the original.
enum PDFCompressor {
    enum Level: Int, CaseIterable {
        case smallest, balanced, high

        var title: String {
            switch self {
            case .smallest: return L("Smallest (100 dpi)")
            case .balanced: return L("Balanced (150 dpi)")
            case .high: return L("High quality (220 dpi)")
            }
        }

        var dpi: Int { [100, 150, 220][rawValue] }
        var quality: Double { [0.5, 0.62, 0.78][rawValue] }
        static func named(_ s: String) -> Level? { ["smallest": .smallest, "balanced": .balanced, "high": .high][s.lowercased()] }
    }

    private static func filter(_ level: Level) -> QuartzFilter? {
        let plist: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": level.quality, "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageScaleFactor": 0.0, "ImageResolution": level.dpi, "ImageScaleInterpolate": true,
                                       "ImageSizeMax": 0, "ImageSizeMin": 0],
            ]]],
            "FilterType": 1, "Name": "PDF42 \(level.dpi) dpi",
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PDF42-\(level.dpi).qfilter")
        guard (plist as NSDictionary).write(to: url, atomically: true) else { return nil }
        return QuartzFilter(url: url)
    }

    /// Compressed PDF data, or nil when it would not be smaller than `original`.
    static func compress(_ doc: PDFDocument, level: Level, original: Int) -> Data? {
        guard let filter = filter(level) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("PDF42-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        guard doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]),
              let raw = try? Data(contentsOf: out), !raw.isEmpty else { return nil }
        let data = AcroFormFixer.ensureFields(raw)   // form fields stay fillable elsewhere, as when saving
        return data.count < original ? data : nil
    }

    static func sizeText(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

extension EditorWindowController {
    /// Size of the document as it is now: the file on disk if unchanged, else what saving would write.
    private var currentDocumentSize: Int {
        if let doc = pdfDoc, !doc.isDocumentEdited, let url = doc.fileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { return size }
        return pdf?.dataRepresentation()?.count ?? 0
    }

    @objc func reduceSizeAction(_ sender: Any?) {
        guard let pdf, let window else { return }
        prepareForSave()
        let original = currentDocumentSize
        // Watermarks, page numbers and edited text are drawn into the pages first, as when saving.
        let baked = PageOverlay.bakedDocument(pdf)
        let snapshot = baked.dataRepresentation().flatMap(PDFDocument.init(data:)) ?? baked

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 26), pullsDown: false)
        popup.addItems(withTitles: PDFCompressor.Level.allCases.map(\.title))
        popup.selectItem(at: PDFCompressor.Level.balanced.rawValue)
        let alert = NSAlert()
        alert.messageText = L("Reduce File Size")
        var info = L("Now: %@. Pictures are made smaller; text stays sharp and searchable.", PDFCompressor.sizeText(original))
        if pdf.dataRepresentation().map({ $0.range(of: Data("/ByteRange".utf8)) != nil }) == true {
            info += "\n" + L("The digital signature will be removed from the compressed file.")
        }
        alert.informativeText = info
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Save Copy…"))
        alert.addButton(withTitle: L("Compress This Document"))
        alert.addButton(withTitle: L("Cancel"))

        // Estimate every level in the background and show the result next to it.
        var results: [PDFCompressor.Level: Data?] = [:]   // touched only on `queue`
        let queue = DispatchQueue(label: "pdf42.compress", qos: .userInitiated)
        for level in PDFCompressor.Level.allCases {
            popup.item(at: level.rawValue)?.title = level.title + " — " + L("estimating…")
            queue.async {
                let data = PDFCompressor.compress(snapshot, level: level, original: original)
                results[level] = data
                DispatchQueue.main.async {
                    let text: String
                    if let data {
                        let saved = 100 - Int((Double(data.count) / Double(max(1, original)) * 100).rounded())
                        text = "\(PDFCompressor.sizeText(data.count)) (−\(saved)%)"
                    } else {
                        text = L("no gain")
                    }
                    popup.item(at: level.rawValue)?.title = level.title + " — " + text
                }
            }
        }

        alert.beginSheetModal(for: window) { [self] response in
            guard response != .alertThirdButtonReturn, let level = PDFCompressor.Level(rawValue: popup.indexOfSelectedItem) else { return }
            // Waits for the chosen level if it is still being estimated.
            let ready = queue.sync { results[level] }
            guard let data = ready ?? nil else {
                let a = NSAlert()
                a.messageText = L("The file is already compact")
                a.informativeText = L("Compression would not make it smaller. Try a lower quality level.")
                a.beginSheetModal(for: window)
                return
            }
            let summary = L("%@ → %@", PDFCompressor.sizeText(original), PDFCompressor.sizeText(data.count))
            if response == .alertSecondButtonReturn {
                guard let compressed = PDFDocument(data: data) else { return }
                replaceDocument(compressed)
                pdfDoc?.updateChangeCount(.changeDone)
                banner.show(.success, L("Compressed: %@. Save to keep the change.", summary))
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            let base = pdfDoc?.fileURL?.deletingPathExtension().lastPathComponent ?? pdfDoc?.displayName ?? L("Document")
            panel.nameFieldStringValue = L("%@ (compressed).pdf", base)
            panel.beginSheetModal(for: window) { r in
                guard r == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url)
                    self.banner.show(.success, L("Saved: %@", summary))
                } catch { self.presentError(error) }
            }
        }
    }
}
