import AppKit
import Kit42

// MARK: - Slide sorter

/// Grid of all slides: select, drag to reorder, double-click to edit.
final class SorterView: NSView {
    weak var owner: DeckWindowController?
    private let cache = ThumbnailCache()
    private var dropIndex: Int?
    private var dragStart: CGPoint?
    private var dragging = false
    var cellWidth: CGFloat = 210
    private let gap: CGFloat = 28, labelH: CGFloat = 20

    init(owner: DeckWindowController) {
        self.owner = owner
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var deck: Deck { owner?.deck ?? Deck.makeDefault() }
    private var cellHeight: CGFloat { cellWidth * deck.size.height / deck.size.width }
    private var columns: Int { max(1, Int((bounds.width - gap) / (cellWidth + gap))) }

    private var leftInset: CGFloat {
        let used = CGFloat(columns) * (cellWidth + gap) - gap
        return max(gap, (bounds.width - used) / 2)
    }

    func rect(_ i: Int) -> CGRect {
        let c = i % columns, r = i / columns
        return CGRect(x: leftInset + CGFloat(c) * (cellWidth + gap), y: gap + CGFloat(r) * (cellHeight + gap + labelH), width: cellWidth, height: cellHeight)
    }

    func deckChanged() {
        let width = enclosingScrollView?.visibleContentSize.width ?? bounds.width
        let rows = Int(ceil(Double(deck.slides.count) / Double(columns)))
        let h = max(enclosingScrollView?.visibleContentSize.height ?? 400, gap + CGFloat(rows) * (cellHeight + gap + labelH) + gap)
        setFrameSize(NSSize(width: width, height: h))
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.deckChanged() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let owner else { return }
        let scale = window?.backingScaleFactor ?? 2
        for (i, s) in deck.slides.enumerated() {
            let r = rect(i)
            guard r.insetBy(dx: -10, dy: -30).intersects(dirtyRect) else { continue }
            if owner.slideSelection.contains(i) {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), xRadius: 5, yRadius: 5)
                ring.lineWidth = 3
                (i == owner.current ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.5)).setStroke()
                ring.stroke()
            }
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowBlurRadius = 4
            sh.shadowOffset = NSSize(width: 0, height: -1)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
            sh.set()
            NSColor.white.setFill()
            r.fill()
            NSGraphicsContext.restoreGraphicsState()
            cache.image(s, index: i, deck: deck, width: Int(cellWidth * scale)).draw(in: r, from: .zero, operation: .sourceOver, fraction: s.hidden ? 0.45 : 1,
                                                                                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            var label = "\(Renderer.number(of: i, deck: deck))"
            if s.hidden { label += " · " + L("Hidden") }
            if s.transition.kind != .none { label += " · " + Transitions.name(s.transition.kind) }
            let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: i == owner.current ? .semibold : .regular),
                                                                      .foregroundColor: NSColor.secondaryLabelColor])
            text.draw(at: CGPoint(x: r.midX - text.size().width / 2, y: r.maxY + 5))
        }
        if let d = dropIndex {
            let r = d < deck.slides.count ? rect(d) : rect(max(0, deck.slides.count - 1)).offsetBy(dx: cellWidth + gap, dy: 0)
            NSColor.controlAccentColor.setFill()
            NSRect(x: r.minX - gap / 2 - 1.5, y: r.minY - 4, width: 3, height: r.height + 8).fill()
        }
    }

    func index(at p: CGPoint) -> Int? { deck.slides.indices.first { rect($0).insetBy(dx: -gap / 2, dy: -gap / 2).contains(p) } }

    /// Insertion index for a drop at `p`.
    func insertion(at p: CGPoint) -> Int {
        var best = deck.slides.count
        var bestD = CGFloat.greatestFiniteMagnitude
        for i in 0...deck.slides.count {
            let r = i < deck.slides.count ? rect(i) : rect(max(0, deck.slides.count - 1)).offsetBy(dx: cellWidth + gap, dy: 0)
            let d = hypot(p.x - (r.minX - gap / 2), p.y - r.midY)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        dragging = false
        guard let i = index(at: p) else { return }
        if event.clickCount == 2 { owner.select(slide: i); owner.setMode(.normal); return }
        if event.modifierFlags.contains(.command) {
            var sel = owner.slideSelection
            if sel.contains(i), sel.count > 1 { sel.remove(i) } else { sel.insert(i) }
            owner.select(slide: i, extend: true)
            owner.slideSelection = sel
        } else if event.modifierFlags.contains(.shift) {
            let a = min(owner.current, i), b = max(owner.current, i)
            owner.select(slide: i)
            owner.slideSelection = IndexSet(a...b)
        } else if !owner.slideSelection.contains(i) {
            owner.select(slide: i)
        } else {
            let sel = owner.slideSelection
            owner.select(slide: i, extend: true)
            owner.slideSelection = sel
        }
        owner.thumbnails.syncSelection()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let s = dragStart, hypot(p.x - s.x, p.y - s.y) > 5 else { return }
        dragging = true
        dropIndex = insertion(at: p)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dropIndex = nil; dragging = false; needsDisplay = true }
        guard dragging, let d = dropIndex, let owner else { return }
        owner.moveSlides(owner.selectedSlideIndexes, to: d)
        deckChanged()
    }

    override func keyDown(with event: NSEvent) {
        guard let owner, let c = event.charactersIgnoringModifiers?.unicodeScalars.first else { super.keyDown(with: event); return }
        switch Int(c.value) {
        case NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey: owner.deleteSlideAction(nil)
        case NSLeftArrowFunctionKey: owner.select(slide: owner.current - 1)
        case NSRightArrowFunctionKey: owner.select(slide: owner.current + 1)
        case NSUpArrowFunctionKey: owner.select(slide: owner.current - columns)
        case NSDownArrowFunctionKey: owner.select(slide: owner.current + columns)
        case 13, 3: owner.setMode(.normal)
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) { owner?.copySlides() }
    @objc func cut(_ sender: Any?) { owner?.copySlides(); owner?.deleteSlideAction(nil) }
    @objc func paste(_ sender: Any?) { owner?.pasteObjects() }
    @objc override func selectAll(_ sender: Any?) {
        owner?.slideSelection = IndexSet(0..<deck.slides.count)
        owner?.thumbnails.syncSelection()
        needsDisplay = true
    }
}

