import AppKit
import Kit42

/// Page size, margins, columns, header and footer of a document or section (points).
struct PageSetup: Equatable {
    var size = NSSize(width: 595, height: 842)
    var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    var header = ""
    var footer = ""
    var pageNumbers = true
    var columns = 1
    var columnSpacing: CGFloat = 36

    static func == (a: PageSetup, b: PageSetup) -> Bool {
        a.sameGeometry(b) && a.header == b.header && a.footer == b.footer && a.pageNumbers == b.pageNumbers
    }

    /// Same paper, margins and columns (what the layout depends on).
    func sameGeometry(_ b: PageSetup) -> Bool {
        size == b.size && columns == b.columns && abs(columnSpacing - b.columnSpacing) < 0.01 &&
            margins.top == b.margins.top && margins.left == b.margins.left && margins.bottom == b.margins.bottom && margins.right == b.margins.right
    }

    var textSize: NSSize { NSSize(width: size.width - margins.left - margins.right, height: size.height - margins.top - margins.bottom) }
    var columnWidth: CGFloat { max(36, (textSize.width - CGFloat(columns - 1) * columnSpacing) / CGFloat(max(1, columns))) }
    var isLandscape: Bool { size.width > size.height }

    /// The geometry part, as stored on a section break.
    var section: DocSection { DocSection(pageSize: size, margins: margins, columns: columns, columnSpacing: columnSpacing) }

    /// A section's geometry with the document's header and footer.
    func with(_ s: DocSection?) -> PageSetup {
        guard let s else { return self }
        var p = self
        p.size = s.pageSize
        p.margins = s.margins
        p.columns = s.columns
        p.columnSpacing = s.columnSpacing
        return p
    }
}

/// Text flowing across real pages: one layout manager, one text container + text view per page column,
/// pages added and removed as the text grows (like TextEdit's "Wrap to Page"). Prints page by page.
/// Sections (form feeds carrying a DocSection) give their pages their own size, margins and columns;
/// footnotes take space at the bottom of the page that has their reference.
final class PagedView: NSView, NSLayoutManagerDelegate {
    let layoutManager = DocLayoutManager()
    private(set) var cards: [PageCard] = []
    private let configure: (NSTextView) -> Void
    static let gap: CGFloat = 28
    /// Space on the right of the pages (comments).
    var sideWidth: CGFloat = 0 { didSet { if sideWidth != oldValue { relayout() } } }
    /// After pages were laid out or moved (comments follow their text).
    var onLayout: (() -> Void)?
    /// Double click on a footnote at the bottom of a page.
    var onNoteClick: ((DocNote) -> Void)?

    /// Setup of the last section (and header/footer of every page).
    var setup: PageSetup {
        didSet { if setup != oldValue { applySetup() } }
    }

    var textViews: [NSTextView] { cards.flatMap(\.textViews) }

    init(storage: NSTextStorage, setup: PageSetup, configure: @escaping (NSTextView) -> Void) {
        self.setup = setup
        self.configure = configure
        super.init(frame: NSRect(x: 0, y: 0, width: setup.size.width + Self.gap * 2, height: setup.size.height + Self.gap * 2))
        layoutManager.delegate = self
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
        addPage(startingAt: 0)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        layoutManager.textStorage?.removeLayoutManager(layoutManager)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.currentContextDrawingToScreen() else { return }
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
    }

    // MARK: Sections

    private var sectionCache: [(index: Int, section: DocSection)]?

    /// Section breaks in text order.
    var sections: [(index: Int, section: DocSection)] {
        if let s = sectionCache { return s }
        var out: [(Int, DocSection)] = []
        if let storage = layoutManager.textStorage {
            storage.enumerateAttribute(.docSection, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if let s = v as? DocSection { out.append((r.location, s)) }
            }
        }
        sectionCache = out
        return out
    }

    /// Setup of the section that contains a character (a break belongs to the section it ends).
    func setup(at index: Int) -> PageSetup {
        setup.with(sections.first { $0.index >= index }?.section)
    }

