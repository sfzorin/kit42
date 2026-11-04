import AppKit
import Kit42

/// Side panel on the right of the pages, like Writer's sidebar: Styles (⌘T) and Navigator (F5).
final class DocSidebar: NSView {
    enum Page: Int { case styles, navigator }
    static let width: CGFloat = 260

    let switcher = NSSegmentedControl(labels: [L("Styles"), L("Navigator")], trackingMode: .selectOne, target: nil, action: nil)
    let styles: StylesPanel
    let navigator: NavigatorPanel
    private(set) var page: Page = .styles

    init(editor: DocWindowController) {
        styles = StylesPanel(editor: editor)
        navigator = NavigatorPanel(editor: editor)
        super.init(frame: .zero)
        switcher.target = self
        switcher.action = #selector(switched(_:))
        switcher.selectedSegment = 0
        switcher.segmentStyle = .automatic
        switcher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(switcher)
        for v in [styles, navigator] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8),
                v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            switcher.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        show(.styles)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    func show(_ p: Page) {
        page = p
        switcher.selectedSegment = p.rawValue
        styles.isHidden = p != .styles
        navigator.isHidden = p != .navigator
        if p == .navigator { navigator.reload() } else { styles.reload() }
    }

    @objc private func switched(_ sender: NSSegmentedControl) { show(Page(rawValue: sender.selectedSegment) ?? .styles) }
}

// MARK: - Styles panel