// MARK: - Outline

/// Text outline of all slides: a line without indent is a slide title, Tab-indented lines are bullets. Editable.
final class OutlineEditor: NSTextView, NSTextViewDelegate {
    weak var owner: DeckWindowController?
    private(set) var isEditing = false
    private var loading = false
    private var pending: DispatchWorkItem?
    private let privateUndo = UndoManager()

    var hasPendingChanges: Bool { pending != nil }

    func resetUndoHistory() {
        breakUndoCoalescing()
        privateUndo.removeAllActions()
    }

    /// Used only after a successful document read; ending focus must not apply the old draft.
    func discardPendingEdits() {
        pending?.cancel(); pending = nil
        loading = true
        isEditing = false
        resetUndoHistory()
    }

    convenience init(owner: DeckWindowController) {
        self.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        self.owner = owner
        isRichText = false
        allowsUndo = true
        delegate = self
        textContainerInset = NSSize(width: 56, height: 24)
        isAutomaticQuoteSubstitutionEnabled = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
    }

    func configure(in scroll: NSScrollView) {
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
    }

    func undoManager(for view: NSTextView) -> UndoManager? { privateUndo }

    static let titleFont = NSFont(name: "Helvetica Neue Bold", size: 16) ?? .boldSystemFont(ofSize: 16)
    static let bodyFont = NSFont(name: "Helvetica Neue", size: 14) ?? .systemFont(ofSize: 14)

