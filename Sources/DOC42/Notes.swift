import AppKit
import Kit42

/// Footnote reference: an attachment that draws its own number (numbers follow the text order,
/// so inserting or deleting a footnote renumbers the others without touching the text).
final class NoteCell: NSTextAttachmentCell {
    private func label(_ lm: NSLayoutManager?, _ index: Int) -> NSAttributedString {
        let n = (lm as? DocLayoutManager)?.noteNumber(at: index) ?? 1
        let base = (lm?.textStorage?.length ?? 0) > index ? lm?.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
        let size = max(6, (base?.pointSize ?? 12) * 0.62)
        let color = ((lm?.textStorage?.length ?? 0) > index ? lm?.textStorage?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor : nil) ?? .black
        return NSAttributedString(string: "\(n)", attributes: [.font: NSFont(name: base?.fontName ?? "Helvetica Neue", size: size) ?? .systemFont(ofSize: size),
                                                                .foregroundColor: color])
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        let lm = textContainer.layoutManager
        let s = label(lm, charIndex).size()
        let base = (lm?.textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont)?.pointSize ?? 12
        // Bottom of the number raised to about half the x-height, top near the cap height.
        return NSRect(x: 0, y: base * 0.32, width: ceil(s.width) + 1, height: ceil(s.height))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        label(layoutManager, charIndex).draw(at: NSPoint(x: cellFrame.minX + 0.5, y: cellFrame.minY))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func wantsToTrackMouse() -> Bool { false }
}

enum Notes {
    /// The reference character of a new footnote.
    static func reference(_ note: DocNote, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let a = NSTextAttachment()
        a.attachmentCell = NoteCell()
        var attrs = attributes.filter { [.font, .foregroundColor, .paragraphStyle, .backgroundColor].contains($0.key) }
        attrs[.attachment] = a
        attrs[.docNote] = note
        return NSAttributedString(string: "\u{FFFC}", attributes: attrs)
    }

    /// All footnotes in text order with their reference positions.
    static func all(in text: NSAttributedString) -> [(NSRange, DocNote)] {
        var out: [(NSRange, DocNote)] = []
        text.enumerateAttribute(.docNote, in: NSRange(location: 0, length: text.length)) { v, r, _ in
            if let n = v as? DocNote { out.append((r, n)) }
        }
        return out
    }

    /// For formats without footnotes (RTF, ODT, HTML, Markdown, text): references become superscript numbers
    /// and the notes a "Notes" list at the end; comments and section geometry are left out.
    static func flatten(_ text: NSAttributedString) -> NSAttributedString {
        let notes = all(in: text)
        var hasSections = false
        text.enumerateAttribute(.docSection, in: NSRange(location: 0, length: text.length)) { v, _, stop in if v != nil { hasSections = true; stop.pointee = true } }
        guard !notes.isEmpty || hasSections else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        out.removeAttribute(.docSection, range: NSRange(location: 0, length: out.length))
        for (k, (r, _)) in notes.enumerated().reversed() {
            var attrs = out.attributes(at: r.location, effectiveRange: nil)
            attrs[.attachment] = nil
            attrs[.docNote] = nil
            attrs[.superscript] = 1
            out.replaceCharacters(in: r, with: NSAttributedString(string: "\(k + 1)", attributes: attrs))
        }
        guard !notes.isEmpty else { return out }
        if !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: Styles.normal.attributes)) }
        var heading = Styles.all[3].attributes
        heading[Styles.styleKey] = "Heading3"
        out.append(NSAttributedString(string: L("Notes") + "\n", attributes: heading))
        for (k, (_, n)) in notes.enumerated() {
            out.append(NSAttributedString(string: "\(k + 1). \(n.text)\n", attributes: Styles.normal.attributes))
        }
        return out
    }
}

extension DocWindowController {
    // MARK: - Footnotes

