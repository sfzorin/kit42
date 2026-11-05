import AppKit
import Kit42

/// Card of one comment in the margin to the right of the pages: author, date, editable text, resolve and delete.
final class CommentCardView: NSView, NSTextFieldDelegate {
    let comment: DocComment
    let field = NSTextField(string: "")
    private let author = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private lazy var resolveButton = button("checkmark.circle", L("Resolve"), #selector(resolve))
    private lazy var deleteButton = button("trash", L("Delete Comment"), #selector(remove))
    var onSelect: (() -> Void)?
    var onResolve: (() -> Void)?
    var onDelete: (() -> Void)?
    var onText: ((String) -> Void)?
    var onResize: (() -> Void)?
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    static let width: CGFloat = 240

    init(_ comment: DocComment) {
        self.comment = comment
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 80))
        author.font = .boldSystemFont(ofSize: 11)
        author.textColor = .labelColor
        date.font = .systemFont(ofSize: 10)
        date.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.placeholderString = L("Comment")
        field.delegate = self
        for v in [author, date, field, resolveButton, deleteButton] as [NSView] { addSubview(v) }
        update()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        return b
    }

    func update() {
        author.stringValue = comment.author.isEmpty ? L("Author") : comment.author
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        date.stringValue = f.string(from: comment.date) + (comment.resolved ? " · " + L("Resolved") : "")
        if field.stringValue != comment.text { field.stringValue = comment.text }
        resolveButton.image = NSImage(systemSymbolName: comment.resolved ? "checkmark.circle.fill" : "checkmark.circle", accessibilityDescription: nil)
        resolveButton.toolTip = comment.resolved ? L("Reopen") : L("Resolve")
        alphaValue = comment.resolved ? 0.6 : 1
        layoutContent()
    }

    /// Lays out the subviews and sets its own height.
    func layoutContent() {
        let w = Self.width, pad: CGFloat = 10
        author.frame = NSRect(x: pad, y: 8, width: w - 2 * pad - 48, height: 15)
        date.frame = NSRect(x: pad, y: 23, width: w - 2 * pad - 48, height: 14)
        resolveButton.frame = NSRect(x: w - 54, y: 8, width: 20, height: 20)
        deleteButton.frame = NSRect(x: w - 30, y: 8, width: 20, height: 20)
        let textWidth = w - 2 * pad
        let h = max(18, field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 18)
        field.frame = NSRect(x: pad - 2, y: 42, width: textWidth + 4, height: h)
        setFrameSize(NSSize(width: w, height: 42 + h + 10))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isActive ? NSColor(calibratedRed: 0.95, green: 0.7, blue: 0.1, alpha: 1) : NSColor.separatorColor).setStroke()
        path.lineWidth = isActive ? 1.5 : 0.5
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    @objc private func resolve() { onResolve?() }
    @objc private func remove() { onDelete?() }

    func controlTextDidChange(_ obj: Notification) {
        let old = frame.height
        layoutContent()
        if frame.height != old { onResize?() }
    }

    func controlTextDidEndEditing(_ obj: Notification) { onText?(field.stringValue) }
}

/// Comment views and highlights of one editor window.
final class CommentsState {
    var views: [ObjectIdentifier: CommentCardView] = [:]
    var shown = UserDefaults.standard.object(forKey: "doc.comments") as? Bool ?? true
    var highlightKey = ""
    var laying = false
}

extension DocWindowController {
    // MARK: - Comments

    /// Comments in text order with the range each covers.
    func allComments() -> [(DocComment, NSRange)] {
        guard let storage = textView.textStorage else { return [] }
        var order: [DocComment] = []
        var ranges: [ObjectIdentifier: NSRange] = [:]
        storage.enumerateAttribute(.docComment, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let c = v as? DocComment else { return }
            let k = ObjectIdentifier(c)
            if let old = ranges[k] { ranges[k] = NSUnionRange(old, r) } else { order.append(c); ranges[k] = r }
        }
        return order.map { ($0, ranges[ObjectIdentifier($0)]!) }
    }