final class StylesPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private weak var editor: DocWindowController?
    let kind = NSSegmentedControl(labels: [L("Paragraph"), L("Character")], trackingMode: .selectOne, target: nil, action: nil)
    let table = NSTableView()
    private var rows: [DocStyle] = []

    init(editor: DocWindowController) {
        self.editor = editor
        super.init(frame: .zero)
        kind.selectedSegment = 0
        kind.controlSize = .small
        kind.target = self
        kind.action = #selector(kindChanged(_:))
        let column = NSTableColumn(identifier: .init("style"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.doubleAction = #selector(modifyAction(_:))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: Theme42.symbol(symbol) ?? NSImage(), target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        let buttons = NSStackView(views: [
            button("plus", L("New Style from Selection"), #selector(newAction(_:))),
            button("arrow.triangle.2.circlepath", L("Update Style to Match Selection"), #selector(updateAction(_:))),
            button("slider.horizontal.3", L("Modify Style…"), #selector(modifyAction(_:))),
            button("minus", L("Delete Style"), #selector(deleteAction(_:))),
        ])
        buttons.spacing = 4
        for v in [kind, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            kind.topAnchor.constraint(equalTo: topAnchor),
            kind.centerXAnchor.constraint(equalTo: centerXAnchor),
            scroll.topAnchor.constraint(equalTo: kind.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var showsCharacter: Bool { kind.selectedSegment == 1 }

    func reload() {
        guard let sheet = editor?.doc?.styles else { return }
        let list = showsCharacter ? sheet.characterStyles : sheet.paragraphStyles.filter { !$0.hidden }
        let order = StyleSheet.builtins.map(\.id)
        rows = list.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            return ia != ib ? ia < ib : a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
        }
        table.reloadData()
        syncSelection()
    }

    /// Highlights the style at the cursor.
    func syncSelection() {
        guard let editor, !isHidden else { return }
        let a = editor.currentAttributes
        let id = showsCharacter ? a[.docCharStyle] as? String : (a[Styles.styleKey] as? String ?? "Normal")
        if let i = rows.firstIndex(where: { $0.id == id }) {
            if table.selectedRow != i { table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i) }
        } else {
            table.deselectAll(nil)
        }
    }

    @objc private func kindChanged(_ sender: Any?) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = rows[row]
        let field = NSTextField(labelWithString: "")
        let r = editor?.doc?.styles.resolved(s.id) ?? s
        let size = min(16, max(10, r.size ?? 12))
        var font = StyleSheet.font(family: r.family, size: size, weight: r.weight ?? 5, italic: r.italic ?? false)
        if s.kind == .character, let p = editor?.doc?.styles.resolved("Normal") {
            font = StyleSheet.font(family: s.family ?? p.family, size: size, weight: s.weight ?? 5, italic: s.italic ?? false)
        }
        field.stringValue = s.displayName
        field.font = font
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = s.basedOn.map { L("Based on: %@", editor?.doc?.styles[$0]?.displayName ?? $0) }
        return field
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, let editor else { return }
        if showsCharacter { editor.applyCharacterStyle(rows[row].id) } else { editor.applyParagraphStyle(rows[row].id) }
    }

    private var targetRow: Int { table.clickedRow >= 0 ? table.clickedRow : table.selectedRow }

    @objc func newAction(_ sender: Any?) { editor?.newStyleFromSelection(character: showsCharacter) }
    @objc func updateAction(_ sender: Any?) {
        let row = targetRow
        guard row >= 0, row < rows.count else { NSSound.beep(); return }
        editor?.updateStyleToMatchSelection(rows[row].id)
    }
    @objc func modifyAction(_ sender: Any?) {
        let row = targetRow
        guard row >= 0, row < rows.count else { NSSound.beep(); return }
        editor?.modifyStyle(rows[row].id)
    }
    @objc func deleteAction(_ sender: Any?) {
        let row = targetRow
        guard row >= 0, row < rows.count, !rows[row].builtin else { NSSound.beep(); return }
        editor?.deleteStyle(rows[row].id)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0 else { return }
        menu.addItem(withTitle: L("Modify Style…"), action: #selector(modifyAction(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Update Style to Match Selection"), action: #selector(updateAction(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("New Style from Selection"), action: #selector(newAction(_:)), keyEquivalent: "").target = self
        if !rows[table.clickedRow].builtin {
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Delete Style"), action: #selector(deleteAction(_:)), keyEquivalent: "").target = self
        }
    }
}

// MARK: - Navigator

final class NavItem: NSObject {
    enum Kind { case group, heading, table, image, bookmark, comment, footnote, link, section, field }
    let kind: Kind
    let title: String
    let range: NSRange
    var children: [NavItem] = []
    var level = 0
    init(_ kind: Kind, _ title: String, _ range: NSRange = NSRange(location: NSNotFound, length: 0)) {
        self.kind = kind
        self.title = title
        self.range = range
    }
}

final class NavigatorPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private weak var editor: DocWindowController?
    let outline = NSOutlineView()
    private(set) var groups: [NavItem] = []
    private var expandedGroups = Set<String>()
    static let dragType = NSPasteboard.PasteboardType("com.sfzorin.doc42.chapter")

    init(editor: DocWindowController) {
        self.editor = editor
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("item"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        expandedGroups = [L("Headings")]
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var reloadScheduled = false
    func scheduleReload() {
        guard !isHidden, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        guard let editor, let storage = editor.textView.textStorage else { return }
        for g in groups where outline.isItemExpanded(g) { expandedGroups.insert(g.title) }
        for g in groups where !outline.isItemExpanded(g) && outline.row(forItem: g) >= 0 { expandedGroups.remove(g.title) }
        groups = Self.items(storage, sheet: editor.doc?.styles)
        outline.reloadData()
        for g in groups where expandedGroups.contains(g.title) { outline.expandItem(g, expandChildren: g.title == L("Headings")) }
    }

    /// Navigator contents of a document (also used by --dump).
    static func items(_ storage: NSAttributedString, sheet: StyleSheet?) -> [NavItem] {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: storage.length)
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Headings as a tree by level.
        let headings = NavItem(.group, L("Headings"))
        var stack: [NavItem] = []
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            guard r.length > 0, let id = storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String,
                  !TOC.isTOCStyle(id) else { return }
            let level: Int
            if id == "Title" { level = 0 } else if let l = sheet?.resolved(id).outlineLevel ?? (id.hasPrefix("Heading") ? Int(id.dropFirst(7)).map { $0 - 1 } : nil) {
                level = l + 1
            } else { return }
            let title = clean(ns.substring(with: r))
            guard !title.isEmpty else { return }
            let item = NavItem(.heading, title, r)
            item.level = level
            while let last = stack.last, last.level >= level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(item) } else { headings.children.append(item) }
            stack.append(item)
        }
        let tables = NavItem(.group, L("Tables")), images = NavItem(.group, L("Images")), bookmarks = NavItem(.group, L("Bookmarks"))
        let comments = NavItem(.group, L("Comments")), notes = NavItem(.group, L("Footnotes")), links = NavItem(.group, L("Links"))
        let sections = NavItem(.group, L("Sections")), fields = NavItem(.group, L("Fields"))
        var lastTable: NSTextTable?
        storage.enumerateAttribute(.paragraphStyle, in: full) { v, r, _ in
            guard let t = ((v as? NSParagraphStyle)?.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock)?.table else { lastTable = nil; return }
            if t !== lastTable {
                tables.children.append(NavItem(.table, L("Table %d", tables.children.count + 1), NSRange(location: r.location, length: 0)))
                lastTable = t
            }
        }
        storage.enumerateAttribute(.attachment, in: full) { v, r, _ in
            guard v is NSTextAttachment, storage.attribute(.docNote, at: r.location, effectiveRange: nil) == nil,
                  storage.attribute(.docField, at: r.location, effectiveRange: nil) == nil else { return }
            images.children.append(NavItem(.image, L("Image %d", images.children.count + 1), r))
        }
        storage.enumerateAttribute(.docBookmark, in: full) { v, r, _ in
            if let name = v as? String { bookmarks.children.append(NavItem(.bookmark, name, NSRange(location: r.location, length: 0))) }
        }
        for (r, c) in CLI.commentsOf(storage) {
            comments.children.append(NavItem(.comment, "\(c.author): " + (c.text.isEmpty ? clean(ns.substring(with: r)) : c.text), r))
        }
        for (k, (r, n)) in Notes.all(in: storage).enumerated() { notes.children.append(NavItem(.footnote, "\(k + 1). \(n.text)", r)) }
        storage.enumerateAttribute(.link, in: full) { v, r, _ in
            guard let v else { return }
            let target = (v as? URL)?.absoluteString ?? "\(v)"
            let text = clean(ns.substring(with: r))
            links.children.append(NavItem(.link, text.isEmpty ? target : "\(text) → \(target)", r))
        }
        var start = 0
        var n = 0
        storage.enumerateAttribute(.docSection, in: full) { v, r, _ in
            guard let s = v as? DocSection else { return }
            n += 1
            sections.children.append(NavItem(.section, L("Section %d", n) + " (\(Int(s.pageSize.width))×\(Int(s.pageSize.height)), \(s.columns))", NSRange(location: start, length: 0)))
            start = NSMaxRange(r)
        }
        if n > 0 { sections.children.append(NavItem(.section, L("Section %d", n + 1), NSRange(location: start, length: 0))) }
        storage.enumerateAttribute(.docField, in: full) { v, r, _ in
            if let f = v as? DocField { fields.children.append(NavItem(.field, f.displayName, r)) }
        }
        return [headings, tables, images, bookmarks, comments, notes, links, sections, fields]
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? NavItem)?.children.count ?? groups.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? NavItem)?.children[index] ?? groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? NavItem)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NavItem else { return nil }
        let field = NSTextField(labelWithString: item.kind == .group ? "\(item.title) (\(item.children.count))" : item.title)
        field.lineBreakMode = .byTruncatingTail
        field.font = item.kind == .group ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        field.textColor = item.kind == .group && item.children.isEmpty ? .secondaryLabelColor : .labelColor
        return field
    }

    @objc private func clicked(_ sender: Any?) {
        guard let item = outline.item(atRow: outline.clickedRow) as? NavItem, item.range.location != NSNotFound else { return }
        editor?.jump(to: item.range)
    }

    // Drag a heading to move its chapter (the heading with everything up to the next heading of its level or higher).

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? NavItem, item.kind == .heading else { return nil }
        let p = NSPasteboardItem()
        p.setString("\(item.range.location)", forType: Self.dragType)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outline, index >= 0 else { return [] }
        let parent = item as? NavItem
        guard parent == nil ? false : (parent!.kind == .heading || parent!.title == L("Headings")) else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let s = info.draggingPasteboard.string(forType: Self.dragType), let from = Int(s), let parent = item as? NavItem, let editor else { return false }
        // Destination: before the heading at `index` of `parent`, or after the parent's last child chapter.
        let to: Int
        if index < parent.children.count {
            to = parent.children[index].range.location
        } else if parent.kind == .heading {
            to = editor.chapterRange(at: parent.range.location).map { NSMaxRange($0) } ?? NSMaxRange(parent.range)
        } else {
            to = editor.textView.textStorage?.length ?? 0
        }
        return editor.moveChapter(from: from, to: to)
    }
}