    @objc private func storageEdited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedAttributes) || storage.editedMask.contains(.editedCharacters) else { return }
        sectionCache = nil
        layoutManager.notesChanged()
        churn = 0
        scheduleReconcile()
    }

    // MARK: Pages

    // Adding a container re-enters layout (and this delegate); defer nested requests to keep page order.
    private var changingPages = false
    private var pendingAdd: Int?

    private func addPage(startingAt index: Int) {
        if changingPages { pendingAdd = index; return }
        changingPages = true
        defer {
            changingPages = false
            // Layout asked for another page while this one was being added.
            if let next = pendingAdd {
                pendingAdd = nil
                addPage(startingAt: next)
            }
        }
        let card = PageCard(setup: setup(at: index))
        card.onNoteClick = { [weak self] in self?.onNoteClick?($0) }
        cards.append(card)
        addSubview(card)
        card.setColumns(card.setup.columns, containerIndex: layoutManager.textContainers.count, in: self)
        relayout()
    }

    /// New text view for a column (configured like every other).
    fileprivate func makeColumn(size: NSSize, at index: Int) -> NSTextView {
        let container = NSTextContainer(size: size)
        container.lineFragmentPadding = 0
        // The layout manager owns containers (text views don't retain theirs).
        layoutManager.insertTextContainer(container, at: index)
        let tv = PageTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        configure(tv)
        return tv
    }

    private func removeLastPage() {
        guard cards.count > 1, !changingPages else { return }
        changingPages = true
        defer { changingPages = false }
        let card = cards.removeLast()
        if let responder = window?.firstResponder as? NSTextView, card.textViews.contains(where: { $0 === responder }) {
            window?.makeFirstResponder(cards.last?.textViews.first)
        }
        for _ in card.textViews { layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1) }
        card.removeFromSuperview()
        relayout()
    }

    private func applySetup() {
        sectionCache = nil
        churn = 0
        for card in cards { card.setup.header = setup.header; card.setup.footer = setup.footer; card.setup.pageNumbers = setup.pageNumbers }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: layoutManager.textStorage?.length ?? 0), actualCharacterRange: nil)
        scheduleReconcile()
    }

    /// Index of a card's first container in the layout manager.
    private func firstContainerIndex(of cardIndex: Int) -> Int {
        cards[..<cardIndex].reduce(0) { $0 + $1.textViews.count }
    }

    func relayout() {
        let visibleWidth = enclosingScrollView?.contentView.bounds.width ?? 0
        let pageWidth = cards.map(\.setup.size.width).max() ?? setup.size.width
        let width = max(visibleWidth, pageWidth + Self.gap * 2 + sideWidth)
        var y = Self.gap
        for (i, card) in cards.enumerated() {
            card.number = i + 1
            card.total = cards.count
            let s = card.setup.size
            card.frame = NSRect(x: floor((width - sideWidth - s.width) / 2), y: y, width: s.width, height: s.height)
            y += s.height + Self.gap
        }
        setFrameSize(NSSize(width: width, height: y))
        onLayout?()
    }

    /// Width the view needs at least (widest page, gaps, side panel).
    var minimumWidth: CGFloat { (cards.map(\.setup.size.width).max() ?? setup.size.width) + Self.gap * 2 + sideWidth }

    override func resizeSubviews(withOldSize oldSize: NSSize) { relayout() }

    /// Lays out the whole text (adds all pages, places footnotes) — needed before printing offscreen.
    func layoutAll() {
        reconcile(full: true)
    }

    private func ensureFullLayout() {
        let full = NSRange(location: 0, length: layoutManager.textStorage?.length ?? 0)
        var count = -1
        while count != cards.count {
            count = cards.count
            layoutManager.ensureLayout(forCharacterRange: full)
        }
    }

    func card(at characterIndex: Int) -> PageCard? {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return cards.first }
        let i = min(max(0, characterIndex), storage.length - 1)
        let g = layoutManager.glyphIndexForCharacter(at: i)
        guard let container = layoutManager.textContainer(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true) else { return cards.last }
        return cards.first { $0.textViews.contains { $0.textContainer === container } }
    }

    func pageNumber(at characterIndex: Int) -> Int {
        guard let c = card(at: characterIndex), let i = cards.firstIndex(where: { $0 === c }) else { return 1 }
        return i + 1
    }

    func textView(at characterIndex: Int) -> NSTextView? {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return textViews.first }
        let g = layoutManager.glyphIndexForCharacter(at: min(max(0, characterIndex), storage.length - 1))
        guard let container = layoutManager.textContainer(forGlyphAt: g, effectiveRange: nil) else { return textViews.last }
        return textViews.first { $0.textContainer === container }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let tv = textView(at: range.location) else { return }
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }

    /// Rectangle of a character range in this view's coordinates (first line).
    func rect(for range: NSRange) -> NSRect? {
        guard let tv = textView(at: range.location), let container = tv.textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: max(1, min(range.length, 1))), actualCharacterRange: nil)
        let r = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        return convert(r.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y), from: tv)
    }

    // MARK: Reconciling pages with sections, footnotes and column breaks

    private var reconcileScheduled = false
    private var reconciling = false
    /// Passes that changed something since the last edit: stops footnote ping-pong.
    private var churn = 0

    func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            self.reconcile(full: false)
        }
    }

    /// Gives every laid-out page its section's geometry, room for its footnotes and empty columns after a page break.
    func reconcile(full: Bool) {
        guard !reconciling, let storage = layoutManager.textStorage else { return }
        reconciling = true
        defer { reconciling = false }
        for _ in 0..<12 {
            if full { ensureFullLayout() }
            guard churn < 40 else { break }
            let laidOut = full ? storage.length : layoutManager.firstUnlaidCharacterIndex()
            var changed = false
            var containerIndex = 0
            var i = 0
            while i < cards.count {
                let card = cards[i]
                let first = containerIndex
                containerIndex += card.textViews.count
                guard let firstContainer = card.textViews.first?.textContainer else { i += 1; continue }
                let glyphs = layoutManager.glyphRange(for: firstContainer)
                let start = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
                if start > laidOut { break }
                // 1. Section geometry.
                let wanted = setup(at: start)
                if !card.setup.sameGeometry(wanted) {
                    card.setup = wanted
                    card.setColumns(wanted.columns, containerIndex: first, in: self)
                    card.setNotes([])
                    card.noteHeight = 0
                    changed = true
                    break
                }
                card.setup.header = setup.header; card.setup.footer = setup.footer; card.setup.pageNumbers = setup.pageNumbers
                // Characters on the page.
                var end = start
                for tv in card.textViews {
                    let g = layoutManager.glyphRange(for: tv.textContainer!)
                    end = max(end, NSMaxRange(layoutManager.characterRange(forGlyphRange: g, actualGlyphRange: nil)))
                }
                // 2. Footnotes of the page.
                var notes: [(Int, DocNote)] = []
                if end > start {
                    storage.enumerateAttribute(.docNote, in: NSRange(location: start, length: end - start)) { v, r, _ in
                        if let n = v as? DocNote { notes.append((self.layoutManager.noteNumber(at: r.location), n)) }
                    }
                }
                card.setNotes(notes)
                let reserve = card.measureNotes()
                // Shrinking can move a reference back and forth between pages: after a few passes only grow.
                if abs(reserve - card.noteHeight) > 0.5, reserve > card.noteHeight || churn < 6 {
                    card.noteHeight = reserve
                    card.positionColumns()
                    changed = true
                    break
                }
                // 3. A page or section break in a column leaves the page's other columns empty.
                var blockFrom = Int.max
                for (j, tv) in card.textViews.enumerated() where j < card.textViews.count - 1 {
                    let g = layoutManager.glyphRange(for: tv.textContainer!)
                    let r = layoutManager.characterRange(forGlyphRange: g, actualGlyphRange: nil)
                    if r.length > 0, (storage.string as NSString).character(at: NSMaxRange(r) - 1) == 0x0C { blockFrom = j + 1; break }
                }
                for (j, tv) in card.textViews.enumerated() {
                    let blocked = j >= blockFrom
                    if let c = tv.textContainer, c.exclusionPaths.isEmpty == blocked {
                        c.exclusionPaths = blocked ? [NSBezierPath(rect: NSRect(x: -10, y: -10, width: c.size.width + 20, height: c.size.height + 20))] : []
                        changed = true
                    }
                }
                if changed { break }
                i += 1
            }
            if !changed { break }
            churn += 1
        }
        relayout()
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ lm: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinished: Bool) {
        let containers = lm.textContainers
        if !layoutFinished || textContainer == nil {
            // Text left over: add a page after the last one.
            if let last = containers.last, textContainer === last || textContainer == nil {
                // (A page that took nothing would be followed by endless empty ones.)
                let used = cards.last?.textViews.compactMap(\.textContainer).filter { lm.glyphRange(for: $0).length > 0 } ?? []
                if let filled = used.last {
                    addPage(startingAt: NSMaxRange(lm.characterRange(forGlyphRange: lm.glyphRange(for: filled), actualGlyphRange: nil)))
                }
            }
        } else if let tc = textContainer, let used = containers.firstIndex(where: { $0 === tc }) {
            // Everything fits: drop empty trailing pages.
            var lastNeeded = 0, index = 0
            for (k, card) in cards.enumerated() {
                if index <= used { lastNeeded = k }
                index += card.textViews.count
            }
            while cards.count - 1 > lastNeeded { removeLastPage() }
        }
        if !reconciling { scheduleReconcile() }
    }

    /// The empty line right after a section break takes no room at the top of the next page.
    func layoutManager(_ lm: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = lm.textStorage, glyphRange.length == 1 else { return false }
        let c = lm.characterIndexForGlyph(at: glyphRange.location)
        guard c > 0, c < storage.length, (storage.string as NSString).character(at: c) == 10,
              storage.attribute(.docSection, at: c - 1, effectiveRange: nil) != nil else { return false }
        lineFragmentRect.pointee.size.height = 0.01
        lineFragmentUsedRect.pointee.size.height = 0.01
        baselineOffset.pointee = 0
        return true
    }

    // MARK: Printing (one sheet per page card)

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: cards.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { cards[max(0, min(cards.count - 1, page - 1))].frame }

    /// Pages differ in size (sections with another orientation or paper).
    var hasMixedPageSizes: Bool { Set(cards.map { "\($0.setup.size)" }).count > 1 }

    /// One PDF page per card, each in its own size.
    func pdfData() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(origin: .zero, size: cards.first?.setup.size ?? setup.size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for card in cards {
            var media = CGRect(origin: .zero, size: card.bounds.size)
            let page = NSData(data: card.dataWithPDF(inside: card.bounds))
            ctx.beginPage(mediaBox: &media)
            if let provider = CGDataProvider(data: page), let doc = CGPDFDocument(provider), let p = doc.page(at: 1) {
                ctx.drawPDFPage(p)
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

/// White sheet with column text views inside the margins, header, footer and footnotes.
final class PageCard: NSView {
    private(set) var textViews: [NSTextView] = []
    var setup: PageSetup { didSet { if !setup.sameGeometry(oldValue) { positionColumns() }; needsDisplay = true } }
    var number = 1 { didSet { if number != oldValue { needsDisplay = true } } }
    var total = 1 { didSet { if total != oldValue { needsDisplay = true } } }
    /// Footnotes whose references are on this page, with their numbers.
    private(set) var notes: [(Int, DocNote)] = []
    private var notesKey = ""

    func setNotes(_ n: [(Int, DocNote)]) {
        let key = n.map { "\($0.0):\(ObjectIdentifier($0.1).hashValue):\($0.1.text.hashValue)" }.joined(separator: ",")
        notes = n
        if key != notesKey { notesKey = key; needsDisplay = true }
    }
    /// Room taken by the footnotes at the bottom of the text area.
    var noteHeight: CGFloat = 0
    var onNoteClick: ((DocNote) -> Void)?
    private var noteRects: [(NSRect, DocNote)] = []

    static let noteFont = NSFont(name: "Helvetica Neue", size: 9) ?? .systemFont(ofSize: 9)

    init(setup: PageSetup) {
        self.setup = setup
        super.init(frame: NSRect(origin: .zero, size: setup.size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// Adds or removes column text views (and their containers, from `containerIndex` in the layout manager).
    func setColumns(_ n: Int, containerIndex: Int, in paged: PagedView) {
        let lm = paged.layoutManager
        while textViews.count > n {
            let tv = textViews.removeLast()
            if let responder = window?.firstResponder as? NSTextView, responder === tv { window?.makeFirstResponder(textViews.first) }
            lm.removeTextContainer(at: containerIndex + textViews.count)
            tv.removeFromSuperview()
        }
        while textViews.count < n {
            let tv = paged.makeColumn(size: NSSize(width: setup.columnWidth, height: setup.textSize.height), at: containerIndex + textViews.count)
            textViews.append(tv)
            addSubview(tv)
        }
        positionColumns()
    }

    func positionColumns() {
        let w = setup.columnWidth, h = max(36, setup.textSize.height - noteHeight)
        for (j, tv) in textViews.enumerated() {
            let size = NSSize(width: w, height: h)
            if tv.textContainer?.size != size { tv.textContainer?.size = size }
            tv.frame = NSRect(x: setup.margins.left + CGFloat(j) * (w + setup.columnSpacing), y: setup.margins.top, width: w, height: h)
        }
    }

    private func noteText(_ n: Int, _ note: DocNote) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "\(n)", attributes: [.font: Self.noteFont, .superscript: 1, .foregroundColor: NSColor.black])
        s.append(NSAttributedString(string: " " + (note.text.isEmpty ? " " : note.text), attributes: [.font: Self.noteFont, .foregroundColor: NSColor.black]))
        return s
    }

    /// Height the footnotes need (separator included).
    func measureNotes() -> CGFloat {
        guard !notes.isEmpty else { return 0 }
        let width = setup.textSize.width
        let h = notes.reduce(CGFloat(0)) { sum, n in
            sum + ceil(noteText(n.0, n.1).boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        }
        return min(setup.textSize.height / 2, h + 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica Neue", size: 9) ?? .systemFont(ofSize: 9),
                                                    .foregroundColor: NSColor(white: 0.4, alpha: 1)]
        func centered(_ s: String, y: CGFloat) {
            let size = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: y), withAttributes: attrs)
        }
        if !setup.header.isEmpty { centered(setup.header, y: max(12, setup.margins.top / 2 - 6)) }
        let footerY = bounds.height - max(18, setup.margins.bottom / 2 + 4)
        let footer = [setup.footer, setup.pageNumbers ? "\(number)" : ""].filter { !$0.isEmpty }.joined(separator: "   ")
        if !footer.isEmpty { centered(footer, y: footerY) }

        // Footnotes under a short rule.
        noteRects = []
        guard !notes.isEmpty, noteHeight > 0 else { return }
        let x = setup.margins.left, width = setup.textSize.width
        var y = setup.margins.top + setup.textSize.height - noteHeight + 6
        NSColor(white: 0.55, alpha: 1).setFill()
        NSRect(x: x, y: y, width: min(144, width / 3), height: 0.5).fill()
        y += 6
        for (n, note) in notes {
            let s = noteText(n, note)
            let h = ceil(s.boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            let r = NSRect(x: x, y: y, width: width, height: h)
            s.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading])
            noteRects.append((r, note))
            y += h + 2
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = noteRects.first(where: { $0.0.insetBy(dx: 0, dy: -1).contains(p) }) {
            onNoteClick?(hit.1)
            return
        }
        super.mouseDown(with: event)
    }
}

/// Text view of one page column: find commands go to the window's finder (all pages at once),
/// the format painter applies on mouse up.
final class PageTextView: NSTextView {
    private var editor: DocWindowController? { window?.windowController as? DocWindowController }

    override func performTextFinderAction(_ sender: Any?) {
        if let editor { editor.performFinderAction(sender) } else { super.performTextFinderAction(sender) }
    }

    override func performFindPanelAction(_ sender: Any?) {
        if let editor { editor.performFinderAction(sender) } else { super.performFindPanelAction(sender) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)), let editor {
            return editor.validateFinderAction(item)
        }
        return super.validateUserInterfaceItem(item)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        editor?.textViewMouseUp(self)
    }

    override func cancelOperation(_ sender: Any?) {
        if editor?.cancelFormatPainter() == true { return }
        super.cancelOperation(sender)
    }
}

/// Draws dot leaders on tab characters marked `.docTabLeader` (tables of contents) and numbers footnote references.
final class DocLayoutManager: NSLayoutManager {
    private var numbers: [Int: Int]?

    func notesChanged() { numbers = nil }

    /// Footnote number of the reference at a character index (1-based, in text order).
    func noteNumber(at index: Int) -> Int {
        if numbers == nil {
            var out: [Int: Int] = [:]
            if let storage = textStorage {
                var n = 0
                storage.enumerateAttribute(.docNote, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                    guard v is DocNote else { return }
                    for k in 0..<r.length { n += 1; out[r.location + k] = n }
                }
            }
            numbers = out
        }
        return numbers?[index] ?? 1
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.docTabLeader, in: chars) { v, r, _ in
            guard v != nil else { return }
            for c in r.location..<NSMaxRange(r) where (storage.string as NSString).character(at: c) == 9 {
                let g = glyphIndexForCharacter(at: c)
                guard let container = textContainer(forGlyphAt: g, effectiveRange: nil) else { continue }
                let rect = boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
                var line = NSRange()
                let fragment = lineFragmentRect(forGlyphAt: g, effectiveRange: &line)
                let baseline = fragment.minY + location(forGlyphAt: g).y
                let color = (storage.attribute(.foregroundColor, at: c, effectiveRange: nil) as? NSColor) ?? .black
                color.setFill()
                var x = ceil((rect.minX + 3) / 4) * 4
                while x < rect.maxX - 4 {
                    NSBezierPath(ovalIn: NSRect(x: origin.x + x, y: origin.y + baseline - 1.6, width: 1.3, height: 1.3)).fill()
                    x += 4
                }
            }
        }
    }
}