    @objc func insertFootnoteAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        let at = NSMaxRange(textView.selectedRange())
        var attrs = textView.typingAttributes
        if storage.length > 0, at > 0 { attrs = storage.attributes(at: at - 1, effectiveRange: nil).merging(attrs.filter { $0.key == .paragraphStyle }) { a, _ in a } }
        let note = DocNote("")
        let ref = Notes.reference(note, attributes: attrs)
        let range = NSRange(location: at, length: 0)
        guard textView.shouldChangeText(in: range, replacementString: ref.string) else { return }
        storage.replaceCharacters(in: range, with: ref)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Insert Footnote"))
        textView.setSelectedRange(NSRange(location: at + 1, length: 0))
        paged.layoutAll()
        editNote(note)
    }

    /// Footnote at or just before the cursor.
    var noteAtCursor: DocNote? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let r = textView.selectedRange()
        for i in [r.location, r.location - 1] where i >= 0 && i < storage.length {
            if let n = storage.attribute(.docNote, at: i, effectiveRange: nil) as? DocNote { return n }
        }
        return nil
    }

    @objc func editFootnoteAction(_ sender: Any?) {
        if let n = noteAtCursor { editNote(n) } else { NSSound.beep() }
    }

    @objc func deleteFootnoteAction(_ sender: Any?) {
        guard let n = noteAtCursor, let storage = textView.textStorage,
              let (r, _) = Notes.all(in: storage).first(where: { $0.1 === n }) else { NSSound.beep(); return }
        guard textView.shouldChangeText(in: r, replacementString: "") else { return }
        storage.replaceCharacters(in: r, with: "")
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Delete Footnote"))
    }

    func setNoteText(_ note: DocNote, _ text: String) {
        let old = note.text
        guard old != text else { return }
        note.text = text
        doc?.undoManager?.registerUndo(withTarget: self) { $0.setNoteText(note, old) }
        doc?.undoManager?.setActionName(L("Edit Footnote"))
        paged.scheduleReconcile()
        for card in paged.cards where card.notes.contains(where: { $0.1 === note }) { card.needsDisplay = true }
    }

    /// Popover over the footnote (at the bottom of its page) for editing its text.
    func editNote(_ note: DocNote) {
        guard let storage = textView.textStorage, let (r, _) = Notes.all(in: storage).first(where: { $0.1 === note }) else { return }
        paged.layoutAll()
        let number = paged.layoutManager.noteNumber(at: r.location)
        let field = NSTextField(string: note.text)
        field.placeholderString = L("Footnote text")
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L("Footnote %d", number))
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [title, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        let vc = NSViewController()
        vc.view = stack
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        let commit = NotePopoverDelegate { [weak self, weak field] in
            guard let self, let field else { return }
            self.setNoteText(note, field.stringValue)
        }
        popover.delegate = commit
        objc_setAssociatedObject(popover, &NotePopoverDelegate.key, commit, .OBJC_ASSOCIATION_RETAIN)
        field.target = commit
        field.action = #selector(NotePopoverDelegate.done(_:))
        commit.popover = popover
        // Anchor: the note at the bottom of its page, else the reference.
        if let card = paged.card(at: r.location) {
            let h = max(card.noteHeight, 20)
            let rect = NSRect(x: card.setup.margins.left, y: card.setup.margins.top + card.setup.textSize.height - h, width: card.setup.textSize.width, height: h)
            card.scrollToVisible(rect)
            popover.show(relativeTo: rect, of: card, preferredEdge: .maxY)
        } else if let tv = paged.textView(at: r.location) {
            popover.show(relativeTo: tv.bounds, of: tv, preferredEdge: .maxY)
        }
        window?.makeFirstResponder(field)
    }
}

/// Saves the footnote text when its popover closes (or Return is pressed).
final class NotePopoverDelegate: NSObject, NSPopoverDelegate {
    static var key = 0
    let commit: () -> Void
    weak var popover: NSPopover?
    init(_ commit: @escaping () -> Void) { self.commit = commit }
    func popoverWillClose(_ notification: Notification) { commit() }
    @objc func done(_ sender: Any?) { popover?.performClose(nil) }
}
