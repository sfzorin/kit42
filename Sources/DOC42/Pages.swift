import AppKit
import Kit42

/// Page size, margins, header and footer of a document (points).
struct PageSetup: Equatable {
    var size = NSSize(width: 595, height: 842)
    var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    var header = ""
    var footer = ""
    var pageNumbers = true

    static func == (a: PageSetup, b: PageSetup) -> Bool {
        a.size == b.size && a.header == b.header && a.footer == b.footer && a.pageNumbers == b.pageNumbers &&
            a.margins.top == b.margins.top && a.margins.left == b.margins.left && a.margins.bottom == b.margins.bottom && a.margins.right == b.margins.right
    }

    var textSize: NSSize { NSSize(width: size.width - margins.left - margins.right, height: size.height - margins.top - margins.bottom) }
}

/// Text flowing across real pages: one layout manager, one text container + text view per page,
/// pages added and removed as the text grows (like TextEdit's "Wrap to Page"). Prints page by page.
final class PagedView: NSView, NSLayoutManagerDelegate {
    let layoutManager = NSLayoutManager()
    private(set) var cards: [PageCard] = []
    private let configure: (NSTextView) -> Void
    static let gap: CGFloat = 28

    var setup: PageSetup {
        didSet { if setup != oldValue { applySetup() } }
    }

    var textViews: [NSTextView] { cards.map(\.textView) }

    init(storage: NSTextStorage, setup: PageSetup, configure: @escaping (NSTextView) -> Void) {
        self.setup = setup
        self.configure = configure
        super.init(frame: NSRect(x: 0, y: 0, width: setup.size.width + Self.gap * 2, height: setup.size.height + Self.gap * 2))
        layoutManager.delegate = self
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        addPage()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func detach() { layoutManager.textStorage?.removeLayoutManager(layoutManager) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.currentContextDrawingToScreen() else { return }
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
    }

    // Adding a container re-enters layout (and this delegate); defer nested requests to keep page order.
    private var changingPages = false
    private var pendingAdd = false

    private func addPage() {
        if changingPages { pendingAdd = true; return }
        changingPages = true
        defer {
            changingPages = false
            // Layout asked for another page while this one was being added.
            if pendingAdd {
                pendingAdd = false
                addPage()
            }
        }
        let container = NSTextContainer(size: setup.textSize)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(origin: .zero, size: setup.textSize), textContainer: container)
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        configure(tv)
        let card = PageCard(textView: tv, setup: setup)
        cards.append(card)
        addSubview(card)
        relayout()
    }

    private func removeLastPage() {
        guard cards.count > 1, !changingPages else { return }
        changingPages = true
        defer { changingPages = false }
        let card = cards.removeLast()
        if window?.firstResponder === card.textView { window?.makeFirstResponder(cards.last?.textView) }
        layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
        card.removeFromSuperview()
        relayout()
    }

    private func applySetup() {
        for card in cards {
            card.setup = setup
            card.textView.textContainer?.size = setup.textSize
            card.textView.setFrameSize(setup.textSize)
        }
        relayout()
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: layoutManager.textStorage?.length ?? 0), actualCharacterRange: nil)
    }

    func relayout() {
        let visibleWidth = enclosingScrollView?.contentView.bounds.width ?? 0
        let width = max(visibleWidth, setup.size.width + Self.gap * 2)
        let x = floor((width - setup.size.width) / 2)
        for (i, card) in cards.enumerated() {
            card.number = i + 1
            card.total = cards.count
            card.frame = NSRect(x: x, y: Self.gap + CGFloat(i) * (setup.size.height + Self.gap), width: setup.size.width, height: setup.size.height)
        }
        setFrameSize(NSSize(width: width, height: Self.gap + CGFloat(cards.count) * (setup.size.height + Self.gap)))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) { relayout() }

    /// Lays out the whole text (adds all pages) — needed before printing offscreen.
    func layoutAll() {
        let full = NSRange(location: 0, length: layoutManager.textStorage?.length ?? 0)
        var count = -1
        while count != cards.count {
            count = cards.count
            layoutManager.ensureLayout(forCharacterRange: full)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard let container = layoutManager.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil),
              let tv = textViews.first(where: { $0.textContainer === container }) else { return }
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ lm: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinished: Bool) {
        let containers = lm.textContainers
        if !layoutFinished || textContainer == nil {
            // Text left over: add a page after the last one.
            if let last = containers.last, textContainer === last || textContainer == nil, lm.glyphRange(for: last).length > 0 { addPage() }
        } else if let tc = textContainer, let used = containers.firstIndex(where: { $0 === tc }), used + 1 < containers.count {
            // Everything fits: drop empty trailing pages.
            for _ in 0..<(containers.count - used - 1) { removeLastPage() }
        }
    }

    // MARK: Printing (one sheet per page card)

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: cards.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { cards[max(0, min(cards.count - 1, page - 1))].frame }
}

/// White sheet with a text view inside the margins, header and footer.
final class PageCard: NSView {
    let textView: NSTextView
    var setup: PageSetup { didSet { position(); needsDisplay = true } }
    var number = 1 { didSet { if number != oldValue { needsDisplay = true } } }
    var total = 1 { didSet { if total != oldValue { needsDisplay = true } } }

    init(textView: NSTextView, setup: PageSetup) {
        self.textView = textView
        self.setup = setup
        super.init(frame: NSRect(origin: .zero, size: setup.size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(textView)
        position()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private func position() {
        textView.setFrameOrigin(NSPoint(x: setup.margins.left, y: setup.margins.top))
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
    }
}
