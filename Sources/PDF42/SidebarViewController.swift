import AppKit
import Kit42
import PDFKit
import UniformTypeIdentifiers

/// Sidebar: page thumbnails, the editable document outline (bookmarks) or the attachments.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Int { case thumbnails, outline, attachments }

    let thumbnails = ThumbnailGrid(frame: .zero)
    weak var editor: EditorWindowController?
    private let pdfView: PDFView
    private let switcher = NSSegmentedControl(labels: [L("Thumbnails"), L("Contents"), L("Attachments")],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let outlineView = OutlineListView()
    private let outlineScroll = NSScrollView()
    private let outlinePane = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: L("No bookmarks. Press ⌘D to add one for the current page."))
    private static let outlineType = NSPasteboard.PasteboardType("com.sfzorin.pdf42.bookmark")
    private var draggedItem: PDFOutline?

    private let attachmentTable = AttachmentTableView()
    private let attachmentScroll = NSScrollView()
    private let attachmentPane = NSView()
    private let attachmentEmpty = NSTextField(wrappingLabelWithString: L("No attachments. Drop files here to embed them in the PDF."))

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var mode: Mode = .thumbnails {
        didSet {
            switcher.selectedSegment = mode.rawValue
            thumbnails.isHidden = mode != .thumbnails
            outlinePane.isHidden = mode != .outline
            attachmentPane.isHidden = mode != .attachments
            if mode == .outline { reloadOutline() }
            if mode == .attachments { reloadAttachments() }
        }
    }

    override func loadView() {
        let root = NSView()

        switcher.target = self
        switcher.action = #selector(switched(_:))
        switcher.controlSize = .small
        switcher.segmentDistribution = .fillEqually

        thumbnails.pdfView = pdfView

        // Outline
        let column = NSTableColumn(identifier: .init("title"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)
        outlineView.doubleAction = #selector(outlineDoubleClicked)
        outlineView.registerForDraggedTypes([Self.outlineType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.sidebar = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        outlineScroll.documentView = outlineView
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center

        let outlineBar = Self.bar([
            (Cmd.addBookmark, "plus"), (Cmd.deleteBookmark, "minus"),
            (Cmd.outdentBookmark, "decrease.indent"), (Cmd.indentBookmark, "increase.indent"),
        ], more: [Cmd.addChildBookmark, Cmd.renameBookmark, Cmd.setBookmarkDestination, nil, Cmd.bookmarksFromHeadings, nil] + Cmd.bookmarkStyles.map { $0 })
        Self.fill(outlinePane, content: outlineScroll, bar: outlineBar, empty: emptyLabel)

        // Attachments
        let nameColumn = NSTableColumn(identifier: .init("name"))
        attachmentTable.addTableColumn(nameColumn)
        attachmentTable.headerView = nil
        attachmentTable.style = .sourceList
        attachmentTable.dataSource = self
        attachmentTable.delegate = self
        attachmentTable.rowHeight = 34
        attachmentTable.doubleAction = #selector(attachmentDoubleClicked)
        attachmentTable.target = self
        attachmentTable.registerForDraggedTypes([.fileURL])
        attachmentTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        attachmentTable.sidebar = self
        attachmentScroll.documentView = attachmentTable
        attachmentScroll.drawsBackground = false
        attachmentScroll.hasVerticalScroller = true
        attachmentEmpty.textColor = .tertiaryLabelColor
        attachmentEmpty.font = .systemFont(ofSize: 12)
        attachmentEmpty.alignment = .center
        let attachmentBar = Self.bar([(Cmd.addAttachment, "plus"), (Cmd.deleteAttachment, "minus"), (Cmd.saveAttachment, "square.and.arrow.down")],
                                     more: [Cmd.openAttachment])
        Self.fill(attachmentPane, content: attachmentScroll, bar: attachmentBar, empty: attachmentEmpty)

        for v in [switcher, thumbnails, outlinePane, attachmentPane] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            switcher.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
        ])
        for v in [thumbnails, outlinePane, attachmentPane] as [NSView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8),
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        mode = .thumbnails
    }

    /// Small button bar under a list; the buttons send their commands up the responder chain.
    private static func bar(_ buttons: [(Command, String)], more: [Command?]) -> NSView {
        var views: [NSView] = buttons.map { command, symbol in
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: command.title) ?? NSImage(), target: nil, action: command.action)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = command.fullToolTip
            b.tag = command.tag
            return b
        }
        let menu = NSMenu()
        for c in more { menu.addItem(c.map { $0.menuItem() } ?? .separator()) }
        let moreButton = StripButton(symbol: "ellipsis.circle", toolTip: L("More"), menu: menu)
        views.append(moreButton)
        let stack = NSStackView(views: views)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 4, right: 6)
        return stack
    }

    private static func fill(_ pane: NSView, content: NSView, bar: NSView, empty: NSView) {
        let line = NSBox()
        line.boxType = .separator
        for v in [content, bar, empty, line] {
            v.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: pane.topAnchor),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: pane.safeAreaLayoutGuide.bottomAnchor),
            empty.topAnchor.constraint(equalTo: pane.topAnchor, constant: 40),
            empty.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
        ])
    }

    @objc private func switched(_ sender: NSSegmentedControl) {
        mode = Mode(rawValue: sender.selectedSegment) ?? .thumbnails
    }

    // MARK: Outline

    private var outlineRoot: PDFOutline? { pdfView.document?.outlineRoot }

    func reloadOutline(select item: PDFOutline? = nil) {
        guard isViewLoaded else { return }
        let keep = item ?? selectedBookmark
        outlineView.reloadData()
        expandOpenItems(outlineRoot)
        emptyLabel.isHidden = (outlineRoot?.numberOfChildren ?? 0) > 0
        if let keep {
            let row = outlineView.row(forItem: keep)
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false); outlineView.scrollRowToVisible(row) }
        }
    }

    private func expandOpenItems(_ item: PDFOutline?) {
        guard let item else { return }
        for i in 0..<item.numberOfChildren {
            guard let c = item.child(at: i) else { continue }
            if c.isOpen, c.numberOfChildren > 0 { outlineView.expandItem(c) }
            expandOpenItems(c)
        }
    }

    var selectedBookmark: PDFOutline? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline
    }

    var outlineHasFocus: Bool { mode == .outline && view.window?.firstResponder === outlineView }

    /// Starts renaming `item` in place.
    func beginRename(_ item: PDFOutline) {
        mode = .outline
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, let field = cell.textField else { return }
        field.isEditable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .textColor
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.isEditable = false
        field.drawsBackground = false
        let row = outlineView.row(for: field)
        guard row >= 0, let item = outlineView.item(atRow: row) as? PDFOutline else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != item.label { editor?.renameBookmark(item, to: text) } else { field.stringValue = item.label ?? "" }
        view.window?.makeFirstResponder(outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? outlineRoot)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? outlineRoot)!.child(at: index)!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PDFOutline)?.numberOfChildren ?? 0 > 0
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? PDFOutline)?.isOpen = true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        (notification.userInfo?["NSObject"] as? PDFOutline)?.isOpen = false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let outline = item as? PDFOutline
        let label = NSTextField(labelWithString: outline?.label ?? "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        if let outline, let style = editor?.pdfDoc?.extras.outlineStyles[ObjectIdentifier(outline)] {
            var traits: NSFontTraitMask = []
            if style.bold { traits.insert(.boldFontMask) }
            if style.italic { traits.insert(.italicFontMask) }
            label.font = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: traits)
            if let color = style.color { label.textColor = Self.readable(color) }
        }
        let pageLabel = NSTextField(labelWithString: "")
        if let page = outline.flatMap(OutlineTree.destination)?.page, let doc = pdfView.document {
            let i = doc.index(for: page)
            if i != NSNotFound { pageLabel.stringValue = editor?.pdfDoc?.extras.displayLabel(i) ?? "\(i + 1)" }
        }
        pageLabel.textColor = .tertiaryLabelColor
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(label)
        cell.addSubview(pageLabel)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pageLabel.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pageLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            pageLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Bookmark colours stay readable on the dark sidebar too (very dark ones are lightened).
    static func readable(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = color.usingColorSpace(.sRGB) ?? color
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return c }
            let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            return lum < 0.35 ? c.blended(withFraction: 0.45, of: .white) ?? c : c
        }
    }

    @objc private func outlineClicked() {
        guard outlineView.clickedRow >= 0, let item = outlineView.item(atRow: outlineView.clickedRow) as? PDFOutline else { return }
        if let dest = OutlineTree.destination(item) { pdfView.go(to: dest) }
        else if let action = item.action { pdfView.perform(action) }
    }

    @objc private func outlineDoubleClicked() {
        guard outlineView.clickedRow >= 0, let item = outlineView.item(atRow: outlineView.clickedRow) as? PDFOutline else { return }
        beginRename(item)
    }

    // Drag to reorder and nest.

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? PDFOutline else { return nil }
        draggedItem = item
        let p = NSPasteboardItem()
        p.setString(item.label ?? "", forType: Self.outlineType)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedItem = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let dragged = draggedItem else { return [] }
        var node = item as? PDFOutline
        while let n = node {   // not into itself or its own children
            if n === dragged { return [] }
            node = n.parent
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let dragged = draggedItem, let parent = (item as? PDFOutline) ?? outlineRoot else { return false }
        editor?.moveBookmark(dragged, to: parent, at: index < 0 ? parent.numberOfChildren : index)
        return true
    }

    // MARK: Attachments

    /// Document attachments, then files attached to pages (FileAttachment annotations).
    enum AttachmentRow {
        case document(Int)
        case annotation(PDFAnnotation, page: Int)
    }

    private(set) var attachmentRows: [AttachmentRow] = []

    func reloadAttachments() {
        guard isViewLoaded else { return }
        var rows: [AttachmentRow] = []
        if let extras = editor?.pdfDoc?.extras { rows += extras.files.indices.map { .document($0) } }
        if let doc = pdfView.document {
            for i in 0..<doc.pageCount {
                for a in doc.page(at: i)?.annotations ?? [] where a.kind == "FileAttachment" { rows.append(.annotation(a, page: i)) }
            }
        }
        attachmentRows = rows
        attachmentTable.reloadData()
        attachmentEmpty.isHidden = !rows.isEmpty
    }

    var selectedAttachment: AttachmentRow? {
        let r = attachmentTable.clickedRow >= 0 ? attachmentTable.clickedRow : attachmentTable.selectedRow
        return r >= 0 && r < attachmentRows.count ? attachmentRows[r] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { attachmentRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let info = editor?.attachmentInfo(attachmentRows[row]) else { return nil }
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: (info.name as NSString).pathExtension) ?? .data))
        let name = NSTextField(labelWithString: info.name)
        name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: info.detail)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let stack = NSStackView(views: [icon, texts])
        stack.spacing = 6
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let cell = NSTableCellView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView !== tableView else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        editor?.addAttachments(urls)
        return true
    }

    /// Dragging an attachment out writes it as a file (promise).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let info = editor?.attachmentInfo(attachmentRows[row]) else { return nil }
        let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: (info.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier,
                                             delegate: promiseDelegate)
        provider.userInfo = info
        return provider
    }

    private lazy var promiseDelegate = AttachmentPromise()

    @objc private func attachmentDoubleClicked() {
        guard attachmentTable.clickedRow >= 0 else { return }
        editor?.openAttachmentAction(nil)
    }
}

