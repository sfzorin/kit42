import AppKit
import Kit42

enum ViewMode: Int {
    case normal, outline, sorter, notesPage, master
}

final class DeckWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSSplitViewDelegate {
    var doc: PresentationDocument? { document as? PresentationDocument }
    var deck: Deck { doc?.deck ?? Deck.makeDefault() }

    /// Current slide (index) and selected object ids on it.
    var current = 0
    var selection: [Int] = [] { didSet { if selection != oldValue { selectionChanged() } } }
    private(set) var mode: ViewMode = .normal
    /// Slides selected in the sidebar / sorter (always contains `current`).
    var slideSelection: IndexSet = [0]
    var snapToGuides = true

    let splitController = NSSplitViewController()
    private(set) lazy var thumbnails = ThumbnailsController(owner: self)
    private(set) lazy var inspector = InspectorController(owner: self)
    let canvas = SlideCanvas()
    let canvasScroll = NSScrollView()
    let notesView = NotesTextView()
    private let notesScroll = NSScrollView()
    let contentSplit = NSSplitView()
    let contentBox = NSView()
    private(set) lazy var sorter = SorterView(owner: self)
    private let sorterScroll = NSScrollView()
    private(set) lazy var outline = OutlineEditor(owner: self)
    private let outlineScroll = NSScrollView()
    private(set) lazy var notesPage = NotesPageView(owner: self)
    private let notesPageScroll = NSScrollView()
    let banner = BannerView()
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var notesCollapsedBeforeHide = false
    lazy var finder = FindController(owner: self)
    lazy var formatBar = FormatBar(owner: self)
    private let toolbarController: ToolbarController

