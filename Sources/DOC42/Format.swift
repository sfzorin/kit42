import AppKit
import CoreText
import Kit42


extension DocWindowController {
    /// Clear presentation attributes without deleting embedded content or document structure.
    /// A table cell and a list paragraph remain a table cell and a list paragraph.
    func clearDirectFormatting() {
        let tv = activeTextView
        guard let storage = tv.textStorage else { return }
        func cleared(_ original: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = original
            for key in PainterState.keys + [.underlineColor, .strikethroughColor, .strokeWidth, .strokeColor,
                                            .docCharStyle, .docAllCaps, .docSmallCaps, .docDropCap, Styles.styleKey] {
                result[key] = nil
            }
            result.merge(Styles.normal.attributes) { _, normal in normal }
            if let originalParagraph = original[.paragraphStyle] as? NSParagraphStyle,
               let paragraph = (result[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                paragraph.textBlocks = originalParagraph.textBlocks.filter { $0 is NSTextTableBlock }
                paragraph.textLists = originalParagraph.textLists
                if !paragraph.textLists.isEmpty {
                    paragraph.headIndent = originalParagraph.headIndent
                    paragraph.firstLineHeadIndent = originalParagraph.firstLineHeadIndent
                    paragraph.tailIndent = originalParagraph.tailIndent
                    paragraph.tabStops = originalParagraph.tabStops
                }
                result[.paragraphStyle] = paragraph
            }
            if original[.link] != nil {
                result[.foregroundColor] = Self.linkColor
                result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if original[.docNote] != nil { result[.superscript] = original[.superscript] }
            return result
        }
        let ranges = tv.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.isEmpty {
            tv.typingAttributes = cleared(tv.typingAttributes)
            syncControls()
            return
        }
        guard tv.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                storage.setAttributes(cleared(attributes), range: run)
            }
        }
        storage.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName(L("Clear Formatting"))
        syncControls()
    }

    // MARK: - Character dialog

    static let underlineChoices: [(String, Int)] = [
        (L("None"), 0), (L("Single"), NSUnderlineStyle.single.rawValue), (L("Double"), NSUnderlineStyle.double.rawValue),
        (L("Thick"), NSUnderlineStyle.thick.rawValue), (L("Dotted"), NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue),
        (L("Dashed"), NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue),
        (L("Words only"), NSUnderlineStyle.single.rawValue | NSUnderlineStyle.byWord.rawValue),
    ]

    struct CharacterOptions {
        var family: String?
        var size: CGFloat?
        var bold: Bool?
        var italic: Bool?
        var color: NSColor?
        /// .some(nil): no highlight.
        var highlight: NSColor??
        var allCaps: Bool?
        var smallCaps: Bool?
        /// 1 superscript, -1 subscript, 0 normal.
        var position: Int?
        var kern: CGFloat?
        var underline: Int?
        /// 0 none, 1 single, 2 double.
        var strike: Int?
    }

