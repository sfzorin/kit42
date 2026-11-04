import AppKit
import Kit42
import UniformTypeIdentifiers

extension ImageWindowController {
    // MARK: - Save

    @objc(saveDocument:) func saveDocument(_ sender: Any?) { save(confirmed: false) }

    @objc(saveDocumentAs:) func saveDocumentAs(_ sender: Any?) { runExportPanel(saveAs: true) }

    @objc(revertDocumentToSaved:) func revertDocumentToSaved(_ sender: Any?) {
        guard isDirty else { return }
        registerUndo(state, L("Revert to Saved"))
        restore(EditState(base: originalBase, marks: [], adjustments: Adjustments(), imageDescription: originalDescription))
    }

    /// Saves over the original (same format, metadata kept). Formats that cannot be written go to Save As.
    func save(confirmed: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let url, let l = loaded, isDirty, let window else { completion?(true); return }
        canvas.markup.endTextEditing()
        if onlyDescriptionChanged, Orientation.writeDescription(imageDescription, to: url) {
            didSave(url)
            completion?(true)
            return
        }
        let type = l.typeIdentifier
        guard ImageWriter.canWrite(type), l.pageCount == 1, !l.isAnimated, let image = finalImage() else {
            runExportPanel(saveAs: true, completion: completion)
            return
        }
        // Transparency would turn white in a JPEG: offer a PNG copy instead.
        let lostAlpha = base !== originalBase && image.alphaInfo != .none && !(loaded?.hasAlpha ?? false)
            && (UTType(type ?? "")?.conforms(to: .jpeg) ?? false)
        if lostAlpha { runExportPanel(saveAs: true, preferred: .png, completion: completion); return }

        let write = { [weak self] in
            guard let self else { return }
            do {
                try ImageWriter.write(image, to: url, type: type!, quality: 0.92, metadataFrom: url, description: .some(self.imageDescription))
                self.didSave(url)
                completion?(true)
            } catch {
                self.showError(error)
                completion?(false)
            }
        }
        if confirmed || confirmedOverwrite { write(); return }
        let alert = NSAlert()
        alert.messageText = L("Save changes to “%@”?", url.lastPathComponent)
        alert.informativeText = L("The original file will be replaced with the edited image. You can save a copy instead.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Save As Copy…"))
        alert.beginSheetModal(for: window) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn:
                self?.confirmedOverwrite = true
                write()
            case .alertThirdButtonReturn: self?.runExportPanel(saveAs: true, completion: completion)
            default: completion?(false)
            }
        }
    }

    func didSave(_ url: URL) {
        invalidateCache(url)
        ImageLoader.thumbnailCache.removeObject(forKey: url as NSURL)
        display(ImageLoader.load(url, page: page))
        banner.show(.success, L("Saved"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.banner.hide() }
    }

    func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - Export / Save As

    @objc func exportAction(_ sender: Any?) { runExportPanel(saveAs: false) }

    func runExportPanel(saveAs: Bool, preferred: UTType? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let window, let image = finalImage() else { completion?(false); return }
        canvas.markup.endTextEditing()
        let panel = NSSavePanel()
        let options = ExportOptions(sourceType: preferred ?? loaded?.typeIdentifier.flatMap(UTType.init), hasAlpha: image.alphaInfo != .none, panel: panel)
        panel.accessoryView = options.view
        panel.title = saveAs ? L("Save As") : L("Export")
        panel.prompt = saveAs ? L("Save") : L("Export")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let url {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + (saveAs ? " " + L("copy") : "") + "." + options.fileExtension
        }
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let dest = panel.url else { completion?(false); return }
            do {
                let out = options.resized(image)
                try ImageWriter.write(out, to: dest, type: options.type.identifier, quality: options.quality, metadataFrom: self.url,
                                      description: .some(self.imageDescription))
                if dest.deletingLastPathComponent().standardizedFileURL == self.url?.deletingLastPathComponent().standardizedFileURL,
                   !self.urls.contains(dest) {
                    if saveAs {
                        self.resetEditing(base: self.originalBase)
                        self.insertIntoSet(dest)
                    } else {
                        let keep = self.index
                        self.insertIntoSetKeepingCurrent(dest, current: keep)
                    }
                } else if saveAs {
                    self.resetEditing(base: self.originalBase)
                    self.refreshDisplay()
                }
                completion?(true)
            } catch {
                self.showError(error)
                completion?(false)
            }
        }
    }

    func insertIntoSetKeepingCurrent(_ new: URL, current: Int) {
        guard let cur = url else { return }
        var list = urls
        list.append(new)
        let sorted = sortOrder.sort(list)
        // Replace without reloading the current image (its edits stay).
        setURLsKeepingCurrent(sorted, current: cur)
    }

    // MARK: - Trash

    @objc func trashAction(_ sender: Any?) {
        guard let url else { return }
        confirmLeavingForTrash { [weak self] ok in
            guard ok, let self else { return }
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
                self.showError(error)
                return
            }
            self.removeFromSet(url)
            if let trashed = resulting as URL? {
                self.undo.registerUndo(withTarget: self.fileUndo) { [weak self] _ in self?.putBack(trashed, to: url) }
                self.undo.setActionName(L("Move to Trash"))
            }
        }
    }

    private func confirmLeavingForTrash(_ done: @escaping (Bool) -> Void) {
        guard isDirty else { done(true); return }
        confirmLeaving(done)
    }

    func putBack(_ trashed: URL, to original: URL) {
        do {
            try FileManager.default.moveItem(at: trashed, to: original)
        } catch {
            showError(error)
            return
        }
        insertIntoSet(original)
        undo.registerUndo(withTarget: fileUndo) { [weak self] _ in
            guard let self, self.url == original else { return }
            self.trashAction(nil)
        }
        undo.setActionName(L("Move to Trash"))
    }

    // MARK: - Finder, Copy, Share, Print

    @objc func showInFinderAction(_ sender: Any?) {
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func copy(_ sender: Any?) {
        guard let image = finalImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let sel = canvas.markup.pixelSelection, let part = PixelOps.extract(sel, from: image) {
            pb.writeObjects([NSImage(cgImage: part, size: .zero)])
            return
        }
        let ns = NSImage(cgImage: image, size: .zero)
        if !isDirty, let url { pb.writeObjects([url as NSURL, ns]) } else { pb.writeObjects([ns]) }
    }

    func shareItems() -> [Any] {
        guard let url else { return [] }
        if isDirty, let image = finalImage() { return [NSImage(cgImage: image, size: .zero)] }
        return [url]
    }

    @objc(printDocument:) func printDocument(_ sender: Any?) {
        guard let image = finalImage(), let window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.orientation = image.width > image.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let page = NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
                          height: info.paperSize.height - info.topMargin - info.bottomMargin)
        let view = NSImageView(frame: NSRect(origin: .zero, size: page))
        view.image = NSImage(cgImage: image, size: .zero)
        view.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = url?.lastPathComponent ?? "IMG42"
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc(runPageLayout:) func runPageLayout(_ sender: Any?) {
        guard let window else { return }
        NSPageLayout().beginSheet(with: NSPrintInfo.shared, modalFor: window, delegate: nil, didEnd: nil, contextInfo: nil)
    }

    // MARK: - Live Text

    /// Recognises text once per shown image (background), then calls `done`.
    func withRecognizedText(_ done: @escaping ([PixelOps.TextLine]) -> Void) {
        guard let image = displayed ?? base else { done([]); return }
        if let lines = textLines, textLinesFor === image { done(lines); return }
        window?.subtitle = L("Recognising text…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lines = PixelOps.recognizeText(image)
            DispatchQueue.main.async {
                guard let self else { return }
                self.textLines = lines
                self.textLinesFor = image
                self.updateSubtitle()
                done(lines)
            }
        }
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        let isEnter = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 36
        if isEnter, !canvas.markup.searchBoxes.isEmpty {
            searchIndex = (searchIndex + 1) % canvas.markup.searchBoxes.count
            canvas.markup.currentSearchBox = searchIndex
            reveal(canvas.markup.searchBoxes[searchIndex])
            return
        }
        runSearch(sender.stringValue)
    }

    func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let image = base else {
            canvas.markup.searchBoxes = []
            banner.hide()
            return
        }
        withRecognizedText { [weak self] lines in
            guard let self else { return }
            let boxes = PixelOps.find(q, in: lines, size: CGSize(width: image.width, height: image.height))
            self.canvas.markup.searchBoxes = boxes
            self.searchIndex = boxes.isEmpty ? -1 : 0
            self.canvas.markup.currentSearchBox = self.searchIndex
            if let first = boxes.first { self.reveal(first) }
            if lines.isEmpty {
                self.banner.show(.info, L("No text found in this image"))
            } else {
                self.banner.show(boxes.isEmpty ? .warning : .info, boxes.isEmpty ? L("“%@” not found", q) : L("Matches for “%@”: %d", q, boxes.count))
            }
        }
    }

    private func reveal(_ box: CGRect) {
        guard !canvas.imageFits else { return }
        canvas.markup.scrollToVisible(box.insetBy(dx: -box.width, dy: -box.height * 3))
    }

    @objc func copyTextAction(_ sender: Any?) {
        withRecognizedText { [weak self] lines in
            guard let self else { return }
            guard !lines.isEmpty else { self.banner.show(.info, L("No text found in this image")); return }
            let text = lines.map(\.text).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.banner.show(.success, L("Copied %d lines of text", lines.count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.banner.hide() }
        }
    }
}