    init() {
        let shapeButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 48, height: 28), pullsDown: true)
        let newSlideButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 48, height: 28), pullsDown: true)
        toolbarController = ToolbarController(identifier: "PPT42.toolbar", elements: [
            .toggleSidebar, .sidebarSeparator,
            .view(id: "newSlide", label: L("New Slide"), newSlideButton),
            .command(Cmd.textBox),
            .view(id: "shape", label: L("Shape"), shapeButton),
            .command(Cmd.image), .command(Cmd.table),
            .flexibleSpace,
            .command(Cmd.play),
            .command(Cmd.formatBar),
            .command(Cmd.inspector),
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 820, height: 520)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        configurePopups(shape: shapeButton, newSlide: newSlideButton)
        setupContent()
        window.toolbar = toolbarController.toolbar
        window.addTitlebarAccessoryViewController(formatBar.strip)
        window.setFrameAutosaveName("PPT42.window")
        if window.frame.width < 900 { window.setContentSize(NSSize(width: 1280, height: 820)); window.center() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var document: AnyObject? {
        didSet {
            guard let doc else { return }
            doc.onChange = { [weak self] old in self?.deckChanged(from: old) }
            doc.currentState = { [weak self] in EditState(slide: self?.current ?? 0, selection: self?.selection ?? []) }
            doc.restoreState = { [weak self] s in self?.restore(s) }
            current = 0
            slideSelection = [0]
            reloadAll()
            updateBanner()
        }
    }

    // MARK: - Layout

    private func configurePopups(shape: NSPopUpButton, newSlide: NSPopUpButton) {
        func style(_ b: NSPopUpButton, symbol: String, tip: String) {
            b.bezelStyle = .toolbar
            b.imagePosition = .imageOnly
            (b.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            b.toolTip = tip
            let first = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            first.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.menu?.addItem(first)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        style(shape, symbol: "square.on.circle", tip: L("Insert a shape"))
        for (i, p) in Shapes.gallery.enumerated() {
            let item = NSMenuItem(title: p.name, action: #selector(insertShapeAction(_:)), keyEquivalent: "")
            item.tag = i
            item.image = Shapes.icon(p.prst)
            shape.menu?.addItem(item)
        }
        style(newSlide, symbol: "plus.rectangle.on.rectangle", tip: L("Add a slide (choose a layout)"))
        newSlide.menu?.delegate = self
        newSlide.menu?.identifier = NSUserInterfaceItemIdentifier("toolbarNewSlide")
    }

    private func setupContent() {
        // Canvas in a scroll view (zoom), notes under it.
        canvas.owner = self
        canvasScroll.documentView = canvas
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.drawsBackground = true
        canvasScroll.backgroundColor = .underPageBackgroundColor
        canvasScroll.contentView.postsBoundsChangedNotifications = true
        notesView.owner = self
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true
        notesScroll.drawsBackground = true
        notesView.minSize = NSSize(width: 0, height: 0)
        notesView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        notesView.isVerticallyResizable = true
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.widthTracksTextView = true
        contentSplit.isVertical = false
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        contentSplit.addArrangedSubview(canvasScroll)
        contentSplit.addArrangedSubview(notesScroll)
        contentSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        contentSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        contentSplit.autosaveName = "PPT42.notesSplit"

        for (scroll, view) in [(sorterScroll, sorter as NSView), (outlineScroll, outline as NSView), (notesPageScroll, notesPage as NSView)] {
            scroll.documentView = view
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = true
            scroll.backgroundColor = .underPageBackgroundColor
        }
        outlineScroll.backgroundColor = .textBackgroundColor
        outline.configure(in: outlineScroll)

        banner.isHidden = true
        let stack = NSStackView(views: [banner, contentBox])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        banner.heightAnchor.constraint(equalToConstant: Theme42.bannerHeight).isActive = true
        let content = NSViewController()
        content.view = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        contentBox.translatesAutoresizingMaskIntoConstraints = false
        contentBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        install(contentSplit)

        sidebarItem = NSSplitViewItem(sidebarWithViewController: thumbnails)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let main = NSSplitViewItem(viewController: content)
        main.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 250
        inspectorItem.maximumThickness = 340
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        splitController.splitViewItems = [sidebarItem, main, inspectorItem]
        splitController.splitView.autosaveName = "PPT42.split"
        window?.contentViewController = splitController
        sidebarItem.preferredThicknessFraction = 0.15
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.layoutIfNeeded()
        setNotesHeight(120)
        if let split = splitController.splitView as NSSplitView?, sidebarItem.viewController.view.frame.width < 170 {
            split.setPosition(190, ofDividerAt: 0)
        }
    }

    /// Notes pane height on open (unless the saved split is reasonable).
    func setNotesHeight(_ h: CGFloat) {
        contentSplit.layoutSubtreeIfNeeded()
        let total = contentSplit.bounds.height
        guard total > 200, !contentSplit.isSubviewCollapsed(notesScroll) else { return }
        if notesScroll.frame.height < 40 || notesScroll.frame.height > total * 0.35 { contentSplit.setPosition(total - h, ofDividerAt: 0) }
    }

    private func install(_ view: NSView) {
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        contentBox.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor), view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentBox.topAnchor), view.bottomAnchor.constraint(equalTo: contentBox.bottomAnchor),
        ])
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === notesScroll }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 40)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    // MARK: - State

    var currentSlide: Slide? { deck.slides.indices.contains(current) ? deck.slides[current] : nil }

    /// The slide shown in the canvas: the real one, or the master sample in master view.
    var displayedSlide: Slide {
        if mode == .master { return MasterView.sampleSlide(deck: deck, layout: nil) }
        return currentSlide ?? Slide(layout: 0)
    }

    var selectedObjects: [SlideObject] {
        let s = displayedSlide
        return selection.compactMap { id in s.objects.first { $0.id == id } }
    }

    func select(slide index: Int, extend: Bool = false) {
        commitEditing()
        doc?.endSilentEdit()
        let n = deck.slides.count
        guard n > 0 else { current = 0; return }
        let i = min(max(0, index), n - 1)
        if i != current { selection = [] }
        current = i
        if !extend { slideSelection = [i] } else { slideSelection.insert(i) }
        thumbnails.syncSelection()
        sorter.needsDisplay = true
        canvas.slideChanged()
        notesView.load()
        notesPage.reload()
        inspector.reload()
        updateTitle()
    }

    private func restore(_ s: EditState) {
        current = min(max(0, s.slide), max(0, deck.slides.count - 1))
        slideSelection = [current]
        selection = s.selection.filter { id in displayedSlide.object(id) != nil }
        thumbnails.syncSelection()
        canvas.slideChanged()
        notesView.load()
    }

    private func selectionChanged() {
        canvas.needsDisplay = true
        inspector.reload()
        formatBar.sync()
    }

    /// Commits the text being edited (before saving, switching slides…).
    func commitEditing() {
        canvas.editor.end()
    }

    private func deckChanged(from old: Deck) {
        if current >= deck.slides.count { current = max(0, deck.slides.count - 1) }
        slideSelection = slideSelection.filteredIndexSet { $0 < deck.slides.count }
        if slideSelection.isEmpty { slideSelection = [current] }
        selection = selection.filter { displayedSlide.object($0) != nil }
        thumbnails.deckChanged(from: old)
        canvas.deckChanged()
        sorter.deckChanged()
        notesPage.reload()
        if !notesView.isEditing { notesView.load() }
        if mode == .outline, !outline.isEditing { outline.reload() }
        inspector.reload()
        formatBar.sync()
        updateTitle()
    }

    private func reloadAll() {
        thumbnails.reload()
        canvas.slideChanged()
        sorter.deckChanged()
        notesView.load()
        outline.reload()
        notesPage.reload()
        inspector.reload()
        formatBar.sync()
        updateTitle()
    }

    func updateTitle() {
        let n = deck.slides.count
        var sub = n == 0 ? L("No slides") : L("Slide %d of %d", current + 1, n)
        switch mode {
        case .master: sub = L("Master")
        case .outline: sub = L("Outline") + " · " + sub
        case .sorter: sub = L("Slide Sorter") + " · " + sub
        case .notesPage: sub = L("Notes Page") + " · " + sub
        case .normal: if currentSlide?.hidden == true { sub += " · " + L("Hidden") }
        }
        window?.subtitle = sub
    }

    private func updateBanner() {
        let lost = deck.slides.flatMap { $0.objects }.contains { $0.unsupported != nil }
        if lost {
            banner.show(.warning, L("Some objects (charts, SmartArt) are shown as placeholders and are not saved."))
        } else {
            banner.hide()
        }
    }

    // MARK: - Mode

    func setMode(_ m: ViewMode) {
        commitEditing()
        if mode == .outline { outline.apply() }
        doc?.endSilentEdit()
        mode = m
        selection = []
        switch m {
        case .normal, .master: install(contentSplit)
        case .outline:
            install(outlineScroll)
            outline.reload()
            window?.makeFirstResponder(outline)
        case .sorter:
            install(sorterScroll)
            sorter.deckChanged()
            window?.makeFirstResponder(sorter)
        case .notesPage:
            install(notesPageScroll)
            notesPage.reload()
        }
        canvas.slideChanged()
        if m == .normal || m == .master { window?.makeFirstResponder(canvas) }
        inspector.reload()
        updateTitle()
    }

    // MARK: - Panels

    var notesShown: Bool { !contentSplit.isSubviewCollapsed(notesScroll) }

    func setNotesShown(_ shown: Bool) {
        if shown {
            notesScroll.isHidden = false
            contentSplit.setPosition(contentSplit.bounds.height - 110, ofDividerAt: 0)
        } else {
            contentSplit.setPosition(contentSplit.bounds.height, ofDividerAt: 0)
        }
        contentSplit.adjustSubviews()
    }

    var inspectorShown: Bool { !inspectorItem.isCollapsed }

    func showInspector(_ show: Bool, tab: Int? = nil) {
        if let tab { inspector.select(tab: tab) }
        if inspectorItem.isCollapsed == show { inspectorItem.animator().isCollapsed = !show }
        inspector.reload()
    }

    @objc func toggleAllPanelsAction(_ sender: Any?) {
        Panels.toggleAll(in: window) { [self] hide in
            if hide {
                notesCollapsedBeforeHide = !notesShown
                if notesShown { setNotesShown(false) }
            } else if !notesCollapsedBeforeHide {
                setNotesShown(true)
            }
        }
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        Panels.fullScreenOptions
    }

    func windowWillClose(_ notification: Notification) {
        if SlideShowController.current?.owner === self { SlideShowController.current?.end() }
    }

    func windowDidResignKey(_ notification: Notification) {
        doc?.endSilentEdit()
    }

    // MARK: - Validation

    var isEditingText: Bool { canvas.editor.isActive }

    var canvasFocused: Bool {
        guard let r = window?.firstResponder else { return false }
        return r === canvas || r === thumbnails.table || r === sorter || r === window
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action, tag: item.tag)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let ok = validate(item.action, tag: item.tag)
        let firstObject = selectedObjects.first
        switch item.action {
        case #selector(toggleAllPanelsAction(_:)):
            item.title = Panels.allHidden(in: window) ? L("Show All Panels") : L("Hide All Panels")
        case #selector(viewModeAction(_:)): item.state = item.tag == mode.rawValue ? .on : .off
        case #selector(toggleNotesAction(_:)): item.state = notesShown ? .on : .off
        case #selector(toggleInspectorAction(_:)): item.state = inspectorShown ? .on : .off
        case #selector(toggleFormatBarAction(_:)): item.state = formatBar.strip.isShown ? .on : .off
        case #selector(toggleGuidesAction(_:)): item.state = snapToGuides ? .on : .off
        case #selector(hideSlideAction(_:)): item.state = currentSlide?.hidden == true ? .on : .off
        case #selector(layoutAction(_:)): item.state = currentSlide?.layout == item.tag ? .on : .off
        case #selector(transitionAction(_:)): item.state = TransitionKind.allCases.firstIndex(of: currentSlide?.transition.kind ?? .none) == item.tag ? .on : .off
        case #selector(slideSizeAction(_:)):
            let r = deck.size.width / deck.size.height
            item.state = (item.tag == 0 ? abs(r - 16.0 / 9) < 0.02 : abs(r - 4.0 / 3) < 0.02) ? .on : .off
        case #selector(themeAction(_:)): item.state = Themes.all[item.tag].theme.name == deck.theme.name ? .on : .off
        case #selector(boldAction(_:)): item.state = currentRunProps.bold == true ? .on : .off
        case #selector(italicAction(_:)): item.state = currentRunProps.italic == true ? .on : .off
        case #selector(underlineAction(_:)): item.state = currentRunProps.underline == true ? .on : .off
        case #selector(strikeAction(_:)): item.state = currentRunProps.strike == true ? .on : .off
        case #selector(alignTextAction(_:)): item.state = (TextAlign.allCases.firstIndex(of: currentLevelStyle.align ?? .left) ?? 0) == item.tag ? .on : .off
        case #selector(bulletsAction(_:)):
            let k = currentLevelStyle.bullet?.kind ?? Bullet.Kind.none
            item.state = (k == .none ? 0 : k == .char ? 1 : 2) == item.tag ? .on : .off
        case #selector(anchorAction(_:)):
            let a = firstObject?.text?.anchor ?? .top
            item.state = (a == .top ? 0 : a == .middle ? 1 : 2) == item.tag && firstObject?.text != nil ? .on : .off
        default: break
        }
        return ok
    }

    func validate(_ action: Selector?, tag: Int) -> Bool {
        let normal = mode == .normal
        let editable = mode == .normal || mode == .master
        let hasSel = !selection.isEmpty
        switch action {
        case #selector(deleteAction(_:)):
            if isEditingText { return false }
            if mode == .sorter || window?.firstResponder === thumbnails.table { return deck.slides.count > 0 }
            return hasSel && canvasFocused && normal
        case #selector(duplicateAction(_:)):
            return !isEditingText && (hasSel && normal || mode == .sorter || window?.firstResponder === thumbnails.table)
        case #selector(groupAction(_:)): return normal && selection.count > 1 && !isEditingText
        case #selector(ungroupAction(_:)): return normal && selectedObjects.contains { $0.kind == .group } && !isEditingText
        case #selector(arrangeAction(_:)): return normal && hasSel && !isEditingText
        case #selector(alignObjectsAction(_:)): return normal && hasSel
        case #selector(distributeAction(_:)): return normal && selection.count > 2
        case #selector(newSlideAction(_:)), #selector(newSlideWithLayoutAction(_:)), #selector(duplicateSlideAction(_:)): return mode != .master
        case #selector(deleteSlideAction(_:)): return mode != .master && deck.slides.count > 0
        case #selector(insertTextBoxAction(_:)), #selector(insertShapeAction(_:)), #selector(insertShapeMenuAction(_:)),
             #selector(insertImageAction(_:)), #selector(insertTableAction(_:)), #selector(showStampsAction(_:)),
             #selector(insertSlideNumberAction(_:)), #selector(insertDateAction(_:)):
            return normal && deck.slides.count > 0
        case #selector(tableRowAction(_:)), #selector(tableColumnAction(_:)):
            return normal && selectedObjects.count == 1 && selectedObjects.first?.kind == .table
        case #selector(boldAction(_:)), #selector(italicAction(_:)), #selector(underlineAction(_:)), #selector(strikeAction(_:)),
             #selector(biggerAction(_:)), #selector(smallerAction(_:)), #selector(baselineAction(_:)), #selector(clearFormattingAction(_:)),
             #selector(alignTextAction(_:)), #selector(bulletsAction(_:)), #selector(indentAction(_:)), #selector(lineSpacingAction(_:)), #selector(anchorAction(_:)):
            return editable && (isEditingText || selectedObjects.contains { $0.text != nil || $0.kind == .table })
        case #selector(layoutAction(_:)), #selector(hideSlideAction(_:)), #selector(transitionAction(_:)), #selector(backgroundAction(_:)):
            return mode != .master && currentSlide != nil
        case #selector(playAction(_:)), #selector(playCurrentAction(_:)), #selector(rehearseAction(_:)):
            return deck.slides.contains { !$0.hidden } && SlideShowController.current == nil
        case #selector(findNextAction(_:)), #selector(findPreviousAction(_:)): return !finder.query.isEmpty
        case #selector(zoomInAction(_:)), #selector(zoomOutAction(_:)), #selector(zoomFitAction(_:)), #selector(actualSizeAction(_:)): return editable
        case #selector(toggleNotesAction(_:)): return normal
        default: return true
        }
    }
}