extension DocWindowController {
    /// Selects a range from the navigator and scrolls to it.
    func jump(to range: NSRange) {
        guard let storage = textView.textStorage else { return }
        let r = NSRange(location: min(range.location, storage.length), length: min(range.length, storage.length - min(range.location, storage.length)))
        window?.makeFirstResponder(paged.textView(at: r.location) ?? textView)
        textView.setSelectedRange(r.length > 0 && r.length < 400 ? r : NSRange(location: r.location, length: 0))
        paged.scrollRangeToVisible(NSRange(location: r.location, length: min(r.length, 1)))
    }

    /// The chapter that starts with the heading at `location`: up to the next heading of the same or a higher level.
    func chapterRange(at location: Int) -> NSRange? {
        guard let storage = textView.textStorage, let sheet = doc?.styles else { return nil }
        func level(_ at: Int) -> Int? {
            guard at < storage.length, let id = storage.attribute(Styles.styleKey, at: at, effectiveRange: nil) as? String, !TOC.isTOCStyle(id) else { return nil }
            if id == "Title" { return 0 }
            return (sheet.resolved(id).outlineLevel ?? (id.hasPrefix("Heading") ? Int(id.dropFirst(7)).map { $0 - 1 } : nil)).map { $0 + 1 }
        }
        guard let mine = level(location) else { return nil }
        let ns = storage.string as NSString
        var end = NSMaxRange(ns.paragraphRange(for: NSRange(location: location, length: 0)))
        while end < storage.length {
            if let l = level(end), l <= mine { break }
            end = NSMaxRange(ns.paragraphRange(for: NSRange(location: end, length: 0)))
        }
        return NSRange(location: location, length: end - location)
    }