extension SidebarViewController: NSMenuDelegate {
    /// Context menu of the outline: the bookmark commands, for the clicked row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        var items: [Command?] = [Cmd.addBookmark, Cmd.addChildBookmark]
        if row >= 0 { items += [Cmd.renameBookmark, Cmd.setBookmarkDestination, Cmd.deleteBookmark, nil, Cmd.outdentBookmark, Cmd.indentBookmark, nil] + Cmd.bookmarkStyles.map { $0 } }
        items += [nil, Cmd.bookmarksFromHeadings]
        for c in items { menu.addItem(c.map { $0.menuItem() } ?? .separator()) }
    }
}

/// Outline list: Delete removes the selected bookmark, Return renames it.
final class OutlineListView: NSOutlineView {
    weak var sidebar: SidebarViewController?

    override func keyDown(with event: NSEvent) {
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            if scalar.value == 127 || Int(scalar.value) == NSDeleteFunctionKey {
                sidebar?.editor?.deleteBookmarkAction(nil)
                return
            }
            if scalar.value == 13, let item = sidebar?.selectedBookmark {
                sidebar?.beginRename(item)
                return
            }
        }
        super.keyDown(with: event)
    }
}

/// Attachment list: Delete removes the selected attachment.
final class AttachmentTableView: NSTableView {
    weak var sidebar: SidebarViewController?

    override func keyDown(with event: NSEvent) {
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first, scalar.value == 127 || Int(scalar.value) == NSDeleteFunctionKey {
            sidebar?.editor?.deleteAttachmentAction(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Name, details and bytes of an attachment row.
final class AttachmentInfo: NSObject {
    let name: String
    let detail: String
    let data: Data
    init(name: String, detail: String, data: Data) {
        self.name = name
        self.detail = detail
        self.data = data
    }
}

final class AttachmentPromise: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        AttachmentExport.fileName((provider.userInfo as? AttachmentInfo)?.name ?? L("Attachment"))
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try (provider.userInfo as? AttachmentInfo)?.data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}
