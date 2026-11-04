import AppKit
import Kit42
import PDFKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let pdfView = EditorPDFView()
    private lazy var sidebar = SidebarViewController(pdfView: pdfView)
    private let splitController = NSSplitViewController()
    private let banner = BannerView()
    private let toolbarController = ToolbarController(identifier: "PDF42.toolbar", elements: Cmd.toolbar)
    private let colorButton = ColorButton(symbol: "paintpalette", toolTip: L("Colour of the tool or selected annotation"),
                                          color: .systemRed, allowsNone: false)
    private lazy var widthButton = StripButton(symbol: "lineweight", toolTip: L("Line width"), menu: widthMenu)
    private lazy var widthMenu: NSMenu = {
        let menu = NSMenu()
        for (i, w) in widths.enumerated() {
            let item = NSMenuItem(title: "\(Int(w)) pt", action: #selector(widthChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == 1 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }()
    private lazy var markupStrip = ToolStrip([
        .group([.tool(Cmd.tool(.select))]),
        .tools([Cmd.tool(.highlight), Cmd.tool(.underline), Cmd.tool(.strikeOut)]),
        .tools([Cmd.tool(.ink), Cmd.tool(.rectangle), Cmd.tool(.oval), Cmd.tool(.whiteout)]),
        .group([.tool(Cmd.tool(.text)), .tool(Cmd.tool(.note)), .command(Cmd.replaceText)]),
        .group([.view(colorButton), .view(widthButton)]),
        .buttons([Cmd.stamps]),
    ])

    private var colors: [Tool: NSColor] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, $0.defaultColor) })
    private let widths: [CGFloat] = [1, 2, 3, 5, 8, 12]
    private var fontSize: CGFloat = 14
    private var warnedSignedEdit = false

    private var searchResults: [PDFSelection] = []
    private var searchIndex = -1
    private var lastSearch = ""

    var pdf: PDFDocument? { pdfView.document }
    var pdfDoc: PDFDoc? { document as? PDFDoc }
    var undo: UndoManager? { pdfDoc?.undoManager }

    init(pdf: PDFDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        setupContent()
        window.toolbar = toolbarController.toolbar
        markupStrip.isShown = false
        window.addTitlebarAccessoryViewController(markupStrip)
        window.setContentSize(NSSize(width: 1180, height: 840))
        window.center()

        pdfView.document = pdf
        setTool(.select)
        updateSubtitle()

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupContent() {
        pdfView.editor = self
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .underPageBackgroundColor

        let content = NSViewController()
        let container = NSView()
        let stack = NSStackView(views: [banner, pdfView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pdfView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        content.view = container

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: content)
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)
        splitController.splitView.autosaveName = "PDF42.split"
        window?.contentViewController = splitController

        colorButton.target = self
        colorButton.action = #selector(colorChanged(_:))
    }

    // MARK: - Document lifecycle

    func documentDidLoad() {
        DispatchQueue.main.async { [self] in
            unlockIfNeeded()
            updateSignatureBanner()
            if let undo {
                NotificationCenter.default.addObserver(self, selector: #selector(didEdit), name: .NSUndoManagerDidCloseUndoGroup, object: undo)
            }
        }
    }

    func replaceDocument(_ pdf: PDFDocument) {
        pdfView.selectAnnotation(nil)
        pdfView.document = pdf
        sidebar.reloadOutline()
        resetSearch()
        updateSubtitle()
        warnedSignedEdit = false
        updateSignatureBanner()
    }

    func prepareForSave() {
        pdfView.selectAnnotation(nil)
        window?.makeFirstResponder(pdfView)
    }

    func unlockIfNeeded() {
        guard let pdf, pdf.isLocked else { return }
        while pdf.isLocked {
            let field = NSSecureTextField()
            let alert = NSAlert.form(L("The document is password-protected"), info: L("Enter the password to open “%@”.", window?.title ?? ""),
                                     ok: L("Open"), rows: [(L("Password:"), field)])
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else {
                pdfDoc?.close()
                return
            }
            pdf.unlock(withPassword: field.stringValue)
        }
        pdfView.layoutDocumentView()
        sidebar.reloadOutline()
        updateSubtitle()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    @objc private func pageChanged(_ note: Notification) { updateSubtitle() }

    private func updateSubtitle() {
        guard let pdf, let page = pdfView.currentPage else {
            window?.subtitle = ""
            return
        }
        var text = L("Page %d of %d", pdf.index(for: page) + 1, pdf.pageCount)
        if !lastSearch.isEmpty {
            text += searchResults.isEmpty ? L(" · not found") : L(" · %d of %d", searchIndex + 1, searchResults.count)
        }
        window?.subtitle = text
    }

    private func updateSignatureBanner() {
        guard let signatures = pdfDoc?.signatures, !signatures.isEmpty else {
            banner.hide()
            return
        }
        let names = Array(Set(signatures.map(\.signer))).sorted().joined(separator: ", ")
        let details = L("Details")
        if signatures.contains(where: { $0.status == .invalid }) {
            banner.show(.error, L("Signature invalid — the document was changed after signing (%@)", names), action: details, handler: showSignatures)
        } else if signatures.contains(where: { $0.status == .untrusted }) {
            banner.show(.warning, L("Signed by %@. The signature is intact, but the certificate is not confirmed by a certification authority", names), action: details, handler: showSignatures)
        } else if signatures.last?.coversWholeFile == false {
            banner.show(.info, L("Signed by %@. The document was extended after signing", names), action: details, handler: showSignatures)
        } else {
            banner.show(.success, L("Signed by %@ · all signatures are valid", names), action: details, handler: showSignatures)
        }
    }

    @objc private func didEdit(_ note: Notification) {
        guard !warnedSignedEdit, pdfDoc?.signatures.isEmpty == false else { return }
        warnedSignedEdit = true
        banner.show(.warning, L("The document is signed: saving changes will invalidate the signatures. Use “Save As…”"),
                    action: L("Details"), handler: showSignatures)
    }

    private func showSignatures() {
        SignDialog.showResults(pdfDoc?.signatures ?? [], window: window)
    }

    // MARK: - Tools

    func setTool(_ tool: Tool) {
        pdfView.tool = tool
        markupStrip.select(tag: tool.rawValue)
        colorButton.color = colors[tool] ?? tool.defaultColor
        colorButton.isEnabled = tool != .whiteout
        pdfView.color = colorButton.color ?? tool.defaultColor
        if tool != .select, !markupStrip.isShown { markupStrip.isShown = true }
    }

    @objc func selectToolAction(_ sender: Any?) {
        setTool(Tool(rawValue: commandTag(of: sender)) ?? .select)
    }

    @objc func toggleMarkupAction(_ sender: Any?) {
        markupStrip.isShown.toggle()
        if !markupStrip.isShown { setTool(.select) }
    }

    @objc private func colorChanged(_ sender: ColorButton) {
        let color = sender.color ?? .black
        if let annotation = pdfView.selectedAnnotation, let page = pdfView.selectedPage {
            recolor(annotation, to: color, on: page)
            return
        }
        colors[pdfView.tool] = color
        pdfView.color = color
    }

    @objc private func widthChosen(_ sender: NSMenuItem) {
        pdfView.lineWidth = widths[max(0, sender.tag)]
        widthMenu.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    private var currentColor: NSColor { colors[pdfView.tool] ?? pdfView.tool.defaultColor }

    // MARK: - Annotation editing (undoable)

    private func stamp(_ annotation: PDFAnnotation) {
        annotation.userName = NSFullUserName()
        annotation.modificationDate = Date()
    }

    func add(_ annotation: PDFAnnotation, to page: PDFPage, name: String) {
        page.addAnnotation(annotation)
        pdfView.annotationsChanged(on: page)
        undo?.registerUndo(withTarget: self) { $0.remove(annotation, from: page, name: name) }
        undo?.setActionName(name)
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage, name: String) {
        if pdfView.selectedAnnotation === annotation { pdfView.selectAnnotation(nil) }
        if let popup = annotation.popup { page.removeAnnotation(popup) }
        page.removeAnnotation(annotation)
        pdfView.annotationsChanged(on: page)
        undo?.registerUndo(withTarget: self) { $0.add(annotation, to: page, name: name) }
        undo?.setActionName(name)
    }

    func didChangeBounds(_ annotation: PDFAnnotation, from original: CGRect, on page: PDFPage, name: String) {
        let changed = annotation.bounds
        annotation.bounds = original
        setBounds(annotation, changed, on: page, name: name)
    }

    private func setBounds(_ annotation: PDFAnnotation, _ rect: CGRect, on page: PDFPage, name: String) {
        let old = annotation.bounds
        annotation.bounds = rect
        pdfView.annotationsChanged(on: page)
        pdfView.refreshMarker()
        undo?.registerUndo(withTarget: self) { $0.setBounds(annotation, old, on: page, name: name) }
        undo?.setActionName(name)
    }

    private func recolor(_ annotation: PDFAnnotation, to color: NSColor, on page: PDFPage) {
        let isText = annotation.isKind(.freeText)
        let old = (isText ? annotation.fontColor : annotation.color) ?? .black
        let newColor = annotation.isKind(.highlight) ? color.withAlphaComponent(0.45) : color
        if isText { annotation.fontColor = newColor } else { annotation.color = newColor }
        pdfView.annotationsChanged(on: page)
        undo?.registerUndo(withTarget: self) { $0.recolor(annotation, to: old, on: page) }
        undo?.setActionName(L("Colour"))
    }

    func addMarkup(for selection: PDFSelection, tool: Tool) {
        let subtype: PDFAnnotationSubtype = tool == .highlight ? .highlight : tool == .underline ? .underline : .strikeOut
        let color = currentColor
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0.5, b.height > 0.5 else { continue }
                let annotation = PDFAnnotation(bounds: b, forType: subtype, withProperties: nil)
                annotation.color = tool == .highlight ? color.withAlphaComponent(0.45) : color
                annotation.quadrilateralPoints = [
                    NSValue(point: NSPoint(x: 0, y: b.height)), NSValue(point: NSPoint(x: b.width, y: b.height)),
                    NSValue(point: NSPoint(x: 0, y: 0)), NSValue(point: NSPoint(x: b.width, y: 0)),
                ]
                stamp(annotation)
                add(annotation, to: page, name: tool.title)
            }
        }
    }

    /// Font for text boxes (not the system font, which extracts Cyrillic incorrectly from PDFs).
    static func textFont(_ size: CGFloat) -> NSFont { NSFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size) }

    private func textSize(_ text: String, font: NSFont) -> CGSize {
        let r = (text as NSString).boundingRect(with: CGSize(width: 460, height: CGFloat.greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                attributes: [.font: font])
        return CGSize(width: ceil(r.width) + 14, height: ceil(r.height) + 8)
    }

    private func makeTextBox(_ text: String, font: NSFont, color: NSColor, topLeft: CGPoint) -> PDFAnnotation {
        let s = textSize(text, font: font)
        let annotation = PDFAnnotation(bounds: CGRect(x: topLeft.x, y: topLeft.y - s.height, width: s.width, height: s.height),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = color
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        stamp(annotation)
        return annotation
    }

    func createTextBox(on page: PDFPage, at point: CGPoint) {
        guard let (text, size) = promptText(title: L("New Text Box"), initial: "", fontSize: fontSize) else { return }
        fontSize = size
        let annotation = makeTextBox(text, font: Self.textFont(size), color: currentColor, topLeft: point)
        add(annotation, to: page, name: L("Text Box"))
        setTool(.select)
        pdfView.selectAnnotation(annotation, on: page)
    }

    func createNote(on page: PDFPage, at point: CGPoint) {
        guard let (text, _) = promptText(title: L("New Note"), initial: "", fontSize: nil) else { return }
        let annotation = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 22, height: 22), forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = currentColor
        annotation.iconType = .comment
        stamp(annotation)
        add(annotation, to: page, name: L("Note"))
    }

    func editAnnotationText(_ annotation: PDFAnnotation, on page: PDFPage) {
        guard annotation.isKind(.freeText) || annotation.isKind(.text) else { return }
        let isText = annotation.isKind(.freeText)
        let currentFont = annotation.font ?? Self.textFont(fontSize)
        guard let (text, size) = promptText(title: isText ? L("Edit Text") : L("Note"), initial: annotation.contents ?? "",
                                            fontSize: isText ? currentFont.pointSize : nil) else { return }
        var bounds = annotation.bounds
        var font: NSFont? = annotation.font
        if isText {
            let f = NSFont(descriptor: currentFont.fontDescriptor, size: size) ?? Self.textFont(size)
            font = f
            let s = textSize(text, font: f)
            bounds = CGRect(x: bounds.minX, y: bounds.maxY - s.height, width: s.width, height: s.height)
        }
        setText(annotation, text: text, font: font, bounds: bounds, on: page)
    }

    private func setText(_ annotation: PDFAnnotation, text: String, font: NSFont?, bounds: CGRect, on page: PDFPage) {
        let old = (annotation.contents ?? "", annotation.font, annotation.bounds)
        annotation.contents = text
        if let font { annotation.font = font }
        annotation.bounds = bounds
        stamp(annotation)
        pdfView.annotationsChanged(on: page)
        pdfView.refreshMarker()
        undo?.registerUndo(withTarget: self) { $0.setText(annotation, text: old.0, font: old.1, bounds: old.2, on: page) }
        undo?.setActionName(L("Edit Text"))
    }

    /// Replaces selected page text: covers it with white and places an editable text box on top,
    /// matching the original size and colour.
    @objc func replaceSelectedTextAction(_ sender: Any?) {
        guard let selection = pdfView.currentSelection, let original = selection.string,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("Select some text")
            alert.informativeText = L("Select text on the page with the Select tool, then choose “Edit Selected Text” (⌘E).")
            alert.beginSheetModal(for: window!)
            return
        }
        let attributes = selection.attributedString?.attributes(at: 0, effectiveRange: nil) ?? [:]
        let sourceFont = attributes[.font] as? NSFont
        let sourceColor = (attributes[.foregroundColor] as? NSColor) ?? .black
        let lines = selection.selectionsByLine()
        guard let firstLine = lines.first, let firstPage = firstLine.pages.first,
              let (text, size) = promptText(title: L("Edit Text"), initial: original, fontSize: (sourceFont?.pointSize ?? 12).rounded())
        else { return }

        for line in lines {
            for page in line.pages {
                let cover = PDFAnnotation(bounds: line.bounds(for: page).insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
                let border = PDFBorder()
                border.lineWidth = 0
                cover.border = border
                cover.color = .white
                cover.interiorColor = .white
                stamp(cover)
                add(cover, to: page, name: L("Edit Text"))
            }
        }
        let font = sourceFont.flatMap { NSFont(descriptor: $0.fontDescriptor, size: size) } ?? Self.textFont(size)
        let b = firstLine.bounds(for: firstPage)
        let box = makeTextBox(text, font: font, color: sourceColor, topLeft: CGPoint(x: b.minX - 4, y: b.maxY + 3))
        add(box, to: firstPage, name: L("Edit Text"))
        pdfView.clearSelection()
        setTool(.select)
        pdfView.selectAnnotation(box, on: firstPage)
    }

    @objc func highlightSelectionAction(_ sender: Any?) {
        guard let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty else { NSSound.beep(); return }
        addMarkup(for: selection, tool: .highlight)
        pdfView.clearSelection()
    }

    @objc func deleteSelectedAnnotation(_ sender: Any?) {
        guard let annotation = pdfView.selectedAnnotation, let page = pdfView.selectedPage else { return }
        remove(annotation, from: page, name: L("Delete Annotation"))
    }

    // MARK: - Signatures & stamps (images)

    @objc func showStampsAction(_ sender: Any?) {
        let popover = NSPopover()
        let vc = StampLibraryViewController { [weak self] image in self?.insertImage(image) }
        vc.popover = popover
        popover.contentViewController = vc
        popover.behavior = .transient
        if let item = toolbarController.item(for: Cmd.stamps), window?.toolbar?.isVisible == true {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: NSRect(x: pdfView.bounds.midX, y: pdfView.bounds.maxY - 20, width: 1, height: 1), of: pdfView, preferredEdge: .minY)
        }
    }

    @objc func insertImageAction(_ sender: Any?) {
        guard let image = StampLibrary.pickImage(window: window) else { return }
        insertImage(image)
    }

    /// Places an image (signature, seal) in the middle of the visible part of the current page.
    func insertImage(_ image: CGImage) {
        guard let page = pdfView.currentPage else { return }
        let pageBox = page.bounds(for: .cropBox)
        let center = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
        let aspect = CGFloat(image.width) / max(1, CGFloat(image.height))
        let width = min(170, pageBox.width * 0.4)
        let size = CGSize(width: width, height: width / aspect)
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = min(max(origin.x, pageBox.minX), pageBox.maxX - size.width)
        origin.y = min(max(origin.y, pageBox.minY), pageBox.maxY - size.height)
        let annotation = ImageStampAnnotation(image: image, bounds: CGRect(origin: origin, size: size))
        stamp(annotation)
        add(annotation, to: page, name: L("Signature or Stamp"))
        setTool(.select)
        pdfView.selectAnnotation(annotation, on: page)
    }

    @objc func signDocumentAction(_ sender: Any?) {
        guard let doc = pdfDoc, let pdf else { return }
        let alreadySigned = !doc.signatures.isEmpty
        if alreadySigned && doc.isDocumentEdited {
            let alert = NSAlert()
            alert.messageText = L("The document is already signed and has been changed")
            alert.informativeText = L("Signing the changed version will invalidate the existing signatures. To add a second signature, undo your changes first.")
            alert.addButton(withTitle: L("Sign Anyway"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let options = SignDialog.run() else { return }

        prepareForSave()
        let base: Data
        if alreadySigned, !doc.isDocumentEdited, let original = doc.originalData {
            base = original
        } else if let data = pdf.dataRepresentation() {
            base = data
        } else { return }

        let signed: Data
        do { signed = try PDFSigner.sign(base, options: options) } catch {
            presentError(error)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = doc.fileURL?.deletingPathExtension().lastPathComponent ?? doc.displayName ?? L("Document")
        panel.nameFieldStringValue = alreadySigned ? "\(baseName).pdf" : L("%@ (signed).pdf", baseName)
        panel.directoryURL = doc.fileURL?.deletingLastPathComponent()
        panel.message = L("Save the signed document")
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try signed.write(to: url)
                if url == doc.fileURL {
                    try doc.revert(toContentsOf: url, ofType: doc.fileType ?? "com.adobe.pdf")
                } else {
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
            } catch { self.presentError(error) }
        }
    }

    @objc func verifySignaturesAction(_ sender: Any?) { showSignatures() }

    // MARK: - Export

    @objc func exportWithPasswordAction(_ sender: Any?) {
        guard let pdf, let window else { return }
        let p1 = NSSecureTextField(), p2 = NSSecureTextField()
        let alert = NSAlert.form(L("Export with Password"), info: L("The copy will open only with the password."),
                                 ok: L("Continue…"), rows: [(L("Password:"), p1), (L("Repeat:"), p2)])
        alert.window.initialFirstResponder = p1
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !p1.stringValue.isEmpty, p1.stringValue == p2.stringValue else {
            let e = NSAlert()
            e.messageText = L("Passwords do not match")
            e.beginSheetModal(for: window)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("%@ (protected).pdf", pdfDoc?.displayName ?? L("Document"))
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            prepareForSave()
            let ok = pdf.write(to: url, withOptions: [.userPasswordOption: p1.stringValue, .ownerPasswordOption: p1.stringValue])
            if !ok { presentError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)) }
        }
    }

    @objc func exportPNGAction(_ sender: Any?) {
        guard let pdf, let window else { return }
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: ["PNG", "JPEG"])
        let dpi = NSPopUpButton(frame: .zero, pullsDown: false)
        dpi.addItems(withTitles: ["72 dpi", "150 dpi", "200 dpi", "300 dpi"])
        dpi.selectItem(at: 2)
        let row = NSStackView(views: [NSTextField(labelWithString: L("Format:")), format, NSTextField(labelWithString: L("Resolution:")), dpi])
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.frame.size = row.fittingSize
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Export")
        panel.message = L("Folder for the images (pages selected in thumbnails, or the current page)")
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        let indices = targetIndices
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let dir = panel.url else { return }
            prepareForSave()
            let name = pdfDoc?.displayName.map { ($0 as NSString).deletingPathExtension } ?? L("Page")
            let scale = [72.0, 150, 200, 300][max(0, dpi.indexOfSelectedItem)] / 72
            let jpeg = format.indexOfSelectedItem == 1
            for i in indices {
                guard let page = pdf.page(at: i) else { continue }
                let box = page.bounds(for: .cropBox)
                let image = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:]) else { continue }
                try? data.write(to: dir.appendingPathComponent("\(name) — \(i + 1).\(jpeg ? "jpg" : "png")"))
            }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    static let exportFormats: [(title: String, ext: String)] = [
        ("Word (.docx)", "docx"), ("Rich Text (.rtf)", "rtf"), (L("Plain Text"), "txt"), ("HTML", "html"),
    ]

    /// PDF text with fonts, one page per section (page breaks between pages).
    var pagesAsText: NSAttributedString { pdf.map(PDFDoc.attributedText) ?? NSAttributedString() }

    @objc func exportAsAction(_ sender: Any?) {
        guard let window else { return }
        let formats = Self.exportFormats
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        let row = NSStackView(views: [NSTextField(labelWithString: L("Format:")), popup])
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.frame.size = row.fittingSize
        let panel = NSSavePanel()
        panel.accessoryView = row
        let base = pdfDoc?.fileURL?.deletingPathExtension().lastPathComponent ?? pdfDoc?.displayName ?? L("Document")
        let observer = ClosureTarget { [weak panel] in
            let f = formats[max(0, popup.indexOfSelectedItem)]
            panel?.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .data]
            panel?.nameFieldStringValue = base + "." + f.ext
        }
        observer.fire()
        popup.target = observer
        popup.action = #selector(ClosureTarget.fire)
        panel.beginSheetModal(for: window) { [self] response in
            _ = observer
            guard response == .OK, let url = panel.url else { return }
            prepareForSave()
            let text = pagesAsText
            let range = NSRange(location: 0, length: text.length)
            do {
                switch formats[max(0, popup.indexOfSelectedItem)].ext {
                case "docx": try DocxWriter.data(text).write(to: url)
                case "rtf": try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url)
                case "html": try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                                            .characterEncoding: String.Encoding.utf8.rawValue]).write(to: url)
                default: try Data((pdf?.string ?? "").utf8).write(to: url)
                }
            } catch { presentError(error) }
        }
    }

    // MARK: - Dialogs

    private func promptText(title: String, initial: String, fontSize: CGFloat?) -> (String, CGFloat)? {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as! NSTextView
        textView.string = initial
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let sizes: [CGFloat] = [6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 36, 48, 72]
        let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let stack = NSStackView(views: [scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        if let fontSize {
            sizePopup.addItems(withTitles: sizes.map { "\(Int($0)) pt" })
            let nearest = sizes.enumerated().min { abs($0.element - fontSize) < abs($1.element - fontSize) }?.offset ?? 8
            sizePopup.selectItem(at: nearest)
            stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: L("Font size:")), sizePopup]))
        }
        stack.frame.size = stack.fittingSize

        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L("Done"))
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = stack
        alert.layout()
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, fontSize == nil ? 0 : sizes[max(0, sizePopup.indexOfSelectedItem)])
    }

    // MARK: - View

    @objc func showThumbnailsAction(_ sender: Any?) { showSidebar(.thumbnails) }
    @objc func showOutlineAction(_ sender: Any?) { showSidebar(.outline) }

    private func showSidebar(_ mode: SidebarViewController.Mode) {
        sidebar.mode = mode
        if splitController.splitViewItems.first?.isCollapsed == true { splitController.toggleSidebar(nil) }
    }

    @objc func zoomInAction(_ sender: Any?) { pdfView.zoomIn(nil) }
    @objc func zoomOutAction(_ sender: Any?) { pdfView.zoomOut(nil) }
    @objc func zoomToFitAction(_ sender: Any?) { pdfView.autoScales = true }
    @objc func actualSizeAction(_ sender: Any?) { pdfView.autoScales = false; pdfView.scaleFactor = 1 }

    @objc func setDisplayModeAction(_ sender: Any?) {
        pdfView.displayMode = PDFDisplayMode(rawValue: commandTag(of: sender)) ?? .singlePageContinuous
    }

    @objc func nextPageAction(_ sender: Any?) { pdfView.goToNextPage(nil) }
    @objc func previousPageAction(_ sender: Any?) { pdfView.goToPreviousPage(nil) }

    @objc func goToPageAction(_ sender: Any?) {
        guard let pdf else { return }
        let field = NSTextField()
        field.placeholderString = "1–\(pdf.pageCount)"
        let alert = NSAlert.form(L("Go to Page"), ok: L("Go"), rows: [(L("Page:"), field)])
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let n = Int(field.stringValue),
              let page = pdf.page(at: min(max(n, 1), pdf.pageCount) - 1) else { return }
        pdfView.go(to: page)
    }

    // MARK: - Search

    @objc func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        if query != lastSearch {
            lastSearch = query
            searchResults = query.isEmpty ? [] : (pdf?.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? [])
            searchResults.forEach { $0.color = .systemYellow }
            pdfView.highlightedSelections = searchResults.isEmpty ? nil : searchResults
            searchIndex = -1
        }
        showSearchResult(step: 1)
    }

    private func showSearchResult(step: Int) {
        guard !searchResults.isEmpty else {
            updateSubtitle()
            return
        }
        searchIndex = (searchIndex + step + searchResults.count) % searchResults.count
        let selection = searchResults[searchIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
        updateSubtitle()
    }

    private func resetSearch() {
        lastSearch = ""
        searchResults = []
        searchIndex = -1
        pdfView.highlightedSelections = nil
        toolbarController.searchItem?.searchField.stringValue = ""
    }

    @objc func focusSearchAction(_ sender: Any?) { toolbarController.searchItem?.beginSearchInteraction() }
    @objc func findNextAction(_ sender: Any?) { showSearchResult(step: 1) }
    @objc func findPreviousAction(_ sender: Any?) { showSearchResult(step: -1) }

    // MARK: - Pages (undoable)

    private var currentIndex: Int {
        guard let pdf, let page = pdfView.currentPage else { return 0 }
        return pdf.index(for: page)
    }

    /// Pages selected in the thumbnail sidebar, or the current page.
    private var targetIndices: [Int] {
        guard let pdf else { return [] }
        let selected = (sidebar.thumbnails.selectedPages ?? []).map { pdf.index(for: $0) }.filter { $0 != NSNotFound }
        return selected.count > 1 ? selected.sorted() : [currentIndex]
    }

    @objc func rotateLeftAction(_ sender: Any?) { rotate(targetIndices, by: -90) }
    @objc func rotateRightAction(_ sender: Any?) { rotate(targetIndices, by: 90) }

    private func rotate(_ indices: [Int], by degrees: Int) {
        guard let pdf else { return }
        for i in indices {
            guard let page = pdf.page(at: i) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        pdfView.layoutDocumentView()
        undo?.registerUndo(withTarget: self) { $0.rotate(indices, by: -degrees) }
        undo?.setActionName(L("Rotate"))
    }

    @objc func deletePagesAction(_ sender: Any?) {
        guard let pdf else { return }
        let indices = targetIndices
        guard indices.count < pdf.pageCount else {
            NSSound.beep()
            return
        }
        deletePages(indices)
    }

    private func deletePages(_ indices: [Int]) {
        guard let pdf else { return }
        pdfView.selectAnnotation(nil)
        let pages = indices.compactMap { pdf.page(at: $0) }
        for i in indices.sorted().reversed() { pdf.removePage(at: i) }
        pdfView.layoutDocumentView()
        undo?.registerUndo(withTarget: self) { $0.insertPages(pages, at: indices) }
        undo?.setActionName(L("Delete Pages"))
        updateSubtitle()
    }

    private func insertPages(_ pages: [PDFPage], at indices: [Int]) {
        guard let pdf else { return }
        for (page, i) in zip(pages, indices).sorted(by: { $0.1 < $1.1 }) {
            pdf.insert(page, at: min(i, pdf.pageCount))
        }
        pdfView.layoutDocumentView()
        if let first = pages.first { pdfView.go(to: first) }
        undo?.registerUndo(withTarget: self) { $0.deletePages(indices) }
        undo?.setActionName(L("Insert Pages"))
        updateSubtitle()
    }

    @objc func insertBlankPageAction(_ sender: Any?) {
        let size = pdfView.currentPage?.bounds(for: .mediaBox).size ?? CGSize(width: 595, height: 842)
        insertPages([PDFPage.blank(size: size)], at: [(pdf?.pageCount ?? 0) == 0 ? 0 : currentIndex + 1])
    }

    @objc func insertFromFileAction(_ sender: Any?) {
        guard let window, let pdf else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = L("Pages of the chosen PDFs will be inserted after the current page")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            var pages: [PDFPage] = []
            for url in panel.urls {
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    if let image = NSImage(contentsOf: url), let page = PDFDoc.page(from: image) { pages.append(page) }
                    continue
                }
                guard let other = PDFDocument(url: url) else { continue }
                for i in 0..<other.pageCount {
                    if let page = other.page(at: i)?.copy() as? PDFPage { pages.append(page) }
                }
            }
            guard !pages.isEmpty else { return }
            let start = pdf.pageCount == 0 ? 0 : self.currentIndex + 1
            self.insertPages(pages, at: Array(start..<(start + pages.count)))
        }
    }

    @objc func movePageUpAction(_ sender: Any?) { movePage(currentIndex, by: -1) }
    @objc func movePageDownAction(_ sender: Any?) { movePage(currentIndex, by: 1) }

    private func movePage(_ index: Int, by delta: Int) {
        guard let pdf else { return }
        let target = index + delta
        guard target >= 0, target < pdf.pageCount else { return }
        pdf.exchangePage(at: index, withPageAt: target)
        pdfView.layoutDocumentView()
        if let page = pdf.page(at: target) { pdfView.go(to: page) }
        undo?.registerUndo(withTarget: self) { $0.movePage(target, by: -delta) }
        undo?.setActionName(L("Move Page"))
        updateSubtitle()
    }

    @objc func extractPagesAction(_ sender: Any?) {
        guard let pdf else { return }
        prepareForSave()
        let newPDF = PDFDocument()
        for i in targetIndices {
            if let page = pdf.page(at: i)?.copy() as? PDFPage { newPDF.insert(page, at: newPDF.pageCount) }
        }
        let doc = PDFDoc(pdf: newPDF)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.updateChangeCount(.changeDone)
    }

    // MARK: - Validation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action, tag: item.tag, menuItem: nil) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item.action, tag: item.tag, menuItem: item) }

    private func validate(_ action: Selector?, tag: Int, menuItem: NSMenuItem?) -> Bool {
        guard let pdf else { return false }
        switch action {
        case #selector(selectToolAction(_:)):
            menuItem?.state = tag == pdfView.tool.rawValue ? .on : .off
        case #selector(setDisplayModeAction(_:)):
            menuItem?.state = tag == pdfView.displayMode.rawValue ? .on : .off
        case #selector(toggleMarkupAction(_:)):
            menuItem?.title = markupStrip.isShown ? L("Hide Markup Toolbar") : L("Show Markup Toolbar")
        case #selector(showThumbnailsAction(_:)):
            menuItem?.state = sidebar.mode == .thumbnails ? .on : .off
        case #selector(showOutlineAction(_:)):
            menuItem?.state = sidebar.mode == .outline ? .on : .off
        case #selector(deleteSelectedAnnotation(_:)):
            return pdfView.selectedAnnotation != nil
        case #selector(deletePagesAction(_:)):
            return targetIndices.count < pdf.pageCount
        case #selector(movePageUpAction(_:)):
            return currentIndex > 0
        case #selector(movePageDownAction(_:)):
            return currentIndex < pdf.pageCount - 1
        case #selector(findNextAction(_:)), #selector(findPreviousAction(_:)):
            return !searchResults.isEmpty
        case #selector(verifySignaturesAction(_:)):
            return true
        default:
            break
        }
        return true
    }
}

/// Target object for controls whose action should run a closure.
final class ClosureTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
