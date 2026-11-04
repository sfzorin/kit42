import AppKit
import Kit42

/// Format painter state: the attributes picked up and whether it stays on (double click).
final class PainterState {
    var characters: [NSAttributedString.Key: Any]?
    var paragraph: NSParagraphStyle?
    var style: String?
    var sticky = false
    var armed: Bool { characters != nil }
    static let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .underlineStyle, .strikethroughStyle,
                                                 .superscript, .baselineOffset, .kern, .shadow, .obliqueness, .expansion]
}

/// Word, character, paragraph and line counts.
struct TextStats {
    var words = 0, characters = 0, charactersNoSpaces = 0, paragraphs = 0, lines = 0

    static func of(_ text: NSAttributedString, _ range: NSRange, layout: NSLayoutManager?) -> TextStats {
        var s = TextStats()
        let ns = text.string as NSString
        let sub = ns.substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{000C}", with: "")
        sub.enumerateSubstrings(in: sub.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in s.words += 1 }
        for ch in sub where ch != "\n" && ch != "\r" && ch != "\u{2029}" {
            s.characters += 1
            if !ch.isWhitespace { s.charactersNoSpaces += 1 }
        }
        sub.enumerateLines { line, _ in if !line.trimmingCharacters(in: .whitespaces).isEmpty { s.paragraphs += 1 } }
        if let lm = layout, range.length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in if used.height > 1 { s.lines += 1 } }
        }
        return s
    }
}

extension DocWindowController {
    // MARK: - Special characters

    static let specialCharacters: [String] = ["—", "–", "«", "»", "„", "“", "”", "‘", "’", "№", "§", "©", "®", "™", "°", "±", "×", "÷",
                                              "≤", "≥", "≠", "≈", "∞", "€", "₽", "₺", "$", "£", "¥", "…", "•", "·", "→", "←", "↑", "↓",
                                              "½", "¼", "¾", "¹", "²", "³", "µ", "Ω", "π", "α", "β", "γ", "Δ", "√", "‰", "†", "✓", "\u{00A0}"]

