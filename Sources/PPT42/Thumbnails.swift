import AppKit
import Kit42

/// Cached slide pictures; reused while the slide (and the deck's look) are unchanged.
final class ThumbnailCache {
    private var cache: [UUID: (slide: Slide, look: Int, width: Int, image: NSImage)] = [:]

    static func look(_ d: Deck) -> Int {
        var h = Hasher()
        h.combine(d.theme.name)
        h.combine(d.theme.colors.values.sorted())
        h.combine(d.theme.majorFont)
        h.combine(d.theme.minorFont)
        h.combine(d.size.width)
        h.combine(d.size.height)
        h.combine(String(describing: d.master.background))
        h.combine(d.master.objects.count)
        h.combine(String(describing: d.master.titleStyle).hashValue)
        h.combine(String(describing: d.master.bodyStyle).hashValue)
        h.combine(d.layouts.count)
        return h.finalize()
    }

    func image(_ slide: Slide, index: Int, deck: Deck, width: Int) -> NSImage {
        let look = Self.look(deck)
        if let c = cache[slide.uid], c.slide == slide, c.look == look, c.width == width { return c.image }
        var o = RenderOptions()
        o.number = Renderer.number(of: index, deck: deck)
        let img = Renderer.nsImage(slide, deck: deck, pixelWidth: width, options: o)
        cache[slide.uid] = (slide, look, width, img)
        return img
    }

    func clear() { cache = [:] }
}

final class ThumbnailRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class ThumbnailCell: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var number = 1 { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var slideHidden = false { didSet { needsDisplay = true } }
    var hasTransition = false
    var aspect: CGFloat = 16.0 / 9

    override var isFlipped: Bool { true }

    var slideRect: CGRect {
        let left: CGFloat = 30, right: CGFloat = 12
        let w = bounds.width - left - right
        return CGRect(x: left, y: 6, width: w, height: w / aspect).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = slideRect
        let num = NSAttributedString(string: "\(number)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: isCurrent ? .semibold : .regular),
                                                                       .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor])
        num.draw(at: CGPoint(x: r.minX - 8 - num.size().width, y: r.minY))
        if slideHidden, let eye = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) {
            let tinted = NSImage(size: eye.size, flipped: false) { b in eye.draw(in: b); NSColor.secondaryLabelColor.set(); b.fill(using: .sourceAtop); return true }
            tinted.draw(in: CGRect(x: r.minX - 8 - eye.size.width, y: r.minY + 16, width: eye.size.width, height: eye.size.height))
        }
        if hasTransition, let t = NSImage(systemSymbolName: "rectangle.righthalf.inset.filled.arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) {
            let tinted = NSImage(size: t.size, flipped: false) { b in t.draw(in: b); NSColor.tertiaryLabelColor.set(); b.fill(using: .sourceAtop); return true }
            tinted.draw(in: CGRect(x: r.minX - 8 - t.size.width, y: r.maxY - t.size.height, width: t.size.width, height: t.size.height))
        }
        if selected {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3.5, dy: -3.5), xRadius: 4, yRadius: 4)
            ring.lineWidth = 3
            (isCurrent ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.5)).setStroke()
            ring.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.set()
        NSColor.white.setFill()
        r.fill()
        NSGraphicsContext.restoreGraphicsState()
        image?.draw(in: r, from: .zero, operation: .sourceOver, fraction: slideHidden ? 0.45 : 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)).stroke()
    }
}

