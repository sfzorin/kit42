import AppKit
import Kit42

/// Scaled host for the text view: bounds in slide points, frame in canvas pixels.
final class EditorContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Text view used for in-place editing (TextKit 1, same layout as the renderer).
final class SlideTextView: NSTextView {
    weak var editor: TextEditController?

    override func insertTab(_ sender: Any?) {
        if editor?.handleTab(back: false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if editor?.handleTab(back: true) == true { return }
        super.insertBacktab(sender)
    }

    override func cancelOperation(_ sender: Any?) { editor?.end() }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    // Text typed after a bullet must not become part of the marker.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var n = newValue
            n.removeValue(forKey: .pptMarker)
            super.typingAttributes = n
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘↩ ends editing.
        if event.keyCode == 36, event.modifierFlags.contains(.command) { editor?.end(); return }
        super.keyDown(with: event)
    }
}

final class TextEditController: NSObject, NSTextViewDelegate {
    weak var canvas: SlideCanvas?
    let container = EditorContainer()
    private(set) var textView: SlideTextView!
    private(set) var objectID: Int?
    private(set) var cell: (Int, Int)?
    private var body = TextBody()
    private var object: SlideObject?
    private var context: TextContext?
    private var normalizing = false
    private let undo = UndoManager()
    /// Height grown by typing (auto-sizing text boxes, table rows).
    private var grownHeight: CGFloat?

    var isActive: Bool { objectID != nil }

    override init() {
        super.init()
        makeTextView()
    }