    @objc func characterAction(_ sender: Any?) {
        let a = currentAttributes
        let font = a[.font] as? NSFont ?? Styles.normal.font
        let traits = NSFontManager.shared.traits(of: font)
        let family = NSComboBox()
        family.addItems(withObjectValues: ["Helvetica Neue", "Arial", "Times New Roman", "Georgia", "Palatino", "Avenir Next", "Calibri", "Cambria", "Courier New", "Menlo", "PT Serif", "PT Sans", "Hoefler Text"])
        family.stringValue = font.familyName ?? ""
        let size = NSTextField(string: Self.num(font.pointSize))
        let bold = NSButton(checkboxWithTitle: L("Bold"), target: nil, action: nil)
        bold.state = traits.contains(.boldFontMask) ? .on : .off
        let italic = NSButton(checkboxWithTitle: L("Italic"), target: nil, action: nil)
        italic.state = traits.contains(.italicFontMask) ? .on : .off
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        color.color = a[.foregroundColor] as? NSColor ?? .black
        let highlight = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        highlight.color = a[.backgroundColor] as? NSColor ?? .yellow
        let noHighlight = NSButton(checkboxWithTitle: L("No highlight"), target: nil, action: nil)
        noHighlight.state = a[.backgroundColor] == nil ? .on : .off
        let caps = NSButton(checkboxWithTitle: L("All caps"), target: nil, action: nil)
        caps.state = a[.docAllCaps] as? Bool == true ? .on : .off
        let small = NSButton(checkboxWithTitle: L("Small caps"), target: nil, action: nil)
        small.state = a[.docSmallCaps] as? Bool == true ? .on : .off
        let position = NSPopUpButton(frame: .zero, pullsDown: false)
        position.addItems(withTitles: [L("Normal"), L("Superscript"), L("Subscript")])
        let sup = a[.superscript] as? Int ?? 0
        position.selectItem(at: sup > 0 ? 1 : sup < 0 ? 2 : 0)
        let kern = NSTextField(string: Self.num(CGFloat((a[.kern] as? NSNumber)?.doubleValue ?? 0)))
        let underline = NSPopUpButton(frame: .zero, pullsDown: false)
        underline.addItems(withTitles: Self.underlineChoices.map(\.0))
        underline.selectItem(at: Self.underlineChoices.firstIndex { $0.1 == (a[.underlineStyle] as? Int ?? 0) } ?? 0)
        let strike = NSPopUpButton(frame: .zero, pullsDown: false)
        strike.addItems(withTitles: [L("None"), L("Single"), L("Double")])
        let st = a[.strikethroughStyle] as? Int ?? 0
        strike.selectItem(at: st == 0 ? 0 : st & 0xF == NSUnderlineStyle.double.rawValue ? 2 : 1)
        let alert = NSAlert.form(L("Character"), ok: L("Apply"), rows: [
            (L("Font:"), family), (L("Size (pt):"), size), ("", NSStackView(views: [bold, italic])), (L("Colour:"), color),
            (L("Highlight:"), highlight), ("", noHighlight), ("", NSStackView(views: [caps, small])), (L("Position:"), position),
            (L("Spacing (pt):"), kern), (L("Underline:"), underline), (L("Strikethrough:"), strike),
        ])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func n(_ f: NSTextField) -> CGFloat? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        var o = CharacterOptions()
        o.family = family.stringValue.isEmpty ? nil : family.stringValue
        o.size = n(size)
        o.bold = bold.state == .on
        o.italic = italic.state == .on
        o.color = color.color
        o.highlight = noHighlight.state == .on ? .some(nil) : .some(highlight.color)
        o.allCaps = caps.state == .on
        o.smallCaps = small.state == .on
        o.position = [0, 1, -1][max(0, position.indexOfSelectedItem)]
        o.kern = n(kern)
        o.underline = Self.underlineChoices[max(0, underline.indexOfSelectedItem)].1
        o.strike = strike.indexOfSelectedItem
        applyCharacterOptions(o)
    }

