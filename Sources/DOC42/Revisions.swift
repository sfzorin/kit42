import AppKit
import Kit42

// MARK: - Reading tracked changes from .docx

extension DocxStyles {
    /// <w:ins>/<w:del> (and moves) → their content unwrapped between markers ("r" id … "R" id), deleted text made visible;
    /// a tracked paragraph mark (pPr/rPr/ins|del) → "p" marker at the end of its paragraph. Restored by `restoreMarks`.
    static func markRevisions(_ body: XMLElement, extras: inout Extras) {
        let iso = ISO8601DateFormatter()
        var n = 0
        func revision(_ e: XMLElement, _ kind: DocRevision.Kind) -> String {
            n += 1
            let dateText = e.attr("date") ?? ""
            let date = iso.date(from: dateText) ?? iso.date(from: dateText + "Z") ?? Date()
            extras.revisions["\(n)"] = DocRevision(kind, author: e.attr("author") ?? "", date: date)
            return "\(n)"
        }
        for name in ["ins", "moveTo", "del", "moveFrom"] {
            let kind: DocRevision.Kind = name == "ins" || name == "moveTo" ? .insertion : .deletion
            for e in descendants(body, named: name) {
                guard let parent = e.parent as? XMLElement else { continue }
                switch parent.localName ?? "" {
                case "rPr":
                    // Paragraph mark of the paragraph that owns this pPr.
                    if parent.parent?.localName == "pPr", let p = parent.parent?.parent as? XMLElement, p.localName == "p" {
                        p.addChild(mark("p", revision(e, kind)))
                    }
                    e.detach()
                case "trPr", "tcPr", "pPr", "sectPr", "numPr", "rPrChange", "pPrChange":
                    e.detach()   // row/cell/property changes: kept as they are now
                default:
                    let id = revision(e, kind)
                    if kind == .deletion {
                        for t in descendants(e, named: "delText") { t.name = "w:t" }
                        for t in descendants(e, named: "delInstrText") { t.name = "w:instrText" }
                    }
                    let kids = e.children ?? []
                    let at = e.index
                    e.setChildren(nil)
                    parent.removeChild(at: at)
                    for (k, c) in ([mark("r", id)] + kids + [mark("R", id)]).enumerated() { parent.insertChild(c, at: at + k) }
                }
            }
        }
    }
}

// MARK: - Changes in a text

enum Revisions {
    /// One change as shown and accepted: adjacent runs of the same kind and author.
    struct Change {
        var range: NSRange
        let kind: DocRevision.Kind
        let author: String
        let date: Date
        let first: DocRevision
    }

    static func changes(in text: NSAttributedString) -> [Change] {
        var out: [Change] = []
        text.enumerateAttribute(.docRevision, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            guard let rev = v as? DocRevision else { return }
            if var last = out.last, NSMaxRange(last.range) == r.location, last.kind == rev.kind, last.author == rev.author {
                last.range.length += r.length
                out[out.count - 1] = last
            } else {
                out.append(Change(range: r, kind: rev.kind, author: rev.author, date: rev.date, first: rev))
            }
        }
        return out
    }

    static func has(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.docRevision, in: NSRange(location: 0, length: text.length)) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The text with every change accepted (for formats without tracked changes, PDF and printing).
    static func accepted(_ text: NSAttributedString) -> NSAttributedString {
        guard has(text) else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        for c in changes(in: text).reversed() {
            if c.kind == .deletion { out.deleteCharacters(in: c.range) } else { out.removeAttribute(.docRevision, range: c.range) }
        }
        return out
    }

    /// Author colours, as in Word: the first author blue-violet, then red, green, …
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.45, green: 0.18, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.80, green: 0.10, blue: 0.15, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.50, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.0, green: 0.35, blue: 0.75, alpha: 1),
        NSColor(srgbRed: 0.75, green: 0.40, blue: 0.0, alpha: 1), NSColor(srgbRed: 0.65, green: 0.10, blue: 0.55, alpha: 1),
    ]
}

/// Track changes state of one editor window.
final class ReviewState {
    var showMarkup = UserDefaults.standard.object(forKey: "doc.markup") as? Bool ?? true
    var views: [String: RevisionCardView] = [:]
    var authors: [String] = []
    /// Text typed with tracking on, to be marked as inserted once it is in the storage.
    var pending: NSRange?
    /// Accepting, rejecting or recording a change: not itself tracked.
    var applying = false
    private var insertion: DocRevision?
    private var deletion: DocRevision?

