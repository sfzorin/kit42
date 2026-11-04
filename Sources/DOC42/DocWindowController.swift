import AppKit
import Kit42
import UniformTypeIdentifiers

/// Grey desk with a white A4-wide page; the text view grows downwards inside it.
final class PageView: NSView {
    let page: NSTextView
    static let pageWidth: CGFloat = 595   // A4, points
    static let margin: CGFloat = 32

    init(textView: NSTextView) {
        page = textView
        super.init(frame: .zero)
        addSubview(page)
        page.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(relayout), name: NSView.frameDidChangeNotification, object: page)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
    }

    @objc func relayout() {
        let width = max(enclosingScrollView?.contentSize.width ?? 0, Self.pageWidth + Self.margin * 2)
        let height = max(page.frame.height + Self.margin * 2, (enclosingScrollView?.contentSize.height ?? 0))
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        let x = floor((width - Self.pageWidth) / 2)
        if page.frame.origin != NSPoint(x: x, y: Self.margin) { page.setFrameOrigin(NSPoint(x: x, y: Self.margin)) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { relayout() }
}

final class DocWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let textView: NSTextView
    private let scrollView = NSScrollView()
    private lazy var pageView = PageView(textView: textView)
    private let toolbarController = ToolbarController(identifier: "DOC42.toolbar", elements: Cmd.toolbar)
    private lazy var stylePopup = stripPopUp(Styles.all.map(\.name), width: 128, toolTip: L("Paragraph style"),
                                             target: self, action: #selector(styleChanged(_:)))
    private lazy var fontPopup = stripPopUp(["Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Palatino", "Avenir Next", "Calibri", "Courier New", "Menlo"],
                                            width: 128, toolTip: L("Font"), target: self, action: #selector(fontChanged(_:)))
    private lazy var sizeStepper: SizeStepper = {
        let s = SizeStepper(toolTip: L("Font size"))
        s.target = self
        s.action = #selector(sizeChanged(_:))
        return s
    }()
    private lazy var textColorButton: ColorButton = {
        let b = ColorButton(symbol: "textformat", toolTip: L("Text colour"), color: .black, allowsNone: false)
        b.target = self
        b.action = #selector(colorChanged(_:))
        return b
    }()
    private lazy var highlightButton: ColorButton = {
        let b = ColorButton(symbol: "highlighter", toolTip: L("Highlight"), color: nil)
        b.target = self
        b.action = #selector(highlightChanged(_:))
        return b
    }()
    private lazy var alignButton = StripButton(symbol: "text.alignleft", toolTip: L("Alignment"),
                                               menu: commandMenu([Cmd.alignLeft, Cmd.alignCenter, Cmd.alignRight, Cmd.justify]))
    private lazy var listButton = StripButton(symbol: "list.bullet", toolTip: L("Lists"),
                                              menu: commandMenu([Cmd.bulletList, Cmd.numberedList]))
    private lazy var formatStrip = ToolStrip([
        .group([.view(stylePopup)]),
        .group([.view(fontPopup), .view(sizeStepper)]),
        .buttons([Cmd.bold, Cmd.italic, Cmd.underline, Cmd.strike]),
        .group([.view(textColorButton), .view(highlightButton)]),
        .group([.view(alignButton), .view(listButton), .command(Cmd.outdent), .command(Cmd.indent)]),
        .buttons([Cmd.insertImage, Cmd.insertTable, Cmd.stamps]),
    ])

    var doc: TextDocument? { document as? TextDocument }

    init(storage: NSTextStorage) {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: PageView.pageWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: PageView.pageWidth, height: 842), textContainer: container)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 420)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        setupText()
        setupContent()
        window.toolbar = toolbarController.toolbar
        window.addTitlebarAccessoryViewController(formatStrip)
        window.center()
        updateStatus()
        syncControls()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func setupText() {
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesRuler = true
        textView.usesInspectorBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: PageView.pageWidth, height: 842)
        textView.maxSize = NSSize(width: PageView.pageWidth, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 64, height: 64)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.insertionPointColor = .black
        textView.typingAttributes = Styles.normal.attributes
        textView.delegate = self
        textView.wantsLayer = true
        textView.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        textView.layer?.masksToBounds = false
    }

    private func setupContent() {
        scrollView.documentView = pageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        NotificationCenter.default.addObserver(pageView, selector: #selector(PageView.relayout), name: NSView.frameDidChangeNotification, object: scrollView)
        DispatchQueue.main.async { self.pageView.relayout() }

    }

    // MARK: - Status

    func textDidChange(_ notification: Notification) { updateStatus() }

    func textViewDidChangeSelection(_ notification: Notification) { syncControls() }

    private func updateStatus() {
        let text = textView.string
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        window?.subtitle = L("%d words · %d characters", words, text.count)
    }

    private var currentAttributes: [NSAttributedString.Key: Any] {
        let r = textView.selectedRange()
        if r.length > 0, r.location < textView.textStorage!.length {
            return textView.textStorage!.attributes(at: r.location, effectiveRange: nil)
        }
        return textView.typingAttributes
    }

    private func syncControls() {
        let attrs = currentAttributes
        if let font = attrs[.font] as? NSFont {
            let family = font.familyName ?? font.fontName
            if fontPopup.item(withTitle: family) == nil { fontPopup.addItem(withTitle: family) }
            fontPopup.selectItem(withTitle: family)
            sizeStepper.value = font.pointSize
            let style = Styles.all.firstIndex { abs($0.size - font.pointSize) < 0.5 && ($0.weight != .regular) == NSFontManager.shared.traits(of: font).contains(.boldFontMask) }
            stylePopup.selectItem(at: style ?? Styles.all.firstIndex { $0.name == Styles.normal.name }!)
            let traits = NSFontManager.shared.traits(of: font)
            formatStrip.setState(traits.contains(.boldFontMask), for: #selector(toggleBold(_:)))
            formatStrip.setState(traits.contains(.italicFontMask), for: #selector(toggleItalic(_:)))
        }
        formatStrip.setState((attrs[.underlineStyle] as? Int ?? 0) != 0, for: #selector(toggleUnderline(_:)))
        formatStrip.setState((attrs[.strikethroughStyle] as? Int ?? 0) != 0, for: #selector(toggleStrike(_:)))
        textColorButton.color = attrs[.foregroundColor] as? NSColor ?? .black
        highlightButton.color = attrs[.backgroundColor] as? NSColor
        let p = attrs[.paragraphStyle] as? NSParagraphStyle
        let align: [NSTextAlignment: String] = [.center: "text.aligncenter", .right: "text.alignright", .justified: "text.justify"]
        alignButton.setSymbol(align[p?.alignment ?? .left] ?? "text.alignleft")
        listButton.setSymbol(p?.textLists.last?.markerFormat == .decimal ? "list.number" : "list.bullet")
    }


    // MARK: - Applying formatting

    /// Applies a change to every selected range (or the typing attributes), undoably.
    private func applyFont(_ transform: (NSFont) -> NSFont) {
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let storage = textView.textStorage else { return }
        if ranges.isEmpty {
            var attrs = textView.typingAttributes
            attrs[.font] = transform(attrs[.font] as? NSFont ?? Styles.normal.font)
            textView.typingAttributes = attrs
            syncControls()
            return
        }
        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges {
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                storage.addAttribute(.font, value: transform(value as? NSFont ?? Styles.normal.font), range: sub)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        syncControls()
    }

    private func applyAttribute(_ key: NSAttributedString.Key, _ value: Any?) {
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let storage = textView.textStorage else { return }
        if ranges.isEmpty {
            textView.typingAttributes[key] = value
            return
        }
        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges {
            if let value { storage.addAttribute(key, value: value, range: r) } else { storage.removeAttribute(key, range: r) }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// Paragraph ranges touched by the selection.
    private var paragraphRanges: [NSRange] {
        let ns = textView.string as NSString
        return textView.selectedRanges.map { ns.paragraphRange(for: $0.rangeValue) }
    }

    private func applyParagraph(_ transform: (NSMutableParagraphStyle) -> Void) {
        guard let storage = textView.textStorage else { return }
        let ranges = paragraphRanges
        let current = (currentAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        guard storage.length > 0, ranges.contains(where: { $0.length > 0 }) else {
            transform(current)
            textView.typingAttributes[.paragraphStyle] = current
            return
        }
        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges where r.length > 0 {
            storage.enumerateAttribute(.paragraphStyle, in: r) { value, sub, _ in
                let p = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                transform(p)
                storage.addAttribute(.paragraphStyle, value: p, range: sub)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let font = currentAttributes[.font] as? NSFont ?? Styles.normal.font
        let has = NSFontManager.shared.traits(of: font).contains(trait)
        applyFont { has ? NSFontManager.shared.convert($0, toNotHaveTrait: trait) : NSFontManager.shared.convert($0, toHaveTrait: trait) }
    }

    @objc func toggleBold(_ sender: Any?) { toggleTrait(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { toggleTrait(.italicFontMask) }

    @objc func toggleUnderline(_ sender: Any?) {
        let on = (currentAttributes[.underlineStyle] as? Int ?? 0) != 0
        applyAttribute(.underlineStyle, on ? nil : NSUnderlineStyle.single.rawValue)
    }

    @objc func toggleStrike(_ sender: Any?) {
        let on = (currentAttributes[.strikethroughStyle] as? Int ?? 0) != 0
        applyAttribute(.strikethroughStyle, on ? nil : NSUnderlineStyle.single.rawValue)
    }

    @objc func alignAction(_ sender: Any?) {
        let alignment: NSTextAlignment = [.left, .center, .right, .justified][max(0, min(3, commandTag(of: sender)))]
        applyParagraph { $0.alignment = alignment }
    }

    @objc func indentAction(_ sender: Any?) { changeIndent(by: 28) }
    @objc func outdentAction(_ sender: Any?) { changeIndent(by: -28) }

    private func changeIndent(by delta: CGFloat) {
        applyParagraph {
            $0.headIndent = max(0, $0.headIndent + delta)
            $0.firstLineHeadIndent = max(0, $0.firstLineHeadIndent + delta)
        }
    }

    @objc func lineSpacingAction(_ sender: Any?) {
        let value = [1.0, 1.15, 1.5, 2.0][max(0, min(3, commandTag(of: sender)))]
        applyParagraph { $0.lineHeightMultiple = value }
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Styles.all.count else { return }
        applyStyle(Styles.all[i])
    }

    @objc func applyStyleAction(_ sender: Any?) {
        let i = commandTag(of: sender)
        guard i >= 0, i < Styles.all.count else { return }
        applyStyle(Styles.all[i])
    }

    private func applyStyle(_ style: Styles) {
        guard let storage = textView.textStorage else { return }
        let ranges = paragraphRanges.filter { $0.length > 0 }
        if ranges.isEmpty || storage.length == 0 {
            textView.typingAttributes = style.attributes
            return
        }
        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges { storage.addAttributes(style.attributes, range: r) }
        storage.endEditing()
        textView.didChangeText()
        textView.typingAttributes = style.attributes
        syncControls()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        guard let family = sender.titleOfSelectedItem else { return }
        applyFont { NSFontManager.shared.convert($0, toFamily: family) }
    }

    @objc private func sizeChanged(_ sender: SizeStepper) {
        let size = sender.value
        applyFont { NSFontManager.shared.convert($0, toSize: size) }
    }

    @objc func biggerAction(_ sender: Any?) { applyFont { NSFontManager.shared.convert($0, toSize: $0.pointSize + 1) } }
    @objc func smallerAction(_ sender: Any?) { applyFont { NSFontManager.shared.convert($0, toSize: max(4, $0.pointSize - 1)) } }

    @objc private func colorChanged(_ sender: ColorButton) { applyAttribute(.foregroundColor, sender.color ?? .black) }
    @objc private func highlightChanged(_ sender: ColorButton) { applyAttribute(.backgroundColor, sender.color) }
    @objc func removeHighlightAction(_ sender: Any?) { applyAttribute(.backgroundColor, nil) }

    @objc func clearFormattingAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty, textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges { storage.setAttributes(Styles.normal.attributes, range: r) }
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: - Lists

    @objc func bulletListAction(_ sender: Any?) { toggleList(NSTextList(markerFormat: .disc, options: 0)) }
    @objc func numberedListAction(_ sender: Any?) { toggleList(NSTextList(markerFormat: .decimal, options: 0)) }

    /// Adds or removes list markers ("\t•\t") on the selected paragraphs, like TextEdit.
    private func toggleList(_ list: NSTextList) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let selection = textView.selectedRange()
        var full = ns.paragraphRange(for: selection)
        if full.length == 0 && storage.length == 0 {
            storage.append(NSAttributedString(string: "", attributes: textView.typingAttributes))
        }
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, r, enclosing, _ in paragraphs.append(enclosing) }
        if paragraphs.isEmpty { paragraphs = [full] }
        let existing = (storage.length > 0 && full.location < storage.length)
            ? (storage.attribute(.paragraphStyle, at: full.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.first : nil
        let removing = existing?.markerFormat == list.markerFormat

        let result = NSMutableAttributedString()
        for (i, r) in paragraphs.enumerated() {
            let para = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: r))
            // Strip an existing marker
            if let m = para.string.range(of: "^\t[^\t]*\t", options: .regularExpression) {
                para.deleteCharacters(in: NSRange(m, in: para.string))
            }
            let p = ((para.length > 0 ? para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) : nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            if removing {
                p.textLists = []
                p.headIndent = 0
                p.firstLineHeadIndent = 0
                p.tabStops = []
            } else {
                p.textLists = [list]
                p.headIndent = 36
                p.firstLineHeadIndent = 0
                p.tabStops = [NSTextTab(textAlignment: .left, location: 12), NSTextTab(textAlignment: .left, location: 36)]
                let attrs = para.length > 0 ? para.attributes(at: 0, effectiveRange: nil) : textView.typingAttributes
                para.insert(NSAttributedString(string: "\t\(list.marker(forItemNumber: i + 1))\t", attributes: attrs), at: 0)
            }
            para.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: para.length))
            result.append(para)
        }
        full = NSRange(location: paragraphs.first!.location, length: NSMaxRange(paragraphs.last!) - paragraphs.first!.location)
        guard textView.shouldChangeText(in: full, replacementString: result.string) else { return }
        storage.replaceCharacters(in: full, with: result)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: full.location + result.length - (result.string.hasSuffix("\n") ? 1 : 0), length: 0))
    }

    // MARK: - Insert

    private func insert(_ s: NSAttributedString) {
        let r = textView.selectedRange()
        guard textView.shouldChangeText(in: r, replacementString: s.string) else { return }
        textView.textStorage?.replaceCharacters(in: r, with: s)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: r.location + s.length, length: 0))
        window?.makeFirstResponder(textView)
    }

    private func imageAttachment(_ image: NSImage, width: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let maxWidth = PageView.pageWidth - textView.textContainerInset.width * 2
        let w = min(width, maxWidth)
        let size = NSSize(width: w, height: w * image.size.height / max(1, image.size.width))
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let wrapper = FileWrapper(regularFileWithContents: png)
            wrapper.preferredFilename = "image.png"
            attachment.fileWrapper = wrapper
        }
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes(textView.typingAttributes.filter { $0.key == .paragraphStyle }, range: NSRange(location: 0, length: s.length))
        return s
    }

    @objc func insertImageAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        insert(imageAttachment(image, width: image.size.width))
    }

    @objc func showStampsAction(_ sender: Any?) {
        let popover = NSPopover()
        let vc = StampLibraryViewController { [weak self] cg in
            guard let self else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            self.insert(self.imageAttachment(image, width: 170))
        }
        vc.popover = popover
        popover.contentViewController = vc
        popover.behavior = .transient
        if let item = toolbarController.item(for: Cmd.stamps), window?.toolbar?.isVisible == true {
            popover.show(relativeTo: item)
        } else {
            popover.show(relativeTo: textView.visibleRect, of: textView, preferredEdge: .minY)
        }
    }

    @objc func insertTableAction(_ sender: Any?) {
        let rows = NSTextField(string: "3"), cols = NSTextField(string: "3")
        let alert = NSAlert.form(L("Insert Table"), ok: L("Insert"), rows: [(L("Rows:"), rows), (L("Columns:"), cols)])
        guard alert.runModal() == .alertFirstButtonReturn,
              let r = Int(rows.stringValue), let c = Int(cols.stringValue), (1...100).contains(r), (1...20).contains(c) else { return }
        let table = NSTextTable()
        table.numberOfColumns = c
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        let out = NSMutableAttributedString()
        let font = (textView.typingAttributes[.font] as? NSFont) ?? Styles.normal.font
        let start = textView.selectedRange().location
        if start > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        for row in 0..<r {
            for col in 0..<c {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: col, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(white: 0.6, alpha: 1))
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                block.setValue(100 / CGFloat(c), type: .percentageValueType, for: .width)
                let p = NSMutableParagraphStyle()
                p.textBlocks = [block]
                out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: p]))
            }
        }
        insert(out)
        textView.setSelectedRange(NSRange(location: start + (start > 0 ? 1 : 0), length: 0))
    }

    @objc func insertPageBreakAction(_ sender: Any?) {
        insert(NSAttributedString(string: "\u{000C}", attributes: textView.typingAttributes))
    }

    @objc func insertDateAction(_ sender: Any?) {
        insert(NSAttributedString(string: Date().formatted(date: .long, time: .omitted), attributes: textView.typingAttributes))
    }

    // MARK: - View & export

    @objc func zoomInAction(_ sender: Any?) { scrollView.magnification = min(3, scrollView.magnification + 0.1) }
    @objc func zoomOutAction(_ sender: Any?) { scrollView.magnification = max(0.5, scrollView.magnification - 0.1) }
    @objc func actualSizeAction(_ sender: Any?) { scrollView.magnification = 1 }
    @objc func toggleFormatBarAction(_ sender: Any?) { formatStrip.isShown.toggle() }
    @objc func toggleRulerAction(_ sender: Any?) { textView.toggleRuler(sender) }

    @objc func findAction(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
        window?.makeFirstResponder(textView)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        let q = sender.stringValue
        guard !q.isEmpty else { return }
        let ns = textView.string as NSString
        let start = NSMaxRange(textView.selectedRange())
        var found = ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: ns.length - start))
        if found.location == NSNotFound { found = ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) }
        guard found.location != NSNotFound else { NSSound.beep(); return }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
    }

    static let exportFormats: [(title: String, ext: String, type: NSAttributedString.DocumentType?)] = [
        ("PDF", "pdf", nil), ("Word (.docx)", "docx", .officeOpenXML), ("Word 97 (.doc)", "doc", .docFormat),
        ("Rich Text (.rtf)", "rtf", .rtf), ("OpenDocument (.odt)", "odt", .openDocument), ("HTML", "html", .html),
        (L("Plain Text"), "txt", .plain),
    ]

    @objc func exportPDFAction(_ sender: Any?) { export(formatIndex: 0) }
    @objc func exportAsAction(_ sender: Any?) { export(formatIndex: UserDefaults.standard.integer(forKey: "doc.exportFormat")) }

    private func export(formatIndex: Int) {
        guard let doc, let window else { return }
        let formats = Self.exportFormats
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        popup.selectItem(at: min(formatIndex, formats.count - 1))
        let row = NSStackView(views: [NSTextField(labelWithString: L("Format:")), popup])
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.frame.size = row.fittingSize
        let panel = NSSavePanel()
        panel.accessoryView = row
        let base = doc.fileURL?.deletingPathExtension().lastPathComponent ?? doc.displayName ?? L("Document")
        func apply() {
            let f = formats[max(0, popup.indexOfSelectedItem)]
            panel.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .data]
            panel.nameFieldStringValue = base + "." + f.ext
        }
        apply()
        let observer = PopupObserver(apply)
        popup.target = observer
        popup.action = #selector(PopupObserver.changed)
        panel.beginSheetModal(for: window) { response in
            _ = observer
            guard response == .OK, let url = panel.url else { return }
            let i = max(0, popup.indexOfSelectedItem)
            UserDefaults.standard.set(i, forKey: "doc.exportFormat")
            do {
                let data = try formats[i].type.map { try doc.exportData($0) } ?? doc.pdfData()
                try data.write(to: url)
            } catch { NSApp.presentError(error) }
        }
    }

    // MARK: - Validation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let attrs = currentAttributes
        let font = attrs[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        switch item.action {
        case #selector(toggleBold(_:)): item.state = traits.contains(.boldFontMask) ? .on : .off
        case #selector(toggleItalic(_:)): item.state = traits.contains(.italicFontMask) ? .on : .off
        case #selector(toggleUnderline(_:)): item.state = (attrs[.underlineStyle] as? Int ?? 0) != 0 ? .on : .off
        case #selector(toggleStrike(_:)): item.state = (attrs[.strikethroughStyle] as? Int ?? 0) != 0 ? .on : .off
        case #selector(alignAction(_:)):
            let a = (attrs[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural
            let mine: [NSTextAlignment] = [.left, .center, .right, .justified]
            item.state = mine[max(0, min(3, item.tag))] == a || (item.tag == 0 && a == .natural) ? .on : .off
        case #selector(toggleFormatBarAction(_:)):
            item.title = formatStrip.isShown ? L("Hide Format Bar") : L("Show Format Bar")
        case #selector(toggleRulerAction(_:)):
            item.title = textView.isRulerVisible ? L("Hide Ruler") : L("Show Ruler")
        default: break
        }
        return true
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { doc?.undoManager }
}

/// Closure target for controls inside save panels.
final class PopupObserver: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func changed() { handler() }
}