extension DeckWindowController: PanelHiding {}

extension DeckWindowController: NSMenuDelegate {
    /// Toolbar "New Slide" pull-down: one item per layout.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "toolbarNewSlide" else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for (i, layout) in deck.layouts.enumerated() {
            let item = NSMenuItem(title: Themes.displayName(layout), action: #selector(newSlideWithLayoutAction(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.image = LayoutIcons.icon(layout, deck: deck, width: 40)
            menu.addItem(item)
        }
    }
}

/// Speaker notes under the canvas.
final class NotesTextView: NSTextView, NSTextViewDelegate {
    weak var owner: DeckWindowController?
    private(set) var isEditing = false
    private var loading = false

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        isRichText = false
        allowsUndo = true
        font = NSFont(name: "Helvetica Neue", size: 13)
        textContainerInset = NSSize(width: 14, height: 10)
        delegate = self
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        isAutomaticQuoteSubstitutionEnabled = false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let s = NSAttributedString(string: L("Click to add speaker notes"), attributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
            s.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
        }
    }

    func load() {
        guard let owner else { return }
        loading = true
        let text = owner.mode == .master ? "" : owner.currentSlide?.notes ?? ""
        if string != text { string = text }
        isEditable = owner.mode == .normal && owner.currentSlide != nil
        loading = false
        needsDisplay = true
    }

    func textDidBeginEditing(_ notification: Notification) { isEditing = true }

    func textDidEndEditing(_ notification: Notification) {
        isEditing = false
        owner?.doc?.endSilentEdit(L("Edit Notes"))
    }

    func textDidChange(_ notification: Notification) {
        guard !loading, let owner, owner.currentSlide != nil else { return }
        let i = owner.current
        let text = string
        owner.doc?.silentChange { $0.slides[i].notes = text }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { privateUndo }
    private let privateUndo = UndoManager()
}