    private func makeTextView() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        let tc = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        tc.widthTracksTextView = true
        manager.addTextContainer(tc)
        let tv = SlideTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: tc)
        tv.editor = self
        tv.isRichText = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.delegate = self
        tv.focusRingType = .none
        textView = tv
        container.addSubview(tv)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: - Begin / end

    /// Starts editing an object's text (or a table cell) at a point (slide coordinates).
    func begin(_ o: SlideObject, cell: (Int, Int)? = nil, at point: CGPoint?, selectAll: Bool = false) {
        guard let canvas, let owner = canvas.owner else { return }
        if o.kind == .table, cell == nil, o.table != nil { begin(o, cell: (0, 0), at: point, selectAll: selectAll); return }
        end()
        objectID = o.id
        self.cell = cell
        object = o
        grownHeight = nil
        var c = TextContext(deck: owner.deck, slide: owner.displayedSlide, object: o, number: Renderer.number(of: owner.current, deck: owner.deck))
        if let cell, let t = o.table {
            body = t.cells[cell.0][cell.1].text
            c.cellDefaults = Renderer.cellDefaults(t, row: cell.0)
            TableEditing.current = (o.id, cell.0, cell.1)
        } else {
            body = o.text ?? TextBody()
            let r = Renderer.textFrame(o)
            c.scale = Renderer.fitScale(body, c, width: body.wrap ? r.width : 10000, height: r.height)
        }
        context = c
        let attributed = TextRender.attributed(body, c, forEditing: true)
        textView.textStorage?.setAttributedString(attributed)
        textView.typingAttributes = attributed.length > 0 ? attributed.attributes(at: max(0, attributed.length - 1), effectiveRange: nil) : TextRender.typingAttributes(body, c)
        let color = (textView.typingAttributes[.foregroundColor] as? NSColor) ?? .black
        textView.insertionPointColor = color
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6)]
        undo.removeAllActions()
        canvas.addSubview(container)
        layout()
        canvas.window?.makeFirstResponder(textView)
        if selectAll {
            textView.selectAll(nil)
        } else if let point {
            let local = containerPoint(point)
            let i = textView.characterIndexForInsertion(at: textView.convert(local, from: container))
            textView.setSelectedRange(NSRange(location: firstContentIndex(atOrAfter: i), length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        canvas.needsDisplay = true
        owner.formatBar.sync()
    }

    /// Slide point → container coordinates (container bounds are the object's box in points).
    private func containerPoint(_ p: CGPoint) -> CGPoint {
        guard let o = object else { return p }
        var origin = o.frame.origin
        if let cell, let t = o.table { origin.x += t.rect(row: cell.0, column: cell.1).minX; origin.y += t.rect(row: cell.0, column: cell.1).minY }
        let c = CGPoint(x: o.frame.midX, y: o.frame.midY)
        let q = canvas?.rotate(p, around: c, by: -o.rotation * .pi / 180) ?? p
        return CGPoint(x: q.x - origin.x, y: q.y - origin.y)
    }

    /// Box being edited, in the object's coordinates.
    private var box: CGRect {
        guard let o = object else { return .zero }
        if let cell, let t = o.table {
            let r = t.rect(row: cell.0, column: cell.1)
            return CGRect(origin: .zero, size: CGSize(width: r.width, height: max(r.height, grownHeight ?? 0)))
        }
        return CGRect(origin: .zero, size: CGSize(width: o.frame.width, height: max(o.frame.height, grownHeight ?? 0)))
    }

    /// Places the container over the object and the text view by its anchor.
    func layout() {
        guard isActive, let canvas, let o = object else { return }
        var frameInSlide = CGRect(origin: o.frame.origin, size: box.size)
        if let cell, let t = o.table {
            let r = t.rect(row: cell.0, column: cell.1)
            frameInSlide.origin = CGPoint(x: o.frame.minX + r.minX, y: o.frame.minY + r.minY)
        }
        let vf = canvas.toView(frameInSlide)
        container.frameCenterRotation = 0
        container.frame = vf
        container.bounds = CGRect(origin: .zero, size: frameInSlide.size)
        if o.rotation != 0, cell == nil { container.frameCenterRotation = -o.rotation }
        let ins = body.insets
        var tr: CGRect
        if cell != nil {
            tr = CGRect(x: ins.left, y: ins.top, width: max(4, box.width - ins.left - ins.right), height: max(4, box.height - ins.top - ins.bottom))
        } else {
            var oo = o
            oo.frame.size = box.size
            tr = Renderer.textFrame(oo)
        }
        let width = body.wrap ? tr.width : max(tr.width, 4000)
        textView.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = max(textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0, lineHeight)
        var y = tr.minY
        switch body.anchor {
        case .top: break
        case .middle: y = tr.minY + (tr.height - used) / 2
        case .bottom: y = tr.maxY - used
        }
        var x = tr.minX
        if !body.wrap {
            let w = (textView.layoutManager?.usedRect(for: textView.textContainer!).width ?? 0) + 4
            let align = (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left
            if align == .center { x = tr.midX - w / 2 } else if align == .right { x = tr.maxX - w }
            textView.textContainer?.size = CGSize(width: w, height: .greatestFiniteMagnitude)
            textView.frame = CGRect(x: x, y: y, width: w, height: used)
        } else {
            textView.frame = CGRect(x: x, y: y, width: width, height: used)
        }
        // Text boxes that size to their text grow while typing.
        let needed = used + ins.top + ins.bottom
        if (body.autofit == .resize || cell != nil), needed > (cell != nil ? (o.table.map { $0.rect(row: cell!.0, column: cell!.1).height } ?? 0) : o.frame.height) + 0.5 {
            if grownHeight == nil || abs((grownHeight ?? 0) - needed) > 0.5 {
                grownHeight = needed
                layout()
                return
            }
        }
        canvas.needsDisplay = true
    }

    private var lineHeight: CGFloat {
        let f = (textView.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 18)
        return textView.layoutManager?.defaultLineHeight(for: f) ?? f.pointSize * 1.2
    }

    /// Ends editing and writes the text back (one undo step).
    func end() {
        guard isActive, let canvas, let owner = canvas.owner, let o = object else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        var newBody = body
        newBody.paragraphs = TextRender.paragraphs(from: textView.textStorage ?? NSAttributedString())
        let id = o.id, cell = self.cell, grown = grownHeight
        objectID = nil
        self.cell = nil
        object = nil
        TableEditing.current = nil
        container.removeFromSuperview()
        if canvas.window?.firstResponder === textView { canvas.window?.makeFirstResponder(canvas) }
        var s = owner.displayedSlide
        if let cell {
            guard newBody != o.table?.cells[cell.0][cell.1].text else { canvas.needsDisplay = true; return }
            s.update(id) { obj in
                guard var t = obj.table else { return }
                t.cells[cell.0][cell.1].text = newBody
                if let g = grown, g > t.rows[cell.0] {
                    let extra = g - t.rect(row: cell.0, column: cell.1).height
                    t.rows[cell.0] += extra
                    obj.frame.size.height += extra
                }
                obj.table = t
            }
        } else {
            if newBody == o.text, grown == nil { canvas.needsDisplay = true; return }
            if o.placeholder == nil, o.kind == .textBox, newBody.isEmpty {
                s.objects.removeAll { $0.id == id }
                owner.selection = []
                owner.commit(slide: s, name: L("Delete"))
                return
            }
            s.update(id) { obj in
                obj.text = newBody
                if let g = grown, newBody.autofit == .resize { obj.frame.size.height = g }
            }
        }
        owner.commit(slide: s, name: L("Typing"))
    }

    // MARK: - Changes while typing

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        var t = textView.typingAttributes
        if t[.pptMarker] != nil { t.removeValue(forKey: .pptMarker); textView.typingAttributes = t }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !normalizing, !textView.hasMarkedText() else { layout(); return }
        normalizeMarkers()
        layout()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !normalizing else { return }
        // Keep the caret out of bullet markers.
        let r = textView.selectedRange()
        if r.length == 0, let s = textView.textStorage, r.location < s.length, s.attribute(.pptMarker, at: r.location, effectiveRange: nil) != nil {
            textView.setSelectedRange(NSRange(location: firstContentIndex(atOrAfter: r.location), length: 0))
        }
        canvas?.owner?.formatBar.sync()
    }

    /// Bullets and numbers follow the paragraphs (new paragraph, deleted marker, renumbering).
    private func normalizeMarkers() {
        guard let storage = textView.textStorage, let c = context else { return }
        var b = body
        b.paragraphs = TextRender.paragraphs(from: storage)
        let fresh = TextRender.attributed(b, c, forEditing: true)
        guard fresh.string != storage.string else { return }
        replaceStorage(with: fresh)
    }

    private func replaceStorage(with fresh: NSAttributedString) {
        guard let storage = textView.textStorage else { return }
        normalizing = true
        let sel = textView.selectedRange()
        let a = contentOffset(sel.location), z = contentOffset(NSMaxRange(sel))
        let typing = textView.typingAttributes
        storage.beginEditing()
        storage.setAttributedString(fresh)
        storage.endEditing()
        let start = index(forContent: a), stop = index(forContent: z)
        textView.setSelectedRange(NSRange(location: start, length: max(0, stop - start)))
        if sel.length == 0, let box = typing[.pptRun] as? RunBox, storage.length == 0 || start >= storage.length {
            var t = textView.typingAttributes
            t[.pptRun] = box
            textView.typingAttributes = t
        }
        normalizing = false
    }

    func contentOffset(_ index: Int) -> Int {
        guard let s = textView.textStorage else { return index }
        var n = 0
        let limit = min(index, s.length)
        var i = 0
        while i < limit {
            var r = NSRange()
            let marker = s.attribute(.pptMarker, at: i, effectiveRange: &r) != nil
            let end = min(NSMaxRange(r), limit)
            if !marker { n += end - i }
            i = end
        }
        return n
    }

    func index(forContent offset: Int) -> Int {
        guard let s = textView.textStorage else { return offset }
        var n = 0, i = 0
        while i < s.length {
            var r = NSRange()
            let marker = s.attribute(.pptMarker, at: i, effectiveRange: &r) != nil
            if marker { i = NSMaxRange(r); continue }
            let len = NSMaxRange(r) - i
            if n + len >= offset { return i + (offset - n) }
            n += len
            i = NSMaxRange(r)
        }
        return s.length
    }

    private func firstContentIndex(atOrAfter i: Int) -> Int {
        guard let s = textView.textStorage else { return i }
        var k = min(i, s.length)
        while k < s.length, s.attribute(.pptMarker, at: k, effectiveRange: nil) != nil { k += 1 }
        return k
    }

    // MARK: - Formatting while editing

    /// Character formatting on the selection (or the typing attributes).
    func applyRun(_ f: (inout RunProps) -> Void) {
        guard let storage = textView.textStorage, let c = context else { return }
        let r = textView.selectedRange()
        if r.length == 0 {
            // An empty paragraph keeps the formatting as its end properties.
            if let s = textView.textStorage, (s.string as NSString).paragraphRange(for: r).length <= 3 { applyPara { _, _, end in f(&end) } }
            var t = textView.typingAttributes
            var props = (t[.pptRun] as? RunBox)?.props ?? RunProps()
            f(&props)
            t[.pptRun] = RunBox(props)
            // Display attributes for the next typed text.
            let para = (t[.pptPara] as? ParaBox)
            let style = (para?.props ?? LevelStyle()).over(TextRender.levelStyle(c, level: para?.level ?? 0))
            for (k, v) in TextRender.attributes(props.over(style.run), theme: c.deck.theme, scale: c.scale, para: t[.paragraphStyle] as? NSParagraphStyle ?? .default) where k != .paragraphStyle {
                t[k] = v
            }
            if props.underline != true { t.removeValue(forKey: .underlineStyle) }
            if props.strike != true { t.removeValue(forKey: .strikethroughStyle) }
            textView.typingAttributes = t
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.pptRun, in: r) { v, range, _ in
            let box = v as? RunBox
            var props = box?.props ?? RunProps()
            f(&props)
            storage.addAttribute(.pptRun, value: RunBox(props, field: box?.field, link: box?.link), range: range)
        }
        storage.endEditing()
        rebuild()
        canvas?.owner?.formatBar.sync()
    }

    /// Paragraph formatting on the paragraphs touched by the selection.
    func applyPara(_ f: (inout Int, inout LevelStyle, inout RunProps) -> Void) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        var ranges = [ns.paragraphRange(for: sel)]
        if ranges[0].length == 0 { ranges = [NSRange(location: ns.length, length: 0)] }
        storage.beginEditing()
        var loc = ranges[0].location
        let stop = NSMaxRange(ranges[0])
        repeat {
            let pr = ns.paragraphRange(for: NSRange(location: min(loc, ns.length), length: 0))
            let probe = pr.length > 0 ? pr.location : max(0, pr.location - 1)
            let box = probe < storage.length ? storage.attribute(.pptPara, at: probe, effectiveRange: nil) as? ParaBox : textView.typingAttributes[.pptPara] as? ParaBox
            var level = box?.level ?? 0, props = box?.props ?? LevelStyle(), end = box?.endProps ?? RunProps()
            f(&level, &props, &end)
            let nb = ParaBox(level: max(0, min(8, level)), props: props, endProps: end)
            if pr.length > 0 { storage.addAttribute(.pptPara, value: nb, range: pr) }
            if NSMaxRange(pr) >= ns.length || pr.length == 0 {
                var t = textView.typingAttributes
                t[.pptPara] = nb
                textView.typingAttributes = t
            }
            if pr.length == 0 { break }
            loc = NSMaxRange(pr)
        } while loc < stop
        storage.endEditing()
        rebuild()
        canvas?.owner?.formatBar.sync()
    }

    /// Redraws the attributed text from the boxes (fonts, markers, numbering).
    private func rebuild() {
        guard let storage = textView.textStorage, let c = context else { return }
        var b = body
        b.paragraphs = TextRender.paragraphs(from: storage)
        if b.paragraphs.isEmpty || storage.length == 0 {
            if let pb = textView.typingAttributes[.pptPara] as? ParaBox {
                var p = Paragraph()
                p.level = pb.level; p.props = pb.props; p.endProps = pb.endProps
                b.paragraphs = [p]
            }
        }
        replaceStorage(with: TextRender.attributed(b, c, forEditing: true))
        if storage.length > 0 {
            let at = min(max(0, textView.selectedRange().location - 1), storage.length - 1)
            if textView.selectedRange().length == 0 { textView.typingAttributes = storage.attributes(at: at, effectiveRange: nil) }
        } else {
            textView.typingAttributes = TextRender.typingAttributes(b, c)
        }
        layout()
    }

    /// Tab / ⇧Tab: next cell in a table, else outline level of the paragraphs.
    func handleTab(back: Bool) -> Bool {
        guard let canvas, let owner = canvas.owner, let o = object else { return false }
        if let cell, let t = o.table {
            var r = cell.0, c = cell.1
            repeat {
                c += back ? -1 : 1
                if c >= t.columns.count { c = 0; r += 1 }
                if c < 0 { c = t.columns.count - 1; r -= 1 }
            } while r >= 0 && r < t.rows.count && t.cells[r][c].merged
            guard r >= 0, r < t.rows.count else { return true }
            end()
            if let updated = owner.displayedSlide.object(o.id) { begin(updated, cell: (r, c), at: nil, selectAll: true) }
            return true
        }
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        let pr = ns.paragraphRange(for: NSRange(location: sel.location, length: 0))
        let atStart = contentOffset(sel.location) == contentOffset(pr.location)
        guard sel.length > 0 || atStart else { return false }
        applyPara { level, _, _ in level += back ? -1 : 1 }
        return true
    }

    /// Effective character formatting at the caret (for the format bar).
    var currentRunProps: RunProps {
        guard let c = context else { return RunProps() }
        let r = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if r.length > 0, let s = textView.textStorage, r.location < s.length {
            attrs = s.attributes(at: firstContentIndex(atOrAfter: r.location) < s.length ? firstContentIndex(atOrAfter: r.location) : r.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        let para = attrs[.pptPara] as? ParaBox
        let style = (para?.props ?? LevelStyle()).over(TextRender.levelStyle(c, level: para?.level ?? 0))
        return ((attrs[.pptRun] as? RunBox)?.props ?? RunProps()).over(style.run)
    }

    var currentLevelStyle: LevelStyle {
        guard let c = context else { return LevelStyle() }
        let para = textView.typingAttributes[.pptPara] as? ParaBox
        var p = para
        if let s = textView.textStorage, s.length > 0 {
            let at = min(textView.selectedRange().location, s.length - 1)
            p = s.attribute(.pptPara, at: at, effectiveRange: nil) as? ParaBox ?? para
        }
        return (p?.props ?? LevelStyle()).over(TextRender.levelStyle(c, level: p?.level ?? 0))
    }

    /// Replaces the selection with text (fields, dates).
    func insert(_ run: TextRun) {
        guard let c = context else { return }
        var attrs = textView.typingAttributes
        attrs[.pptRun] = RunBox(run.props, field: run.field)
        let text = TextRender.fieldText(run.field, fallback: run.text, number: c.number)
        textView.insertText(NSAttributedString(string: text, attributes: attrs), replacementRange: textView.selectedRange())
    }
}