/// Format, quality and size controls for the export / Save As panel.
final class ExportOptions: NSObject {
    let view: NSView
    private let formatPopup = NSPopUpButton()
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: L("Quality:"))
    private let qualityValue = NSTextField(labelWithString: "")
    private let sizePopup = NSPopUpButton()
    private weak var panel: NSSavePanel?
    let types: [UTType]

    static let sizes: [(String, CGFloat?, CGFloat?)] = [
        (L("Original Size"), nil, nil), ("75 %", 0.75, nil), ("50 %", 0.5, nil), ("25 %", 0.25, nil),
        (L("Fit in %d px", 3840), nil, 3840), (L("Fit in %d px", 2048), nil, 2048), (L("Fit in %d px", 1024), nil, 1024),
    ]

    init(sourceType: UTType?, hasAlpha: Bool, panel: NSSavePanel) {
        self.panel = panel
        var list: [UTType] = [.png, .jpeg, .heic, .tiff]
        if let avif = UTType("public.avif"), ImageWriter.writableTypes.contains(avif) { list.append(avif) }
        if let s = sourceType, ImageWriter.canWrite(s.identifier), !list.contains(s) { list.append(s) }
        types = list
        for t in list { formatPopup.addItem(withTitle: t.preferredFilenameExtension?.uppercased() ?? t.identifier) }
        var start = sourceType.flatMap { s in list.firstIndex { s.conforms(to: $0) } } ?? 0
        if hasAlpha, list[start] == .jpeg { start = 0 }
        formatPopup.selectItem(at: start)
        for s in Self.sizes { sizePopup.addItem(withTitle: s.0) }
        qualitySlider.doubleValue = 0.9
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Format:")), formatPopup],
            [qualityLabel, NSStackView(views: [qualitySlider, qualityValue])],
            [NSTextField(labelWithString: L("Size:")), sizePopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qualityValue.translatesAutoresizingMaskIntoConstraints = false
        qualityValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let box = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 20),
        ])
        view = box
        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        formatChanged()
        qualityChanged()
    }

    var type: UTType { types[max(0, formatPopup.indexOfSelectedItem)] }
    var fileExtension: String { type.preferredFilenameExtension ?? "png" }
    var quality: Double { qualitySlider.doubleValue }

    @objc private func formatChanged() {
        let lossy = type.conforms(to: .jpeg) || type == .heic || type.identifier == "public.avif"
        qualityLabel.isHidden = !lossy
        qualitySlider.isHidden = !lossy
        qualityValue.isHidden = !lossy
        panel?.allowedContentTypes = [type]
        if let panel {
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            if !name.isEmpty { panel.nameFieldStringValue = name + "." + fileExtension }
        }
    }

    @objc private func qualityChanged() {
        qualityValue.stringValue = "\(Int((quality * 100).rounded())) %"
    }

    func resized(_ image: CGImage) -> CGImage {
        let s = Self.sizes[max(0, sizePopup.indexOfSelectedItem)]
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var k: CGFloat = 1
        if let f = s.1 { k = f }
        if let m = s.2 { k = min(1, m / max(w, h)) }
        guard k < 1 else { return image }
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        return ImageLoader.render(size: size, colorSpace: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
        } ?? image
    }
}