    var commentAtCursor: DocComment? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let r = textView.selectedRange()
        for i in [r.location, r.location - 1] where i >= 0 && i < storage.length {
            if let c = storage.attribute(.docComment, at: i, effectiveRange: nil) as? DocComment { return c }
        }
        return nil
    }

    @objc func newCommentAction(_ sender: Any?) {
        guard let storage = textView.textStorage, storage.length > 0 else { NSSound.beep(); return }
        var r = textView.selectedRange()
        if r.length == 0 { r = textView.selectionRange(forProposedRange: NSRange(location: min(r.location, storage.length - 1), length: 0), granularity: .selectByWord) }
        guard r.length > 0, textView.shouldChangeText(in: r, replacementString: nil) else { NSSound.beep(); return }
        let c = DocComment(author: NSFullUserName())
        storage.addAttribute(.docComment, value: c, range: r)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("New Comment"))
        textView.setSelectedRange(r)
        if !comments.shown { toggleCommentsAction(nil) }
        layoutComments()
        if let v = comments.views[ObjectIdentifier(c)] {
            v.scrollToVisible(v.bounds)
            window?.makeFirstResponder(v.field)
        }
    }

    func deleteComment(_ c: DocComment) {
        guard let storage = textView.textStorage, let (_, range) = allComments().first(where: { $0.0 === c }),
              textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.docComment, in: range) { v, r, _ in
            if (v as? DocComment) === c { storage.removeAttribute(.docComment, range: r) }
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Delete Comment"))
        layoutComments()
    }

    @objc func deleteCommentAction(_ sender: Any?) {
        if let c = commentAtCursor { deleteComment(c) } else { NSSound.beep() }
    }

    @objc func resolveCommentAction(_ sender: Any?) {
        if let c = commentAtCursor { setResolved(c, !c.resolved) } else { NSSound.beep() }
    }

    func setResolved(_ c: DocComment, _ value: Bool) {
        let old = c.resolved
        guard old != value else { return }
        c.resolved = value
        doc?.undoManager?.registerUndo(withTarget: self) { $0.setResolved(c, old) }
        doc?.undoManager?.setActionName(value ? L("Resolve") : L("Reopen"))
        comments.views[ObjectIdentifier(c)]?.update()
        comments.highlightKey = ""
        layoutComments()
    }

    func setCommentText(_ c: DocComment, _ text: String) {
        let old = c.text
        guard old != text else { return }
        c.text = text
        doc?.undoManager?.registerUndo(withTarget: self) { $0.setCommentText(c, old) }
        doc?.undoManager?.setActionName(L("Edit Comment"))
        comments.views[ObjectIdentifier(c)]?.update()
        layoutComments()
    }

    @objc func toggleCommentsAction(_ sender: Any?) {
        setComments(shown: !comments.shown)
        UserDefaults.standard.set(comments.shown, forKey: "doc.comments")
    }

    func setComments(shown: Bool) {
        comments.shown = shown
        comments.highlightKey = ""
        layoutComments()
    }

    /// Places comment cards next to their text (pushed down when they would overlap) and highlights the ranges.
    func layoutComments() {
        guard !comments.laying else { return }
        comments.laying = true
        defer { comments.laying = false }
        let list = allComments()
        let lm = paged.layoutManager
        // Highlights (screen only).
        let active = commentAtCursor
        let key = list.map { "\(ObjectIdentifier($0.0).hashValue):\($0.1):\($0.0.resolved)" }.joined() + "\(comments.shown)\(active.map { ObjectIdentifier($0).hashValue } ?? 0)"
        if key != comments.highlightKey, let storage = textView.textStorage {
            comments.highlightKey = key
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            if comments.shown {
                for (c, r) in list where !c.resolved {
                    storage.enumerateAttribute(.docComment, in: r) { v, sub, _ in
                        guard (v as? DocComment) === c else { return }
                        let strong = c === active
                        lm.addTemporaryAttribute(.backgroundColor, value: NSColor(calibratedRed: 1, green: 0.86, blue: 0.4, alpha: strong ? 0.85 : 0.45), forCharacterRange: sub)
                    }
                }
            }
        }
        // Cards of comments and tracked changes, in text order.
        var cards = revisionCards()
        let wanted: CGFloat = comments.shown && (!list.isEmpty || !cards.isEmpty) ? CommentCardView.width + 40 : 0
        if paged.sideWidth != wanted { paged.sideWidth = wanted }
        var keep = Set<ObjectIdentifier>()
        for (c, r) in comments.shown ? list : [] {
            let k = ObjectIdentifier(c)
            keep.insert(k)
            let v = comments.views[k] ?? {
                let v = CommentCardView(c)
                v.onSelect = { [weak self] in
                    guard let self, let range = self.allComments().first(where: { $0.0 === c })?.1 else { return }
                    self.window?.makeFirstResponder(self.paged.textView(at: range.location))
                    self.textView.setSelectedRange(range)
                    self.paged.scrollRangeToVisible(range)
                }
                v.onResolve = { [weak self] in self?.setResolved(c, !c.resolved) }
                v.onDelete = { [weak self] in self?.deleteComment(c) }
                v.onText = { [weak self] in self?.setCommentText(c, $0) }
                v.onResize = { [weak self] in self?.layoutComments() }
                comments.views[k] = v
                paged.addSubview(v)
                return v
            }()
            v.isActive = c === active
            cards.append((r, v))
        }
        cards.sort { $0.0.location < $1.0.location }
        var bottom: CGFloat = 0
        for (r, v) in cards {
            guard let rect = paged.rect(for: r), let card = paged.card(at: r.location) else { v.isHidden = true; continue }
            v.isHidden = false
            let y = max(rect.minY - 8, bottom + 8)
            v.setFrameOrigin(NSPoint(x: card.frame.maxX + 20, y: y))
            bottom = v.frame.maxY
        }
        for (k, v) in comments.views where !keep.contains(k) {
            v.removeFromSuperview()
            comments.views[k] = nil
        }
    }
}