    func color(_ author: String) -> NSColor {
        if !authors.contains(author) { authors.append(author) }
        return Revisions.palette[(authors.firstIndex(of: author) ?? 0) % Revisions.palette.count]
    }

    /// The revision new edits get (one per kind for a couple of minutes: neighbouring edits merge).
    func revision(_ kind: DocRevision.Kind) -> DocRevision {
        let author = NSFullUserName()
        let cached = kind == .insertion ? insertion : deletion
        if let c = cached, c.author == author, Date().timeIntervalSince(c.date) < 120 { return c }
        let r = DocRevision(kind, author: author)
        if kind == .insertion { insertion = r } else { deletion = r }
        return r
    }
}

// MARK: - Change card in the margin

/// Card of one tracked change: author, date, what was inserted or deleted, accept and reject.
final class RevisionCardView: NSView {
    private(set) var change: Revisions.Change
    private let author = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private lazy var acceptButton = button("checkmark", L("Accept Change"), #selector(accept))
    private lazy var rejectButton = button("xmark", L("Reject Change"), #selector(reject))
    var color: NSColor = .systemPurple { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }

    init(_ change: Revisions.Change, text: String) {
        self.change = change
        super.init(frame: NSRect(x: 0, y: 0, width: CommentCardView.width, height: 60))
        author.font = .boldSystemFont(ofSize: 11)
        author.textColor = .labelColor
        date.font = .systemFont(ofSize: 10)
        date.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: 11)
        body.textColor = .labelColor
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byTruncatingTail
        for v in [author, date, body, acceptButton, rejectButton] as [NSView] { addSubview(v) }
        update(change, text: text)
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

    func update(_ change: Revisions.Change, text: String) {
        self.change = change
        author.stringValue = change.author.isEmpty ? L("Author") : change.author
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        date.stringValue = f.string(from: change.date)
        var shown = text.replacingOccurrences(of: "\n", with: " ¶ ").replacingOccurrences(of: "\u{000C}", with: " ").replacingOccurrences(of: "\u{FFFC}", with: "▫︎")
        if shown.count > 160 { shown = String(shown.prefix(160)) + "…" }
        let label = change.kind == .insertion ? L("Inserted:") : L("Deleted:")
        let s = NSMutableAttributedString(string: label + " ", attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        if change.kind == .deletion { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        s.append(NSAttributedString(string: "«" + shown + "»", attributes: a))
        body.attributedStringValue = s
        layoutContent()
    }

    func layoutContent() {
        let w = CommentCardView.width, pad: CGFloat = 10
        author.frame = NSRect(x: pad + 8, y: 8, width: w - 2 * pad - 56, height: 15)
        date.frame = NSRect(x: pad + 8, y: 23, width: w - 2 * pad - 56, height: 14)
        acceptButton.frame = NSRect(x: w - 54, y: 8, width: 20, height: 20)
        rejectButton.frame = NSRect(x: w - 30, y: 8, width: 20, height: 20)
        let textWidth = w - 2 * pad - 8
        body.preferredMaxLayoutWidth = textWidth
        let h = min(64, max(15, body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 15))
        body.frame = NSRect(x: pad + 8, y: 41, width: textWidth, height: h)
        setFrameSize(NSSize(width: w, height: 41 + h + 9))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isActive ? color : NSColor.separatorColor).setStroke()
        path.lineWidth = isActive ? 1.5 : 0.5
        path.stroke()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 10, width: 3, height: bounds.height - 20), xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    @objc private func accept() { onAccept?() }
    @objc private func reject() { onReject?() }
}

// MARK: - Editor

extension DocWindowController {
    var isTrackingChanges: Bool { doc?.trackChanges == true }

    /// Revision for text typed now (nil when not tracking): used as a typing attribute.
    var typingRevision: DocRevision? { isTrackingChanges ? review.revision(.insertion) : nil }

    @objc func toggleTrackChangesAction(_ sender: Any?) {
        guard let doc else { return }
        doc.trackChanges.toggle()
        doc.updateChangeCount(.changeDone)
        textView.typingAttributes[.docRevision] = typingRevision
        updateStatus()
    }

    @objc func toggleMarkupAction(_ sender: Any?) {
        review.showMarkup.toggle()
        UserDefaults.standard.set(review.showMarkup, forKey: "doc.markup")
        paged.hidesDeletions = !review.showMarkup
        updateRevisionMarkup()
        layoutComments()
    }

    /// Called from `textView(_:shouldChangeTextIn:replacementString:)`: with tracking on, a user edit that
    /// removes text keeps it as a deletion. Returns whether the text view may go on with the change itself.
    func trackEdit(_ tv: NSTextView, _ range: NSRange, _ replacement: String?) -> Bool {
        guard isTrackingChanges, !review.applying, PageTextView.userEditing > 0, let replacement else { return true }
        if range.length == 0 || tv.hasMarkedText() {
            if !replacement.isEmpty { review.pending = NSRange(location: range.location, length: (replacement as NSString).length) }
            return true
        }
        guard let storage = tv.textStorage else { return true }
        // Tracked insertions just go; other text stays as deleted.
        let out = NSMutableAttributedString()
        let deletion = review.revision(.deletion)
        var unchanged = true
        storage.enumerateAttribute(.docRevision, in: range) { v, r, _ in
            let rev = v as? DocRevision
            if rev?.kind == .insertion { unchanged = false; return }
            let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: r))
            if rev == nil { piece.addAttribute(.docRevision, value: deletion, range: NSRange(location: 0, length: piece.length)); unchanged = false }
            out.append(piece)
        }
        let kept = out.length
        if !replacement.isEmpty {
            var attrs = tv.typingAttributes
            if range.location < storage.length, replacement != "\n" {
                // The typed text looks like what it replaces.
                for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
                    if let v = storage.attribute(key, at: range.location, effectiveRange: nil) { attrs[key] = v }
                }
            }
            for key in [NSAttributedString.Key.docNote, .attachment, .docSection, .link, .docComment] { attrs[key] = nil }
            attrs[.docRevision] = review.revision(.insertion)
            out.append(NSAttributedString(string: replacement, attributes: attrs))
            unchanged = false
        }
        let caret = !replacement.isEmpty ? range.location + out.length : PageTextView.forwardDelete ? range.location + kept : range.location
        if !unchanged {
            review.applying = true
            defer { review.applying = false }
            guard tv.shouldChangeText(in: range, replacementString: out.string) else { return false }
            storage.replaceCharacters(in: range, with: out)
            tv.didChangeText()
        }
        tv.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        return false
    }