    func reload() {
        guard let owner else { return }
        loading = true
        let s = NSMutableAttributedString()
        for (i, slide) in owner.deck.slides.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "\n")) }
            s.append(NSAttributedString(string: slide.title.replacingOccurrences(of: "\u{0B}", with: " ")))
            for o in Outline.bodyObjects(slide) {
                for p in o.text?.paragraphs ?? [] where !p.text.isEmpty {
                    s.append(NSAttributedString(string: "\n" + String(repeating: "\t", count: p.level + 1) + p.text.replacingOccurrences(of: "\u{0B}", with: " ")))
                }
            }
        }
        if string != s.string {
            pending?.cancel(); pending = nil
            resetUndoHistory()
            textStorage?.setAttributedString(s)
        }
        restyle()
        loading = false
        needsDisplay = true
    }

    /// Titles bold, bullets indented by level.
    private func restyle() {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        storage.beginEditing()
        var loc = 0
        while loc <= ns.length {
            let r = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
            let line = ns.substring(with: r)
            let tabs = line.prefix { $0 == "\t" }.count
            let p = NSMutableParagraphStyle()
            p.tabStops = (1...9).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 26) }
            p.headIndent = CGFloat(tabs) * 26
            p.paragraphSpacingBefore = tabs == 0 && r.location > 0 ? 12 : 2
            storage.setAttributes([.font: tabs == 0 ? Self.titleFont : Self.bodyFont, .paragraphStyle: p,
                                   .foregroundColor: tabs == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor], range: r)
            if NSMaxRange(r) >= ns.length { break }
            loc = NSMaxRange(r)
        }
        storage.endEditing()
        typingAttributes = [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor]
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // Slide numbers and icons in the left margin.
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        var n = 0, loc = 0
        while loc < ns.length || (loc == 0 && ns.length == 0) {
            if ns.length == 0 { break }
            let r = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            if !ns.substring(with: r).hasPrefix("\t") {
                n += 1
                let g = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: 0), actualCharacterRange: nil)
                var rect = lm.lineFragmentRect(forGlyphAt: min(g.location, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
                if lm.numberOfGlyphs == 0 || r.location >= ns.length { rect = lm.extraLineFragmentRect }
                _ = tc
                let y = rect.maxY - lm.defaultLineHeight(for: Self.titleFont) + textContainerInset.height
                let num = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor])
                num.draw(at: CGPoint(x: 14, y: y + 5))
                NSColor.tertiaryLabelColor.setStroke()
                NSBezierPath(rect: CGRect(x: 30, y: y + 6, width: 16, height: 10)).stroke()
            }
            if NSMaxRange(r) >= ns.length { break }
            loc = NSMaxRange(r)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let r = ns.paragraphRange(for: selectedRange())
        if ns.substring(with: r).hasPrefix("\t") { insertText("", replacementRange: NSRange(location: r.location, length: 1)) }
    }

    func textDidBeginEditing(_ notification: Notification) { isEditing = true }

    func textDidEndEditing(_ notification: Notification) {
        apply()
        isEditing = false
        owner?.doc?.endSilentEdit(L("Edit Outline"))
    }

    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        restyle()
        needsDisplay = true
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes titles and bullets back into the slides (new title lines add slides; formatting of existing paragraphs is kept).
    func apply() {
        pending?.cancel()
        pending = nil
        guard let owner, !loading else { return }
        var groups: [(title: String, body: [(Int, String)])] = []
        for line in string.components(separatedBy: "\n") {
            let tabs = line.prefix { $0 == "\t" }.count
            let text = String(line.dropFirst(tabs))
            if tabs == 0 { groups.append((text, [])) } else if !groups.isEmpty { groups[groups.count - 1].body.append((tabs - 1, text)) } else { groups.append(("", [(tabs - 1, text)])) }
        }
        let deck = owner.deck
        var d = deck
        for (i, g) in groups.enumerated() {
            if i >= d.slides.count { d.slides.append(d.newSlide(layout: d.layoutIndex(type: "obj") ?? 1)) }
            var s = d.slides[i]
            if let k = s.objects.firstIndex(where: { $0.placeholder?.isTitle == true }) {
                if s.title.replacingOccurrences(of: "\u{0B}", with: " ") != g.title {
                    var t = s.objects[k].text ?? TextBody()
                    let props = t.paragraphs.first?.runs.first?.props ?? RunProps()
                    var p = t.paragraphs.first ?? Paragraph()
                    p.runs = g.title.isEmpty ? [] : [TextRun(text: g.title, props: props)]
                    t.paragraphs = [p]
                    s.objects[k].text = t
                }
            } else if !g.title.isEmpty, let lp = d.layout(of: s)?.placeholders.first(where: { $0.placeholder?.isTitle == true }) {
                var o = lp
                o.id = s.maxID + 1
                o.text?.listStyle = ListStyle()
                o.text?.paragraphs = [Paragraph(g.title)]
                s.objects.append(o)
            }
            if let k = s.objects.firstIndex(where: { Outline.bodyObjects(s).first?.id == $0.id }) {
                var t = s.objects[k].text ?? TextBody()
                let old = t.paragraphs.filter { !$0.text.isEmpty }
                let current = old.map { ($0.level, $0.text.replacingOccurrences(of: "\u{0B}", with: " ")) }
                if current.map({ "\($0.0)\($0.1)" }) != g.body.map({ "\($0.0)\($0.1)" }) {
                    t.paragraphs = g.body.enumerated().map { j, item in
                        var p = j < old.count ? old[j] : (old.last ?? Paragraph())
                        p.level = item.0
                        let props = p.runs.first?.props ?? RunProps()
                        p.runs = item.1.isEmpty ? [] : [TextRun(text: item.1, props: props)]
                        return p
                    }
                    if t.paragraphs.isEmpty { t.paragraphs = [Paragraph()] }
                    s.objects[k].text = t
                }
            }
            d.slides[i] = s
        }
        guard d != deck else { return }
        owner.doc?.silentChange { $0 = d }
    }
}