    @objc func specialCharacterAction(_ sender: Any?) {
        let columns = 9
        var rows: [[NSView]] = []
        for (i, ch) in Self.specialCharacters.enumerated() {
            if i % columns == 0 { rows.append([]) }
            let b = NSButton(title: ch == "\u{00A0}" ? "⍽" : ch, target: self, action: #selector(insertSpecialCharacter(_:)))
            b.bezelStyle = .smallSquare
            b.font = .systemFont(ofSize: 15)
            b.tag = i
            b.toolTip = ch == "\u{00A0}" ? L("Non-breaking space") : (ch.unicodeScalars.first.map { $0.properties.name ?? "" } ?? "").capitalized
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            rows[rows.count - 1].append(b)
        }
        while rows[rows.count - 1].count < columns { rows[rows.count - 1].append(NSGridCell.emptyContentView) }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        let more = NSButton(title: L("More…"), target: self, action: #selector(characterViewerAction(_:)))
        more.bezelStyle = .rounded
        let stack = NSStackView(views: [grid, more])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let vc = NSViewController()
        vc.view = stack
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        specialPopover = popover
        if let tv = paged.textView(at: textView.selectedRange().location), let container = tv.textContainer {
            let g = paged.layoutManager.glyphRange(forCharacterRange: NSRange(location: textView.selectedRange().location, length: 0), actualCharacterRange: nil)
            var r = paged.layoutManager.boundingRect(forGlyphRange: NSRange(location: g.location, length: g.location < paged.layoutManager.numberOfGlyphs ? 1 : 0), in: container)
            r.size.width = max(1, r.width)
            popover.show(relativeTo: r.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y), of: tv, preferredEdge: .maxY)
        } else if let view = window?.contentView {
            popover.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
        }
    }

    @objc private func insertSpecialCharacter(_ sender: NSButton) {
        guard Self.specialCharacters.indices.contains(sender.tag) else { return }
        textView.insertText(Self.specialCharacters[sender.tag], replacementRange: textView.selectedRange())
    }

    @objc func characterViewerAction(_ sender: Any?) {
        specialPopover?.close()
        window?.makeFirstResponder(paged.textView(at: textView.selectedRange().location) ?? textView)
        NSApp.orderFrontCharacterPalette(sender)
    }

    // MARK: - Statistics

    @objc func statisticsAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        paged.layoutAll()
        let all = TextStats.of(storage, NSRange(location: 0, length: storage.length), layout: paged.layoutManager)
        let sel = textView.selectedRange()
        let part = sel.length > 0 ? TextStats.of(storage, sel, layout: paged.layoutManager) : nil
        func label(_ s: String, bold: Bool = false) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            if bold { f.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            f.alignment = .right
            return f
        }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        func n(_ v: Int) -> NSTextField { label(fmt.string(from: NSNumber(value: v)) ?? "\(v)") }
        var rows: [[NSView]] = [[NSGridCell.emptyContentView, label(L("Document"), bold: true)] + (part != nil ? [label(L("Selection"), bold: true)] : [])]
        let pagesInSelection = part != nil ? paged.pageNumber(at: NSMaxRange(sel) - 1) - paged.pageNumber(at: sel.location) + 1 : 0
        let items: [(String, Int, Int)] = [
            (L("Pages"), paged.cards.count, pagesInSelection),
            (L("Words"), all.words, part?.words ?? 0),
            (L("Characters (with spaces)"), all.characters, part?.characters ?? 0),
            (L("Characters (no spaces)"), all.charactersNoSpaces, part?.charactersNoSpaces ?? 0),
            (L("Paragraphs"), all.paragraphs, part?.paragraphs ?? 0),
            (L("Lines"), all.lines, part?.lines ?? 0),
        ]
        for (title, a, b) in items {
            let t = NSTextField(labelWithString: title)
            rows.append([t, n(a)] + (part != nil ? [n(b)] : []))
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 18
        grid.frame.size = grid.fittingSize
        let alert = NSAlert()
        alert.messageText = L("Statistics")
        alert.accessoryView = grid
        alert.addButton(withTitle: L("OK"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Paragraph

    @objc func paragraphAction(_ sender: Any?) {
        let p = (currentAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let k = DocRuler.cm
        func field(_ v: CGFloat, _ unit: CGFloat) -> NSTextField {
            let f = NSTextField(string: String(format: "%.2f", v / unit).replacingOccurrences(of: ".00", with: ""))
            return f
        }
        let alignment = NSPopUpButton(frame: .zero, pullsDown: false)
        alignment.addItems(withTitles: [L("Left"), L("Center"), L("Right"), L("Justify")])
        alignment.selectItem(at: [NSTextAlignment.center: 1, .right: 2, .justified: 3][p.alignment] ?? 0)
        let left = field(p.headIndent, k)
        let right = field(p.tailIndent < 0 ? -p.tailIndent : 0, k)
        let first = field(p.firstLineHeadIndent - p.headIndent, k)
        let before = field(p.paragraphSpacingBefore, 1), after = field(p.paragraphSpacing, 1)
        let spacing = NSPopUpButton(frame: .zero, pullsDown: false)
        spacing.addItems(withTitles: [L("Single"), "1.15", "1.5", L("Double"), L("Exactly")])
        let exact = p.minimumLineHeight > 0 && p.minimumLineHeight == p.maximumLineHeight
        let multiples: [CGFloat] = [1, 1.15, 1.5, 2]
        spacing.selectItem(at: exact ? 4 : multiples.firstIndex { abs($0 - (p.lineHeightMultiple == 0 ? 1 : p.lineHeightMultiple)) < 0.01 } ?? 0)
        let at = field(exact ? p.minimumLineHeight : 14, 1)
        at.placeholderString = L("pt")
        let initial = [left, right, first, before, after, at].map(\.stringValue)
        let initialAlign = alignment.indexOfSelectedItem, initialSpacing = spacing.indexOfSelectedItem
        let alert = NSAlert.form(L("Paragraph"), info: L("Indents in centimetres, spacing in points. A negative first line is a hanging indent."), ok: L("Apply"),
                                 rows: [(L("Alignment:"), alignment), (L("Left indent:"), left), (L("Right indent:"), right), (L("First line:"), first),
                                        (L("Spacing before:"), before), (L("Spacing after:"), after), (L("Line spacing:"), spacing), (L("Exactly (pt):"), at)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func num(_ f: NSTextField) -> CGFloat? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        let changed = zip([left, right, first, before, after, at], initial).map { $0.0.stringValue != $0.1 }
        let alignChanged = alignment.indexOfSelectedItem != initialAlign
        let spacingChanged = spacing.indexOfSelectedItem != initialSpacing || (spacing.indexOfSelectedItem == 4 && changed[5])
        applyParagraph { s in
            if alignChanged { s.alignment = [.left, .center, .right, .justified][max(0, alignment.indexOfSelectedItem)] }
            let firstOffset = s.firstLineHeadIndent - s.headIndent
            if changed[0], let v = num(left) { s.headIndent = max(0, v * k); s.firstLineHeadIndent = max(0, s.headIndent + firstOffset) }
            if changed[1], let v = num(right) { s.tailIndent = -max(0, v * k) }
            if changed[2], let v = num(first) { s.firstLineHeadIndent = max(0, s.headIndent + v * k) }
            if changed[3], let v = num(before) { s.paragraphSpacingBefore = max(0, v) }
            if changed[4], let v = num(after) { s.paragraphSpacing = max(0, v) }
            if spacingChanged {
                if spacing.indexOfSelectedItem == 4, let v = num(at), v > 0 {
                    s.lineHeightMultiple = 0
                    s.minimumLineHeight = v
                    s.maximumLineHeight = v
                } else if spacing.indexOfSelectedItem < 4 {
                    s.lineHeightMultiple = multiples[spacing.indexOfSelectedItem]
                    s.minimumLineHeight = 0
                    s.maximumLineHeight = 0
                }
            }
        }
        textView.undoManager?.setActionName(L("Paragraph"))
        syncRuler()
    }

    // MARK: - Format painter

    /// Click: copy the formatting at the selection, apply it to the next selection. Double click: keep applying until Esc.
    @objc func formatPainterAction(_ sender: Any?) {
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        if painter.armed && clicks < 2 { _ = cancelFormatPainter(); return }
        let attrs = currentAttributes
        painter.characters = attrs.filter { PainterState.keys.contains($0.key) }
        painter.paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        painter.style = attrs[Styles.styleKey] as? String
        painter.sticky = clicks >= 2
        formatStripState()
    }

    func formatStripState() { setStripState(painter.armed, for: #selector(formatPainterAction(_:))) }

    @discardableResult
    func cancelFormatPainter() -> Bool {
        guard painter.armed else { return false }
        painter.characters = nil
        painter.paragraph = nil
        painter.sticky = false
        formatStripState()
        return true
    }

    /// After a click or drag in the text: paint the selection.
    func textViewMouseUp(_ tv: NSTextView) {
        guard let chars = painter.characters, let storage = textView.textStorage else { return }
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        let paragraphs = ranges.map { (storage.string as NSString).paragraphRange(for: $0) }
        let all = (ranges + paragraphs).map { NSValue(range: $0) }
        guard textView.shouldChangeText(inRanges: all, replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges {
            for key in PainterState.keys { storage.removeAttribute(key, range: r) }
            storage.addAttributes(chars, range: r)
        }
        if let source = painter.paragraph {
            for r in paragraphs where r.length > 0 {
                storage.enumerateAttribute(.paragraphStyle, in: r) { v, sub, _ in
                    let target = (v as? NSParagraphStyle) ?? .default
                    let p = source.mutableCopy() as! NSMutableParagraphStyle
                    // Tables and lists stay what they are.
                    p.textBlocks = target.textBlocks
                    p.textLists = target.textLists
                    if !target.textLists.isEmpty { p.tabStops = target.tabStops; p.headIndent = target.headIndent; p.firstLineHeadIndent = target.firstLineHeadIndent }
                    storage.addAttribute(.paragraphStyle, value: p, range: sub)
                }
                if let style = painter.style { storage.addAttribute(Styles.styleKey, value: style, range: r) } else { storage.removeAttribute(Styles.styleKey, range: r) }
            }
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Clone Formatting"))
        if !painter.sticky { cancelFormatPainter() }
    }

    // MARK: - Sections and columns

    @objc func insertSectionBreakAction(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        let sel = textView.selectedRange()
        let at = sel.location
        let section = paged.setup(at: at).section
        var attrs = textView.typingAttributes
        attrs[.docSection] = section
        let ns = storage.string as NSString
        let out = NSMutableAttributedString(string: "\u{000C}", attributes: attrs)
        let next = NSMaxRange(sel) < ns.length ? ns.character(at: NSMaxRange(sel)) : 0
        if next != 10 { out.append(NSAttributedString(string: "\n", attributes: attrs.filter { $0.key != .docSection })) }
        guard textView.shouldChangeText(in: sel, replacementString: out.string) else { return }
        storage.replaceCharacters(in: sel, with: out)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Section Break"))
        textView.setSelectedRange(NSRange(location: at + out.length, length: 0))
        paged.layoutAll()
    }

    @objc func columnsAction(_ sender: Any?) {
        let n = max(1, commandTag(of: sender) + 1)
        changeSetup(L("Columns")) { $0.columns = n }
    }
}