    /// Moves the chapter starting at `from` to `to` (a paragraph start outside it). Undoable.
    @discardableResult
    func moveChapter(from: Int, to: Int) -> Bool {
        guard let storage = textView.textStorage, let chapter = chapterRange(at: from),
              to <= chapter.location || to >= NSMaxRange(chapter) else { return false }
        let text = storage.attributedSubstring(from: chapter)
        let lo = min(chapter.location, to), hi = max(NSMaxRange(chapter), to)
        let span = NSRange(location: lo, length: hi - lo)
        let out = NSMutableAttributedString()
        if to <= chapter.location {
            out.append(text)
            out.append(storage.attributedSubstring(from: NSRange(location: to, length: chapter.location - to)))
        } else {
            out.append(storage.attributedSubstring(from: NSRange(location: NSMaxRange(chapter), length: to - NSMaxRange(chapter))))
            out.append(text)
        }
        // The last paragraph of the document may lack its newline.
        guard textView.shouldChangeText(in: span, replacementString: out.string) else { return false }
        storage.replaceCharacters(in: span, with: out)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Move Chapter"))
        let newStart = to <= chapter.location ? to : to - chapter.length
        textView.setSelectedRange(NSRange(location: newStart, length: 0))
        sidebar.navigator.reload()
        return true
    }
}