// MARK: - Notes page

/// A printed notes page: the slide above, the editable notes below.
final class NotesPageView: NSView, NSTextViewDelegate {
    weak var owner: DeckWindowController?
    private let notes = NSTextView()
    private var loading = false
    private let privateUndo = UndoManager()
    private var loadedSlide: UUID?

    func resetUndoHistory() {
        notes.breakUndoCoalescing()
        privateUndo.removeAllActions()
    }

    init(owner: DeckWindowController) {
        self.owner = owner
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        notes.isRichText = false
        notes.font = NSFont(name: "Helvetica Neue", size: 13)
        notes.textColor = .black
        notes.backgroundColor = .white
        notes.drawsBackground = true
        notes.insertionPointColor = .black
        notes.delegate = self
        notes.allowsUndo = true
        notes.textContainerInset = NSSize(width: 4, height: 6)
        addSubview(notes)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private var pageRect: CGRect {
        let avail = (enclosingScrollView?.visibleContentSize.width ?? bounds.width) - 80
        let w = min(680, max(320, avail))
        return CGRect(x: (bounds.width - w) / 2, y: 30, width: w, height: w * 842 / 595)
    }

    private var slideRect: CGRect {
        let p = pageRect, m = p.width * 54 / 595
        let w = p.width - m * 2
        return CGRect(x: p.minX + m, y: p.minY + m, width: w, height: w * (owner?.deck.size.height ?? 540) / (owner?.deck.size.width ?? 960))
    }

    func reload() {
        guard let owner else { return }
        let width = enclosingScrollView?.visibleContentSize.width ?? 800
        setFrameSize(NSSize(width: width, height: max(enclosingScrollView?.visibleContentSize.height ?? 600, pageRect.maxY + 30)))
        let p = pageRect, s = slideRect, m = p.width * 54 / 595
        notes.frame = CGRect(x: s.minX - 4, y: s.maxY + 22, width: s.width + 8, height: p.maxY - m - s.maxY - 22)
        loading = true
        let text = owner.currentSlide?.notes ?? ""
        if loadedSlide != owner.currentSlide?.uid || notes.string != text { resetUndoHistory() }
        loadedSlide = owner.currentSlide?.uid
        if notes.string != text { notes.string = text }
        notes.isEditable = owner.currentSlide != nil
        loading = false
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.reload() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = pageRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(p)
        ctx.restoreGState()
        if let slide = owner.currentSlide {
            Renderer.drawSlide(slide, index: owner.current, deck: owner.deck, in: slideRect, ctx: ctx)
            let num = NSAttributedString(string: "\(Renderer.number(of: owner.current, deck: owner.deck))", attributes: [.font: NSFont(name: "Helvetica Neue", size: 11) ?? .systemFont(ofSize: 11), .foregroundColor: NSColor.gray])
            num.draw(at: CGPoint(x: p.maxX - p.width * 54 / 595 - num.size().width, y: p.maxY - p.width * 40 / 595))
        }
        if notes.string.isEmpty {
            let s = NSAttributedString(string: L("Click to add speaker notes"), attributes: [.font: NSFont(name: "Helvetica Neue", size: 13) ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.gray])
            s.draw(at: CGPoint(x: notes.frame.minX + 9, y: notes.frame.minY + 6))
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { privateUndo }

    func textDidChange(_ notification: Notification) {
        guard !loading, let owner, owner.currentSlide != nil else { return }
        let i = owner.current, text = notes.string
        owner.doc?.silentChange { $0.slides[i].notes = text }
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) { owner?.doc?.endSilentEdit(L("Edit Notes")) }
}
