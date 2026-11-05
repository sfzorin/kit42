import AppKit
import Kit42

extension DocWindowController {
    var styleSheet: StyleSheet { doc?.styles ?? StyleSheet() }

    // MARK: Applying

    func applyParagraphStyle(_ id: String) {
        let textView = activeTextView
        guard let storage = textView.textStorage, let sheet = doc?.styles, sheet[id] != nil else { return }
        let ranges = paragraphRanges.filter { $0.length > 0 }
        if ranges.isEmpty || storage.length == 0 {
            textView.typingAttributes = sheet.attributes(id)
            syncControls()
            return
        }
        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges { sheet.apply(paragraphStyle: id, to: storage, range: r) }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Apply Style"))
        var typing = sheet.attributes(id)
        if let p = storage.attribute(.paragraphStyle, at: ranges[0].location, effectiveRange: nil) { typing[.paragraphStyle] = p }
        textView.typingAttributes = typing
        syncControls()
    }

    /// nil: Default Character Style (removes the character style).
    func applyCharacterStyle(_ id: String?) {
        let textView = activeTextView
        guard let storage = textView.textStorage, let sheet = doc?.styles else { return }
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            // Typing continues in the style.
            let tmp = NSMutableAttributedString(string: " ", attributes: textView.typingAttributes)
            sheet.apply(characterStyle: id, to: tmp, range: NSRange(location: 0, length: 1))
            textView.typingAttributes = tmp.attributes(at: 0, effectiveRange: nil)
            return
        }
        guard textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges { sheet.apply(characterStyle: id, to: storage, range: r) }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Apply Style"))
        syncControls()
    }

    // MARK: Changing the style sheet (undoable together with the text it restyles)

    private func registerStylesUndo(_ list: [DocStyle]) {
        guard let doc else { return }
        doc.undoManager?.registerUndo(withTarget: self) { me in
            guard let d = me.doc else { return }
            let current = d.styles.styles
            d.styles.setAll(list)
            me.registerStylesUndo(current)
            me.stylesDidChange()
        }
    }

    /// Changes the styles; paragraphs (and character ranges) using `reapply` take on the new definition.
    func changeStyles(_ name: String, reapply: String? = nil, _ body: (StyleSheet) -> Void) {
        guard let doc, let storage = textView.textStorage else { return }
        let old = doc.styles.copy()
        let undo = doc.undoManager
        textView.breakUndoCoalescing()
        undo?.beginUndoGrouping()
        body(doc.styles)
        registerStylesUndo(old.styles)
        if let id = reapply, let style = doc.styles[id] {
            if style.kind == .paragraph {
                let ranges = doc.styles.paragraphs(using: id, in: storage)
                if !ranges.isEmpty, textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) {
                    storage.beginEditing()
                    for r in ranges {
                        let own = (storage.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String) ?? "Normal"
                        doc.styles.apply(paragraphStyle: own, to: storage, range: r, from: old, update: true)
                    }
                    storage.endEditing()
                    textView.didChangeText()
                }
            } else {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.docCharStyle, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                    if let s = v as? String, doc.styles.chain(s).contains(id) { ranges.append(r) }
                }
                if !ranges.isEmpty, textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) {
                    storage.beginEditing()
                    for r in ranges { doc.styles.apply(characterStyle: storage.attribute(.docCharStyle, at: r.location, effectiveRange: nil) as? String, to: storage, range: r) }
                    storage.endEditing()
                    textView.didChangeText()
                }
            }
        }
        undo?.setActionName(name)
        undo?.endUndoGrouping()
        stylesDidChange()
    }

    /// Panel, style popup and menus follow the style sheet.
    func stylesDidChange() {
        sidebar.styles.reload()
        rebuildStylePopup()
        syncControls()
    }

    func newStyleFromSelection(character: Bool) {
        guard let storage = textView.textStorage else { return }
        let name = NSTextField(string: "")
        name.placeholderString = L("Style name")
        let alert = NSAlert.form(character ? L("New Character Style") : L("New Paragraph Style"), info: L("The new style takes the formatting of the selection."),
                                 ok: L("Create"), rows: [(L("Name:"), name)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        newStyle(named: name.stringValue, character: character)
        _ = storage
    }

    @discardableResult
    func newStyle(named raw: String, character: Bool) -> String? {
        let textView = activeTextView
        guard let storage = textView.textStorage, let sheet = doc?.styles else { return nil }
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return nil }
        let id = sheet.newId(for: name)
        let at = textView.selectedRange().location
        let current = storage.length > 0 ? storage.attribute(Styles.styleKey, at: min(at, storage.length - 1), effectiveRange: nil) as? String : nil
        var style = StyleSheet.style(from: storage, at: at, id: id, name: name, kind: character ? .character : .paragraph,
                                     basedOn: character ? nil : (current ?? "Normal"))
        if !character { style.next = id }
        changeStyles(L("New Style")) { $0.replace(style) }
        if character { applyCharacterStyle(id) } else { applyParagraphStyle(id) }
        return id
    }

    func updateStyleToMatchSelection(_ id: String) {
        let textView = activeTextView
        guard let storage = textView.textStorage, let sheet = doc?.styles, let old = sheet[id] else { return }
        var s = StyleSheet.style(from: storage, at: textView.selectedRange().location, id: id, name: old.name, kind: old.kind, basedOn: old.basedOn)
        s.next = old.next
        s.builtin = old.builtin
        s.hidden = old.hidden
        s.outlineLevel = old.outlineLevel
        changeStyles(L("Update Style"), reapply: id) { $0.replace(s) }
        if s.kind == .paragraph { applyParagraphStyle(id) }
    }

    func deleteStyle(_ id: String) {
        guard let storage = textView.textStorage, let sheet = doc?.styles, let style = sheet[id], !style.builtin else { return }
        // Its paragraphs fall back to the style it was based on.
        let fallback = style.basedOn ?? "Normal"
        textView.breakUndoCoalescing()
        doc?.undoManager?.beginUndoGrouping()
        if style.kind == .paragraph {
            let ranges = sheet.paragraphs(using: id, in: storage).filter { (storage.attribute(Styles.styleKey, at: $0.location, effectiveRange: nil) as? String) == id }
            if !ranges.isEmpty, textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) {
                storage.beginEditing()
                for r in ranges { sheet.apply(paragraphStyle: fallback, to: storage, range: r) }
                storage.endEditing()
                textView.didChangeText()
            }
        } else {
            var ranges: [NSRange] = []
            storage.enumerateAttribute(.docCharStyle, in: NSRange(location: 0, length: storage.length)) { v, r, _ in if v as? String == id { ranges.append(r) } }
            if !ranges.isEmpty, textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) {
                storage.beginEditing()
                for r in ranges { sheet.apply(characterStyle: nil, to: storage, range: r) }
                storage.endEditing()
                textView.didChangeText()
            }
        }
        changeStyles(L("Delete Style")) { s in
            s.remove(id)
            for var other in s.styles where other.basedOn == id || other.next == id {
                if other.basedOn == id { other.basedOn = fallback }
                if other.next == id { other.next = nil }
                s.replace(other)
            }
        }
        doc?.undoManager?.endUndoGrouping()
    }

    // MARK: Modify Style dialog

    func modifyStyle(_ id: String) {
        guard let sheet = doc?.styles, let style = sheet[id], let changed = styleDialog(style, sheet: sheet) else { return }
        changeStyles(L("Modify Style"), reapply: id) { $0.replace(changed) }
    }

    /// Font, size, colour, spacing, indents, alignment, based on and next style. nil: cancelled.
    func styleDialog(_ style: DocStyle, sheet: StyleSheet) -> DocStyle? {
        let r = style.kind == .paragraph ? sheet.resolved(style.id) : style
        let name = NSTextField(string: style.displayName)
        name.isEditable = !style.builtin
        let parents = sheet.styles.filter { $0.kind == style.kind && $0.id != style.id && !sheet.chain($0.id).contains(style.id) }
        let basedOn = NSPopUpButton(frame: .zero, pullsDown: false)
        basedOn.addItem(withTitle: L("(none)"))
        basedOn.addItems(withTitles: parents.map(\.displayName))
        basedOn.selectItem(at: (parents.firstIndex { $0.id == style.basedOn } ?? -1) + 1)
        let paragraphs = sheet.paragraphStyles
        let next = NSPopUpButton(frame: .zero, pullsDown: false)
        next.addItem(withTitle: L("(same style)"))
        next.addItems(withTitles: paragraphs.map(\.displayName))
        next.selectItem(at: (paragraphs.firstIndex { $0.id == style.next && style.next != style.id } ?? -1) + 1)
        let families = ["Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Palatino", "Avenir Next", "Calibri", "Cambria", "Courier New", "Menlo", "PT Serif", "PT Sans"]
        let font = NSComboBox()
        font.addItems(withObjectValues: families)
        font.stringValue = r.family ?? ""
        font.placeholderString = L("(inherited)")
        let size = NSTextField(string: r.size.map { Self.num($0) } ?? "")
        let bold = NSButton(checkboxWithTitle: L("Bold"), target: nil, action: nil)
        let italic = NSButton(checkboxWithTitle: L("Italic"), target: nil, action: nil)
        let underline = NSButton(checkboxWithTitle: L("Underline"), target: nil, action: nil)
        for (b, v) in [(bold, r.isBold), (italic, r.italic), (underline, r.underline)] {
            b.allowsMixedState = style.kind == .character
            b.state = v == nil ? .mixed : (v! ? .on : .off)
        }
        let traits = NSStackView(views: [bold, italic, underline])
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        color.color = r.color ?? .black
        var rows: [(String, NSView)] = [(L("Name:"), name), (L("Based on:"), basedOn)]
        if style.kind == .paragraph { rows.append((L("Next style:"), next)) }
        rows += [(L("Font:"), font), (L("Size (pt):"), size), ("", traits), (L("Colour:"), color)]
        let align = NSPopUpButton(frame: .zero, pullsDown: false)
        align.addItems(withTitles: [L("Left"), L("Centre"), L("Right"), L("Justify")])
        align.selectItem(at: [NSTextAlignment.center: 1, .right: 2, .justified: 3][r.alignment ?? .left] ?? 0)
        let before = NSTextField(string: Self.num(r.spaceBefore ?? 0)), after = NSTextField(string: Self.num(r.spaceAfter ?? 0))
        let line = NSPopUpButton(frame: .zero, pullsDown: false)
        let multiples: [CGFloat] = [1, 1.15, 1.5, 2]
        line.addItems(withTitles: [L("Single"), "1.15", "1.5", L("Double")])
        line.selectItem(at: multiples.firstIndex { abs($0 - (r.lineHeightMultiple ?? 1.15)) < 0.01 } ?? 1)
        let k = DocRuler.cm
        let left = NSTextField(string: Self.num((r.headIndent ?? 0) / k)), right = NSTextField(string: Self.num(-(r.tailIndent ?? 0) / k))
        let first = NSTextField(string: Self.num(((r.firstLineHeadIndent ?? 0) - (r.headIndent ?? 0)) / k))
        if style.kind == .paragraph {
            rows += [(L("Alignment:"), align), (L("Spacing before (pt):"), before), (L("Spacing after (pt):"), after), (L("Line spacing:"), line),
                     (L("Left indent (cm):"), left), (L("Right indent (cm):"), right), (L("First line (cm):"), first)]
        }
        let alert = NSAlert.form(L("Modify Style"), info: L("Changes apply to every paragraph in this style."), ok: L("OK"), rows: rows)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        func n(_ f: NSTextField) -> CGFloat? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        var s = style
        if !style.builtin, !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { s.name = name.stringValue }
        s.basedOn = basedOn.indexOfSelectedItem > 0 ? parents[basedOn.indexOfSelectedItem - 1].id : nil
        if style.kind == .paragraph { s.next = next.indexOfSelectedItem > 0 ? paragraphs[next.indexOfSelectedItem - 1].id : nil }
        let fam = font.stringValue.trimmingCharacters(in: .whitespaces)
        s.family = fam.isEmpty ? nil : fam
        s.size = n(size).map { max(4, min(400, $0)) }
        s.weight = bold.state == .mixed ? nil : (bold.state == .on ? 9 : 5)
        s.italic = italic.state == .mixed ? nil : italic.state == .on
        s.underline = underline.state == .mixed ? nil : underline.state == .on
        s.color = color.color
        if style.kind == .paragraph {
            s.alignment = [.left, .center, .right, .justified][max(0, align.indexOfSelectedItem)]
            s.spaceBefore = n(before)
            s.spaceAfter = n(after)
            s.lineHeightMultiple = multiples[max(0, line.indexOfSelectedItem)]
            let head = (n(left) ?? 0) * k
            s.headIndent = head
            s.tailIndent = -(n(right) ?? 0) * k
            s.firstLineHeadIndent = head + (n(first) ?? 0) * k
        }
        return s
    }

    static func num(_ v: CGFloat) -> String {
        let s = String(format: "%.2f", v)
        return s.hasSuffix(".00") ? String(s.dropLast(3)) : s.hasSuffix("0") ? String(s.dropLast()) : s
    }

    // MARK: Menu commands

    /// Format › Styles (⌘T): the Styles panel.
    @objc func toggleStylesAction(_ sender: Any?) { toggleSidebar(.styles) }
    /// View › Navigator (F5).
    @objc func toggleNavigatorAction(_ sender: Any?) { toggleSidebar(.navigator) }

    @objc func newStyleAction(_ sender: Any?) { newStyleFromSelection(character: false) }
    @objc func updateStyleAction(_ sender: Any?) {
        let a = currentAttributes
        updateStyleToMatchSelection(a[Styles.styleKey] as? String ?? "Normal")
    }
    @objc func modifyStyleAction(_ sender: Any?) { modifyStyle(currentAttributes[Styles.styleKey] as? String ?? "Normal") }
    @objc func applyCharacterStyleAction(_ sender: Any?) {
        let ids = [nil] + styleSheet.characterStyles.map(\.id)
        let i = commandTag(of: sender)
        guard ids.indices.contains(i) else { return }
        applyCharacterStyle(ids[i])
    }
}