    /// Marks text just typed or pasted with tracking on as inserted (from `textDidChange`).
    func markPendingInsertion() {
        guard let p = review.pending else { return }
        review.pending = nil
        guard isTrackingChanges, NSMaxRange(p) <= storageLength, p.length > 0, let storage = textView.textStorage else { return }
        let rev = review.revision(.insertion)
        var plain = false
        storage.enumerateAttribute(.docRevision, in: p) { v, _, stop in if (v as? DocRevision) !== rev { plain = true; stop.pointee = true } }
        if plain { storage.addAttribute(.docRevision, value: rev, range: p) }
    }

    private var storageLength: Int { textView.textStorage?.length ?? 0 }

    /// Colours inserted text (underlined) and deleted text (struck through) on screen; Final view shows neither.
    func updateRevisionMarkup() {
        guard let storage = textView.textStorage else { return }
        let lm = paged.layoutManager
        let full = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.foregroundColor, .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor] {
            lm.removeTemporaryAttribute(key, forCharacterRange: full)
        }
        guard review.showMarkup else { return }
        for c in Revisions.changes(in: storage) {
            let color = review.color(c.author)
            let style = c.kind == .insertion ? NSAttributedString.Key.underlineStyle : .strikethroughStyle
            lm.addTemporaryAttributes([.foregroundColor: color, style: NSUnderlineStyle.single.rawValue,
                                       c.kind == .insertion ? .underlineColor : .strikethroughColor: color], forCharacterRange: c.range)
        }
    }

    var allChanges: [Revisions.Change] { textView.textStorage.map { Revisions.changes(in: $0) } ?? [] }

    /// Changes touched by the selection (or at the cursor).
    var changesAtSelection: [Revisions.Change] {
        let sel = textView.selectedRange()
        return allChanges.filter { c in
            sel.length > 0 ? NSIntersectionRange(c.range, sel).length > 0 : (sel.location >= c.range.location && sel.location <= NSMaxRange(c.range))
        }
    }

    func select(_ c: Revisions.Change) {
        textView.setSelectedRange(c.range)
        window?.makeFirstResponder(paged.textView(at: c.range.location))
        paged.scrollRangeToVisible(c.range)
    }

    @objc func nextChangeAction(_ sender: Any?) {
        let sel = textView.selectedRange()
        let all = allChanges
        guard let c = all.first(where: { $0.range.location >= NSMaxRange(sel) && $0.range != sel }) ?? all.first(where: { $0.range != sel }) ?? all.first else { NSSound.beep(); return }
        select(c)
    }

    @objc func previousChangeAction(_ sender: Any?) {
        let sel = textView.selectedRange()
        let all = allChanges
        guard let c = all.last(where: { NSMaxRange($0.range) <= sel.location && $0.range != sel }) ?? all.last(where: { $0.range != sel }) ?? all.last else { NSSound.beep(); return }
        select(c)
    }

    @objc func acceptChangeAction(_ sender: Any?) { resolveAtSelection(accept: true) }
    @objc func rejectChangeAction(_ sender: Any?) { resolveAtSelection(accept: false) }
    @objc func acceptAllChangesAction(_ sender: Any?) { resolve(allChanges, accept: true, name: L("Accept All Changes")) }
    @objc func rejectAllChangesAction(_ sender: Any?) { resolve(allChanges, accept: false, name: L("Reject All Changes")) }

    private func resolveAtSelection(accept: Bool) {
        let list = changesAtSelection
        guard !list.isEmpty else {
            // Nothing here: go to the next change, as Word does.
            nextChangeAction(nil)
            return
        }
        resolve(list, accept: accept, name: accept ? L("Accept Change") : L("Reject Change"))
        // On to the next change.
        let at = list[0].range.location
        if let next = allChanges.first(where: { $0.range.location >= at }) { select(next) }
    }

    /// Accepts or rejects changes in one undo step: accepted deletions and rejected insertions remove their text,
    /// the others just stop being changes.
    func resolve(_ list: [Revisions.Change], accept: Bool, name: String) {
        guard !list.isEmpty, let storage = textView.textStorage else { NSSound.beep(); return }
        let remove = list.filter { ($0.kind == .deletion) == accept }.map(\.range)
        let keep = list.filter { ($0.kind == .deletion) != accept }.map(\.range)
        let undo = doc?.undoManager
        review.applying = true
        defer { review.applying = false }
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        if !keep.isEmpty, textView.shouldChangeText(inRanges: keep.map { NSValue(range: $0) }, replacementStrings: nil) {
            storage.beginEditing()
            for r in keep { storage.removeAttribute(.docRevision, range: r) }
            storage.endEditing()
            textView.didChangeText()
        }
        if !remove.isEmpty, textView.shouldChangeText(inRanges: remove.map { NSValue(range: $0) }, replacementStrings: remove.map { _ in "" }) {
            storage.beginEditing()
            for r in remove.reversed() { storage.deleteCharacters(in: r) }
            storage.endEditing()
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: min(remove[0].location, storage.length), length: 0))
        }
        undo?.setActionName(name)
        undo?.endUndoGrouping()
        updateRevisionMarkup()
        layoutComments()
    }

    /// Cards of the changes (placed with the comment cards by `layoutComments`), with the text they cover.
    func revisionCards() -> [(NSRange, NSView)] {
        guard comments.shown, review.showMarkup, let storage = textView.textStorage else {
            for v in review.views.values { v.removeFromSuperview() }
            review.views = [:]
            return []
        }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        var keep = Set<String>()
        var seen: [ObjectIdentifier: Int] = [:]
        var out: [(NSRange, NSView)] = []
        for c in Revisions.changes(in: storage) {
            let k0 = ObjectIdentifier(c.first)
            let n = seen[k0, default: 0]
            seen[k0] = n + 1
            let key = "\(k0.hashValue)-\(n)"
            keep.insert(key)
            let text = ns.substring(with: c.range)
            let v = review.views[key] ?? {
                let v = RevisionCardView(c, text: text)
                v.onSelect = { [weak self, weak v] in if let self, let v { self.select(v.change) } }
                v.onAccept = { [weak self, weak v] in if let self, let v { self.resolve([v.change], accept: true, name: L("Accept Change")) } }
                v.onReject = { [weak self, weak v] in if let self, let v { self.resolve([v.change], accept: false, name: L("Reject Change")) } }
                review.views[key] = v
                paged.addSubview(v)
                return v
            }()
            if v.change.range != c.range || v.change.kind != c.kind { v.update(c, text: text) }
            v.color = review.color(c.author)
            v.isActive = sel.length > 0 ? NSIntersectionRange(c.range, sel).length > 0 : (sel.location >= c.range.location && sel.location <= NSMaxRange(c.range))
            out.append((c.range, v))
        }
        for (k, v) in review.views where !keep.contains(k) {
            v.removeFromSuperview()
            review.views[k] = nil
        }
        return out
    }
}