/// Sidebar: slide thumbnails (select, multi-select, drag to reorder, context menu).
final class ThumbnailsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var owner: DeckWindowController?
    let table = ThumbnailTable()
    let cache = ThumbnailCache()
    private var syncing = false
    static let rowType = NSPasteboard.PasteboardType("com.sfzorin.ppt42.slide-rows")

    init(owner: DeckWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        if table.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: .init("slide"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.owner = owner
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        view = effect
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.noteHeightOfRows(withIndexesChanged: IndexSet(0..<self.table.numberOfRows))
        }
    }

    var deck: Deck { owner?.deck ?? Deck.makeDefault() }

    func reload() {
        guard isViewLoaded else { return }
        table.reloadData()
        syncSelection()
    }

    /// Redraws only the slides that changed.
    func deckChanged(from old: Deck) {
        guard isViewLoaded else { return }
        if old.slides.count != deck.slides.count || old.slides.map(\.uid) != deck.slides.map(\.uid) || ThumbnailCache.look(old) != ThumbnailCache.look(deck) {
            table.reloadData()
        } else {
            let changed = IndexSet(deck.slides.indices.filter { deck.slides[$0] != old.slides[$0] })
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
        }
        syncSelection()
    }

    func syncSelection() {
        guard isViewLoaded, let owner else { return }
        syncing = true
        table.selectRowIndexes(owner.slideSelection.filteredIndexSet { $0 < table.numberOfRows }, byExtendingSelection: false)
        if owner.current < table.numberOfRows { table.scrollRowToVisible(owner.current) }
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCell else { continue }
            cell.selected = owner.slideSelection.contains(row)
            cell.isCurrent = row == owner.current
        }
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { deck.slides.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let w = max(60, table.bounds.width - 42)
        return w * deck.size.height / deck.size.width + 12
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThumbnailRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("thumb"), owner: nil) as? ThumbnailCell) ?? ThumbnailCell()
        cell.identifier = .init("thumb")
        guard deck.slides.indices.contains(row) else { return cell }
        let s = deck.slides[row]
        cell.aspect = deck.size.width / deck.size.height
        cell.number = Renderer.number(of: row, deck: deck)
        cell.slideHidden = s.hidden
        cell.hasTransition = s.transition.kind != .none
        let scale = view.window?.backingScaleFactor ?? 2
        cell.image = cache.image(s, index: row, deck: deck, width: Int(max(160, (table.bounds.width - 42) * scale).rounded()))
        cell.selected = owner?.slideSelection.contains(row) ?? false
        cell.isCurrent = row == owner?.current
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let owner else { return }
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { syncSelection(); return }
        let clicked = table.clickedRow >= 0 && rows.contains(table.clickedRow) ? table.clickedRow : (rows.contains(owner.current) ? owner.current : rows.first!)
        if clicked != owner.current || rows.count == 1 { owner.select(slide: clicked) }
        owner.slideSelection = rows
        syncSelection()
    }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }
        guard !rows.isEmpty, let owner else { return false }
        owner.moveSlides(rows, to: row)
        return true
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if table.clickedRow >= 0, owner?.slideSelection.contains(table.clickedRow) == false { owner?.select(slide: table.clickedRow) }
        for c in [Cmd.newSlide, Cmd.duplicateSlide, Cmd.deleteSlide] { menu.addItem(c.menuItem()) }
        menu.addItem(.separator())
        menu.addItem(Cmd.hideSlide.menuItem())
        let layouts = NSMenuItem(title: L("Layout"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, l) in deck.layouts.enumerated() {
            let item = NSMenuItem(title: Themes.displayName(l), action: #selector(DeckWindowController.layoutAction(_:)), keyEquivalent: "")
            item.tag = i
            item.image = LayoutIcons.icon(l, deck: deck, width: 32)
            sub.addItem(item)
        }
        layouts.submenu = sub
        menu.addItem(layouts)
        let trans = NSMenuItem(title: L("Transition"), action: nil, keyEquivalent: "")
        trans.submenu = MenuBar.menu(L("Transition"), Cmd.transitions.menuElements)
        menu.addItem(trans)
    }
}

/// The thumbnail list: ⌫ deletes slides, ⌘C/⌘V copy slides.
final class ThumbnailTable: NSTableView {
    weak var owner: DeckWindowController?

    override func keyDown(with event: NSEvent) {
        if let c = event.charactersIgnoringModifiers?.unicodeScalars.first, [NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey].contains(Int(c.value)) {
            owner?.deleteSlideAction(nil)
            return
        }
        if event.keyCode == 36 { owner?.addSlide(layout: owner?.defaultNewLayout ?? 1); return }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { owner?.copySlides() }
    @objc func cut(_ sender: Any?) { owner?.copySlides(); owner?.deleteSlideAction(nil) }
    @objc func paste(_ sender: Any?) { owner?.pasteObjects() }
    @objc func delete(_ sender: Any?) { owner?.deleteSlideAction(nil) }
}