    /// The font with real small capitals when it has them.
    static func smallCapsFont(_ font: NSFont, on: Bool) -> NSFont {
        let features: [[NSFontDescriptor.FeatureKey: Int]] = on ? [[.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]] : []
        let d = font.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    /// Whether a font draws small capitals itself (else DOC42 shows capitals).
    static func hasSmallCaps(_ font: NSFont) -> Bool {
        guard let features = CTFontCopyFeatures(font as CTFont) as? [[String: Any]] else { return false }
        return features.contains { ($0[kCTFontFeatureTypeIdentifierKey as String] as? Int) == kLowerCaseType }
    }

    func applyCharacterOptions(_ o: CharacterOptions) {
        let tv = activeTextView
        guard let storage = tv.textStorage else { return }
        let ranges = tv.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        func transform(_ a: inout [NSAttributedString.Key: Any]) {
            var font = a[.font] as? NSFont ?? Styles.normal.font
            let fm = NSFontManager.shared
            if let f = o.family { font = fm.convert(font, toFamily: f) }
            if let s = o.size, s > 0 { font = fm.convert(font, toSize: s) }
            if let b = o.bold { font = b ? fm.convert(font, toHaveTrait: .boldFontMask) : fm.convert(font, toNotHaveTrait: .boldFontMask) }
            if let i = o.italic { font = i ? fm.convert(font, toHaveTrait: .italicFontMask) : fm.convert(font, toNotHaveTrait: .italicFontMask) }
            if let sc = o.smallCaps { font = Self.smallCapsFont(font, on: sc && Self.hasSmallCaps(font)) }
            a[.font] = font
            if let c = o.color { a[.foregroundColor] = c }
            if let h = o.highlight { a[.backgroundColor] = h }
            if let c = o.allCaps { a[.docAllCaps] = c ? true : nil }
            if let c = o.smallCaps { a[.docSmallCaps] = c ? true : nil }
            if let p = o.position { a[.superscript] = p == 0 ? nil : p }
            if let k = o.kern { a[.kern] = abs(k) < 0.01 ? nil : k }
            if let u = o.underline { a[.underlineStyle] = u == 0 ? nil : u }
            if let s = o.strike { a[.strikethroughStyle] = s == 0 ? nil : (s == 2 ? NSUnderlineStyle.double.rawValue : NSUnderlineStyle.single.rawValue) }
        }
        if ranges.isEmpty {
            var a = tv.typingAttributes
            transform(&a)
            tv.typingAttributes = a
            return
        }
        guard tv.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for r in ranges {
            storage.enumerateAttributes(in: r) { attrs, sub, _ in
                var a = attrs
                transform(&a)
                storage.setAttributes(a, range: sub)
            }
        }
        storage.endEditing()
        tv.didChangeText()
        tv.undoManager?.setActionName(L("Character"))
        syncControls()
    }

    // MARK: - Paragraph borders and background

    struct BorderOptions {
        /// 0 none, 1 box, 2 top, 3 bottom, 4 top and bottom, 5 left.
        var preset = 1
        var width: CGFloat = 0.75
        var color: NSColor = .black
        var padding: CGFloat = 4
        var background: NSColor?
    }

    @objc func paragraphBordersAction(_ sender: Any?) {
        let block = (currentAttributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last.flatMap { $0 is NSTextTableBlock ? nil : $0 }
        let preset = NSPopUpButton(frame: .zero, pullsDown: false)
        preset.addItems(withTitles: [L("None"), L("Box"), L("Top"), L("Bottom"), L("Top and bottom"), L("Left")])
        if let b = block {
            let w = [NSRectEdge.minX, .minY, .maxX, .maxY].map { b.width(for: .border, edge: $0) > 0 }
            preset.selectItem(at: w.allSatisfy { $0 } ? 1 : (w[1] && w[3] ? 4 : w[1] ? 2 : w[3] ? 3 : w[0] ? 5 : 0))
        } else { preset.selectItem(at: 1) }
        let maxWidth = block.map { b in [NSRectEdge.minX, .minY, .maxX, .maxY].map { b.width(for: .border, edge: $0) }.max() ?? 0.75 } ?? 0.75
        let width = NSTextField(string: Self.num(maxWidth > 0 ? maxWidth : 0.75))
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        color.color = block?.borderColor(for: .minY) ?? block?.borderColor(for: .minX) ?? .black
        let padding = NSTextField(string: Self.num(block?.width(for: .padding, edge: .minY) ?? 4))
        let background = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        background.color = block?.backgroundColor ?? NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 1)
        let noBackground = NSButton(checkboxWithTitle: L("No background"), target: nil, action: nil)
        noBackground.state = block?.backgroundColor == nil ? .on : .off
        let alert = NSAlert.form(L("Borders and Background"), info: L("For the selected paragraphs; neighbouring paragraphs share one box."), ok: L("Apply"),
                                 rows: [(L("Borders:"), preset), (L("Line width (pt):"), width), (L("Line colour:"), color),
                                        (L("Spacing to text (pt):"), padding), (L("Background:"), background), ("", noBackground)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func n(_ f: NSTextField) -> CGFloat? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        applyParagraphBorders(BorderOptions(preset: preset.indexOfSelectedItem, width: n(width) ?? 0.75, color: color.color, padding: n(padding) ?? 4,
                                            background: noBackground.state == .on ? nil : background.color))
    }

    static func paragraphBlock(_ o: BorderOptions) -> NSTextBlock? {
        guard o.preset != 0 || o.background != nil else { return nil }
        let b = NSTextBlock()
        let edges: [NSRectEdge: Bool] = [.minX: [1, 5].contains(o.preset), .maxX: o.preset == 1, .minY: [1, 2, 4].contains(o.preset), .maxY: [1, 3, 4].contains(o.preset)]
        for (e, on) in edges {
            b.setWidth(on ? o.width : 0, type: .absoluteValueType, for: .border, edge: e)
            b.setBorderColor(o.color, for: e)
        }
        b.setWidth(o.padding, type: .absoluteValueType, for: .padding)
        b.setValue(100, type: .percentageValueType, for: .width)
        b.backgroundColor = o.background
        return b
    }

    func applyParagraphBorders(_ o: BorderOptions) {
        let textView = activeTextView
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let ranges = paragraphRanges.filter { $0.length > 0 }
        guard !ranges.isEmpty, textView.shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        let block = Self.paragraphBlock(o)
        storage.beginEditing()
        for r in ranges {
            storage.enumerateAttribute(.paragraphStyle, in: r) { v, sub, _ in
                let p = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                guard !(p.textBlocks.last is NSTextTableBlock) else { return }   // table cells have their own borders
                p.textBlocks = block.map { [$0] } ?? []
                storage.addAttribute(.paragraphStyle, value: p, range: sub)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Borders and Background"))
    }

    // MARK: - Drop caps

    @objc func dropCapAction(_ sender: Any?) {
        guard headerEditor == nil, let storage = textView.textStorage, storage.length > 0 else { return }
        let p = (storage.string as NSString).paragraphRange(for: NSRange(location: textView.selectedRange().location, length: 0))
        let current = p.location < storage.length ? storage.attribute(.docDropCap, at: p.location, effectiveRange: nil) as? Int : nil
        let lines = NSPopUpButton(frame: .zero, pullsDown: false)
        lines.addItems(withTitles: [L("None"), "2", "3", "4", "5"])
        lines.selectItem(at: current.map { max(0, $0 - 1) } ?? 2)
        let alert = NSAlert.form(L("Drop Cap"), info: L("The paragraph's first letter, enlarged over several lines."), ok: L("Apply"), rows: [(L("Lines:"), lines)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setDropCap(lines.indexOfSelectedItem == 0 ? nil : lines.indexOfSelectedItem + 1)
    }

    func setDropCap(_ lines: Int?) {
        guard headerEditor == nil, let storage = textView.textStorage, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let p = ns.paragraphRange(for: NSRange(location: textView.selectedRange().location, length: 0))
        // The first letter (after a list marker).
        var at = p.location
        if let m = ListNumbering.currentMarker(storage, p) { at = NSMaxRange(m) }
        guard at < NSMaxRange(p), ns.character(at: at) != 10 else { NSSound.beep(); return }
        let r = NSRange(location: p.location, length: p.length)
        guard textView.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.removeAttribute(.docDropCap, range: r)
        if let lines { storage.addAttribute(.docDropCap, value: lines, range: NSRange(location: at, length: 1)) }
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Drop Cap"))
        paged.layoutManager.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        paged.scheduleReconcile()
    }

    // MARK: - Page background, watermark, hyphenation

    private func setPageLook(_ name: String, background: NSColor??, watermark: String?, hyphenate: Bool?) {
        guard let doc else { return }
        let old = (doc.background, doc.watermark, doc.hyphenate)
        if let b = background { doc.background = b }
        if let w = watermark { doc.watermark = w }
        if let h = hyphenate { doc.hyphenate = h }
        doc.undoManager?.registerUndo(withTarget: self) { me in
            me.setPageLook(name, background: .some(old.0), watermark: old.1, hyphenate: old.2)
        }
        doc.undoManager?.setActionName(name)
    }

    @objc func pageBackgroundAction(_ sender: Any?) {
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        color.color = doc?.background ?? NSColor(calibratedRed: 1, green: 0.98, blue: 0.9, alpha: 1)
        let none = NSButton(checkboxWithTitle: L("No colour (white)"), target: nil, action: nil)
        none.state = doc?.background == nil ? .on : .off
        let alert = NSAlert.form(L("Page Background"), ok: L("Apply"), rows: [(L("Colour:"), color), ("", none)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setPageLook(L("Page Background"), background: .some(none.state == .on ? nil : color.color), watermark: nil, hyphenate: nil)
    }

    func setPageBackground(_ c: NSColor?) { setPageLook(L("Page Background"), background: .some(c), watermark: nil, hyphenate: nil) }

    @objc func watermarkAction(_ sender: Any?) {
        let text = NSTextField(string: doc?.watermark ?? "")
        text.placeholderString = L("For example: DRAFT")
        let alert = NSAlert.form(L("Watermark"), info: L("Light grey text across every page; leave empty for none."), ok: L("Apply"), rows: [(L("Text:"), text)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setWatermark(text.stringValue)
    }

    func setWatermark(_ s: String) { setPageLook(L("Watermark"), background: nil, watermark: s.trimmingCharacters(in: .whitespaces), hyphenate: nil) }

    @objc func toggleHyphenationAction(_ sender: Any?) {
        setPageLook(L("Hyphenation"), background: nil, watermark: nil, hyphenate: !(doc?.hyphenate ?? false))
    }
}

// MARK: - Showing caps and drop caps

extension PagedView {
    /// Lowercase letters of all-caps (and small-caps without the font feature) text get capital glyphs.
    static func capitalGlyphs(_ storage: NSTextStorage, _ glyphs: UnsafePointer<CGGlyph>, _ props: inout [NSLayoutManager.GlyphProperty],
                              _ charIndexes: UnsafePointer<Int>, _ count: Int, _ font: NSFont) -> [CGGlyph]? {
        var out: [CGGlyph]?
        let ns = storage.string as NSString
        for i in 0..<count {
            let c = charIndexes[i]
            guard c < storage.length else { continue }
            let caps = storage.attribute(.docAllCaps, at: c, effectiveRange: nil) as? Bool == true
            let small = storage.attribute(.docSmallCaps, at: c, effectiveRange: nil) as? Bool == true && !DocWindowController.hasSmallCaps(font)
            if storage.attribute(.docDropCap, at: c, effectiveRange: nil) != nil {
                props[i] = .null
                if out == nil { out = Array(UnsafeBufferPointer(start: glyphs, count: count)) }
                continue
            }
            guard caps || small else { continue }
            // One character, one glyph (ligatures keep their glyphs).
            if i + 1 < count, charIndexes[i + 1] != c + 1 { continue }
            let ch = ns.character(at: c)
            let upper = String(utf16CodeUnits: [ch], count: 1).uppercased().utf16
            guard upper.count == 1, let u = upper.first, u != ch else { continue }
            var uc = u
            var g: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(font as CTFont, &uc, &g, 1) {
                if out == nil { out = Array(UnsafeBufferPointer(start: glyphs, count: count)) }
                out![i] = g
            }
        }
        return out
    }

    /// Drop caps on a page column: the room they take (container coordinates).
    func dropCaps(in container: NSTextContainer) -> [(rect: NSRect, index: Int)] {
        guard let storage = layoutManager.textStorage else { return [] }
        let glyphs = layoutManager.glyphRange(for: container)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var out: [(NSRect, Int)] = []
        storage.enumerateAttribute(.docDropCap, in: chars) { v, r, _ in
            guard let lines = v as? Int, lines > 1, let cap = layoutManager.dropCap(at: r.location, lines: lines) else { return }
            out.append((cap.rect, r.location))
        }
        return out
    }

    static func dropCapFont(_ font: NSFont, lines: Int, lineHeight: CGFloat) -> NSFont {
        // Cap height spanning `lines` lines: from the first line's cap top to the last line's baseline.
        let target = lineHeight * CGFloat(lines - 1) + font.capHeight
        let ratio = max(0.5, font.capHeight / max(1, font.pointSize))
        return NSFontManager.shared.convert(font, toSize: target / ratio)
    }
}
