import AppKit
import Kit42

extension NSTextAttachment {
    /// The attachment's picture (with an ImageCell the cell holds it: a set `image` would replace the cell).
    var picture: NSImage? {
        image ?? (attachmentCell as? NSTextAttachmentCell)?.image ?? fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
    }
}

/// Draws a picture with its crop and border; a floating picture takes no room in the line (the page shows it).
final class ImageCell: NSTextAttachmentCell {
    static func props(_ lm: NSLayoutManager?, _ i: Int) -> DocImage? {
        guard let s = lm?.textStorage, i < s.length else { return nil }
        return s.attribute(.docImage, at: i, effectiveRange: nil) as? DocImage
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
                            characterIndex charIndex: Int) -> NSRect {
        if Self.props(textContainer.layoutManager, charIndex)?.isFloating == true { return NSRect(x: 0, y: 0, width: 0.01, height: 0.01) }
        let size = (attachment?.bounds.size.width ?? 0) > 0 ? attachment!.bounds.size : (image?.size ?? .zero)
        return NSRect(origin: .zero, size: size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let p = Self.props(layoutManager, charIndex)
        guard p?.isFloating != true else { return }
        Self.drawPicture(image ?? attachment?.picture, in: cellFrame, props: p, flipped: controlView?.isFlipped ?? true)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        Self.drawPicture(image ?? attachment?.picture, in: cellFrame, props: nil, flipped: controlView?.isFlipped ?? true)
    }

    override func wantsToTrackMouse() -> Bool { false }

    /// Lower-quality copies used while exporting a PDF with reduced image quality (0…1, 1: originals).
    static var exportQuality: CGFloat = 1

    static func drawPicture(_ image: NSImage?, in rect: NSRect, props: DocImage?, flipped: Bool) {
        guard var image else { return }
        if exportQuality < 1, let small = reduced(image, rect.size) { image = small }
        var from = NSRect(origin: .zero, size: image.size)
        if let c = props?.crop, props?.isCropped == true {
            from = NSRect(x: image.size.width * c.left, y: image.size.height * c.bottom,
                          width: image.size.width * max(0.01, 1 - c.left - c.right), height: image.size.height * max(0.01, 1 - c.top - c.bottom))
        }
        image.draw(in: rect, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        if let p = props, p.borderWidth > 0 {
            p.borderColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: p.borderWidth / 2, dy: p.borderWidth / 2))
            path.lineWidth = p.borderWidth
            path.stroke()
        }
    }

    private static var reducedCache: [ObjectIdentifier: NSImage] = [:]
    static func clearReduced() { reducedCache = [:] }

    /// A JPEG copy at about 150 dpi × quality.
    static func reduced(_ image: NSImage, _ size: NSSize) -> NSImage? {
        if let c = reducedCache[ObjectIdentifier(image)] { return c }
        let scale = max(0.3, exportQuality) * 150 / 72
        let w = max(8, Int(size.width * scale)), h = max(8, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: max(0.2, exportQuality)]), let out = NSImage(data: jpeg) else { return nil }
        reducedCache[ObjectIdentifier(image)] = out
        return out
    }
}

/// A floating picture on its page.
final class FloatImageView: NSView {
    var image: NSImage?
    var props = DocImage()
    var index = 0
    var onMouseDown: ((FloatImageView, NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { ImageCell.drawPicture(image, in: bounds, props: props, flipped: true) }
    override func mouseDown(with event: NSEvent) { onMouseDown?(self, event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

extension PagedView {
    /// Floating pictures anchored on a page: placed (views on the card) and returned with their rectangles (card coordinates).
    func placeFloats(_ card: PageCard, start: Int, end: Int) -> [(rect: NSRect, wrap: DocImage.Wrap, index: Int)] {
        guard let storage = layoutManager.textStorage, end > start else { card.setFloats([]); return [] }
        var out: [(NSRect, DocImage.Wrap, Int, NSImage?, DocImage)] = []
        storage.enumerateAttribute(.docImage, in: NSRange(location: start, length: end - start)) { v, r, _ in
            guard let p = v as? DocImage, p.isFloating, let a = storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment else { return }
            if p.fromParagraph {
                // Offset from the paragraph (as Word files have it): converted to the page once, where the paragraph is now.
                let para = (storage.string as NSString).paragraphRange(for: NSRange(location: r.location, length: 0))
                let g = layoutManager.glyphIndexForCharacter(at: para.location)
                if let c = layoutManager.textContainer(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true) {
                    let y = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true).minY
                    let tv = card.textViews.first { $0.textContainer === c }
                    p.offset.y += y + (tv.map { $0.frame.minY - card.setup.margins.top } ?? 0)
                }
                p.fromParagraph = false
            }
            let size = a.bounds.size.width > 0 ? a.bounds.size : (a.picture?.size ?? NSSize(width: 100, height: 100))
            let rect = NSRect(x: card.setup.margins.left + p.offset.x, y: card.setup.margins.top + p.offset.y, width: size.width, height: size.height)
            out.append((rect, p.wrap, r.location, a.picture, p))
        }
        card.setFloats(out.map { ($0.0, $0.3, $0.4, $0.2) })
        return out.map { ($0.0, $0.1, $0.2) }
    }
}

extension PageCard {
    /// Keeps one view per floating picture: behind the text views or in front of them.
    func setFloats(_ list: [(rect: NSRect, image: NSImage?, props: DocImage, index: Int)]) {
        let old = subviews.compactMap { $0 as? FloatImageView }
        for (k, f) in list.enumerated() {
            let v = k < old.count ? old[k] : {
                let v = FloatImageView()
                v.onMouseDown = { [weak self] view, event in self?.paged?.onFloatMouseDown?(view, event) }
                return v
            }()
            v.image = f.image
            v.props = f.props
            v.index = f.index
            if v.frame != f.rect { v.frame = f.rect }
            let behind = f.props.wrap == .behind
            if v.superview !== self || (behind && subviews.firstIndex(of: v) != 0) {
                v.removeFromSuperview()
                if behind { addSubview(v, positioned: .below, relativeTo: subviews.first) } else { addSubview(v) }
            }
            v.needsDisplay = true
        }
        for v in old.dropFirst(list.count) { v.removeFromSuperview() }
    }
}

// MARK: - Selection handles

/// Eight handles around the selected picture; dragging one resizes it (corners keep the proportions).
final class ImageHandles: NSView {
    var onResize: ((NSSize, Bool) -> Void)?
    var keepRatio = true
    private var start: NSPoint = .zero
    private var startSize: NSSize = .zero
    private var handle = -1
    static let size: CGFloat = 7
    override var isFlipped: Bool { true }

    var picture: NSRect { bounds.insetBy(dx: Self.size, dy: Self.size) }

    private func handles() -> [NSRect] {
        let r = picture, s = Self.size
        let xs = [r.minX, r.midX, r.maxX], ys = [r.minY, r.midY, r.maxY]
        var out: [NSRect] = []
        for (j, y) in ys.enumerated() { for (i, x) in xs.enumerated() where !(i == 1 && j == 1) { out.append(NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)) } }
        return out   // 0 TL, 1 T, 2 TR, 3 L, 4 R, 5 BL, 6 B, 7 BR
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: picture.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        for h in handles() {
            NSColor.white.setFill()
            h.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: h).stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return handles().contains { $0.insetBy(dx: -3, dy: -3).contains(p) } ? self : nil
    }

    override func resetCursorRects() {
        for (i, h) in handles().enumerated() { addCursorRect(h.insetBy(dx: -3, dy: -3), cursor: [1, 6].contains(i) ? .resizeUpDown : [3, 4].contains(i) ? .resizeLeftRight : .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        handle = handles().firstIndex { $0.insetBy(dx: -3, dy: -3).contains(p) } ?? -1
        start = p
        startSize = picture.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard handle >= 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        var dx = p.x - start.x, dy = p.y - start.y
        if [0, 3, 5].contains(handle) { dx = -dx }
        if [0, 1, 2].contains(handle) { dy = -dy }
        if [1, 6].contains(handle) { dx = 0 }
        if [3, 4].contains(handle) { dy = 0 }
        var size = NSSize(width: max(12, startSize.width + dx), height: max(12, startSize.height + dy))
        let corner = [0, 2, 5, 7].contains(handle)
        if corner && (keepRatio != event.modifierFlags.contains(.shift)), startSize.width > 0 {
            let k = max(size.width / startSize.width, size.height / startSize.height)
            size = NSSize(width: startSize.width * k, height: startSize.height * k)
        }
        onResize?(size, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard handle >= 0 else { return }
        mouseDragged(with: event)
        onResize?(picture.size, true)
        handle = -1
    }
}

extension DocWindowController {
    /// The selected picture (character index), from a click or the selection.
    var selectedImageIndex: Int? {
        guard let storage = textView.textStorage else { return nil }
        if let i = extras2.imageIndex, i < storage.length, storage.attribute(.attachment, at: i, effectiveRange: nil) is NSTextAttachment { return i }
        let sel = textView.selectedRange()
        for i in [sel.location, sel.location - 1] where i >= 0 && i < storage.length {
            if let a = storage.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment, a.picture != nil,
               storage.attribute(.docNote, at: i, effectiveRange: nil) == nil, storage.attribute(.docField, at: i, effectiveRange: nil) == nil { return i }
        }
        return nil
    }

    /// Picture rectangle in the pages view (inline from the layout, floating from its view).
    func imageRect(_ index: Int) -> NSRect? {
        guard let storage = textView.textStorage, index < storage.length else { return nil }
        if (storage.attribute(.docImage, at: index, effectiveRange: nil) as? DocImage)?.isFloating == true {
            for c in paged.cards { if let v = c.subviews.compactMap({ $0 as? FloatImageView }).first(where: { $0.index == index }) { return paged.convert(v.frame, from: c) } }
            return nil
        }
        guard let tv = paged.textView(at: index), let container = tv.textContainer else { return nil }
        let g = paged.layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var r = paged.layoutManager.boundingRect(forGlyphRange: g, in: container)
        if let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment, a.bounds.size.width > 0 {
            r = NSRect(x: r.minX, y: r.maxY - a.bounds.height, width: a.bounds.width, height: a.bounds.height)
        }
        return paged.convert(r.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y), from: tv)
    }

    /// Shows handles on a picture (nil hides them).
    func selectImage(_ index: Int?) {
        extras2.imageIndex = index
        extras2.handles?.removeFromSuperview()
        extras2.handles = nil
        guard let index, let rect = imageRect(index) else { return }
        let h = ImageHandles(frame: rect.insetBy(dx: -ImageHandles.size, dy: -ImageHandles.size))
        h.onResize = { [weak self, weak h] size, done in
            guard let self, let h else { return }
            h.frame = NSRect(origin: h.frame.origin, size: NSSize(width: size.width + ImageHandles.size * 2, height: size.height + ImageHandles.size * 2))
            h.needsDisplay = true
            if done { self.resizeImage(index, to: size) }
        }
        paged.addSubview(h)
        extras2.handles = h
        window?.invalidateCursorRects(for: h)
    }

    /// Handles follow the picture after layout changes.
    func updateImageHandles() {
        guard let index = extras2.imageIndex, let h = extras2.handles else { return }
        guard let rect = imageRect(index) else { selectImage(nil); return }
        let f = rect.insetBy(dx: -ImageHandles.size, dy: -ImageHandles.size)
        if h.frame != f { h.frame = f; h.needsDisplay = true }
    }

    /// Changes a picture's attachment or properties (undoable).
    func changeImage(_ index: Int, name: String, _ body: (NSTextAttachment, DocImage) -> Void) {
        guard let storage = textView.textStorage, index < storage.length,
              let old = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment else { return }
        let props = (storage.attribute(.docImage, at: index, effectiveRange: nil) as? DocImage)?.duplicate() ?? DocImage()
        let a = NSTextAttachment()
        let picture = old.picture
        a.fileWrapper = old.fileWrapper
        if a.fileWrapper == nil, let tiff = picture?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            a.fileWrapper = FileWrapper(regularFileWithContents: png)
            a.fileWrapper?.preferredFilename = "image.png"
        }
        a.bounds = old.bounds.width > 0 ? old.bounds : NSRect(origin: .zero, size: picture?.size ?? .zero)
        a.attachmentCell = ImageCell(imageCell: picture)
        body(a, props)
        let r = NSRange(location: index, length: 1)
        guard textView.shouldChangeText(in: r, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.attachment, value: a, range: r)
        storage.addAttribute(.docImage, value: props, range: r)
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName(name)
        paged.layoutManager.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        paged.layoutAll()
        selectImage(index)
    }

    func resizeImage(_ index: Int, to size: NSSize) {
        changeImage(index, name: L("Resize Image")) { a, _ in a.bounds = NSRect(origin: .zero, size: NSSize(width: round(size.width), height: round(size.height))) }
    }

    /// Dragging a floating picture moves it on the page.
    func floatMouseDown(_ view: FloatImageView, _ event: NSEvent) {
        let index = view.index
        selectImage(index)
        guard let card = view.superview as? PageCard, let window else { return }
        let start = event.locationInWindow
        let origin = view.frame.origin
        var moved = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let d = NSPoint(x: e.locationInWindow.x - start.x, y: -(e.locationInWindow.y - start.y))
            let scale = scroller.magnification
            view.setFrameOrigin(NSPoint(x: origin.x + d.x / scale, y: origin.y + d.y / scale))
            moved = moved || abs(d.x) + abs(d.y) > 2
            updateImageHandles()
            if e.type == .leftMouseUp { break }
        }
        if event.clickCount == 2 { imagePropertiesAction(nil); return }
        guard moved else { return }
        let offset = CGPoint(x: view.frame.minX - card.setup.margins.left, y: view.frame.minY - card.setup.margins.top)
        changeImage(index, name: L("Move Image")) { _, p in p.offset = offset }
    }

    // MARK: Properties

    @objc func imagePropertiesAction(_ sender: Any?) {
        guard let index = selectedImageIndex, let storage = textView.textStorage,
              let a = storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment else { NSSound.beep(); return }
        let p = (storage.attribute(.docImage, at: index, effectiveRange: nil) as? DocImage) ?? DocImage()
        let k = DocRuler.cm
        let size = a.bounds.size.width > 0 ? a.bounds.size : (a.picture?.size ?? .zero)
        let width = NSTextField(string: Self.num(size.width / k)), height = NSTextField(string: Self.num(size.height / k))
        let ratio = NSButton(checkboxWithTitle: L("Keep proportions"), target: nil, action: nil)
        ratio.state = .on
        let wrap = NSPopUpButton(frame: .zero, pullsDown: false)
        wrap.addItems(withTitles: Self.wrapTitles)
        wrap.selectItem(at: DocImage.Wrap.allCases.firstIndex(of: p.wrap) ?? 0)
        let x = NSTextField(string: Self.num(p.offset.x / k)), y = NSTextField(string: Self.num(p.offset.y / k))
        let border = NSTextField(string: Self.num(p.borderWidth))
        let color = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        color.color = p.borderColor
        let crop = [p.crop.left, p.crop.top, p.crop.right, p.crop.bottom].map { NSTextField(string: Self.num($0 * 100)) }
        let cropRow = NSStackView(views: crop)
        for f in crop { f.widthAnchor.constraint(equalToConstant: 52).isActive = true }
        let alert = NSAlert.form(L("Image Properties"), info: L("Sizes in centimetres; crop in percent of each side (left, top, right, bottom). Position of a floating picture from the top-left of the text area."),
                                 ok: L("Apply"), rows: [(L("Width:"), width), (L("Height:"), height), ("", ratio), (L("Wrap:"), wrap),
                                                        (L("Horizontal position:"), x), (L("Vertical position:"), y), (L("Border (pt):"), border),
                                                        (L("Border colour:"), color), (L("Crop (%):"), cropRow)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func n(_ f: NSTextField) -> CGFloat? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).map { CGFloat($0) } }
        var w = (n(width) ?? size.width / k) * k, h = (n(height) ?? size.height / k) * k
        if ratio.state == .on, size.width > 0, size.height > 0 {
            if abs(w - size.width) > 0.5 { h = w * size.height / size.width } else if abs(h - size.height) > 0.5 { w = h * size.width / size.height }
        }
        let c = crop.map { max(0, min(45, n($0) ?? 0)) / 100 }
        changeImage(index, name: L("Image Properties")) { att, props in
            att.bounds = NSRect(x: 0, y: 0, width: max(4, round(w)), height: max(4, round(h)))
            props.wrap = DocImage.Wrap.allCases[max(0, wrap.indexOfSelectedItem)]
            props.offset = CGPoint(x: (n(x) ?? 0) * k, y: (n(y) ?? 0) * k)
            props.borderWidth = max(0, n(border) ?? 0)
            props.borderColor = color.color
            props.crop = NSEdgeInsets(top: c[1], left: c[0], bottom: c[3], right: c[2])
        }
    }

    static let wrapTitles = [L("In Line with Text"), L("Square (Text Around)"), L("Top and Bottom"), L("Behind Text"), L("In Front of Text")]

    @objc func imageWrapAction(_ sender: Any?) {
        guard let index = selectedImageIndex else { NSSound.beep(); return }
        setImageWrap(index, DocImage.Wrap.allCases[max(0, min(4, commandTag(of: sender)))])
    }

    func setImageWrap(_ index: Int, _ wrap: DocImage.Wrap) {
        // A picture that starts floating keeps its place on the page.
        let rect = imageRect(index)
        let card = paged.card(at: index)
        changeImage(index, name: L("Wrap")) { _, p in
            if !p.isFloating, wrap != .inline, let rect, let card {
                let r = card.convert(rect, from: paged)
                p.offset = CGPoint(x: max(0, r.minX - card.setup.margins.left), y: max(0, r.minY - card.setup.margins.top))
            }
            p.wrap = wrap
        }
    }

    // MARK: Captions

    @objc func insertCaptionAction(_ sender: Any?) {
        let label = NSComboBox()
        label.addItems(withObjectValues: [L("Figure"), L("Table"), L("Illustration"), L("Drawing")])
        label.stringValue = isInTable ? L("Table") : L("Figure")
        let text = NSTextField(string: "")
        text.placeholderString = L("Caption text")
        let alert = NSAlert.form(L("Insert Caption"), info: L("Numbered automatically (Figure 1, Figure 2, …)."), ok: L("Insert"),
                                 rows: [(L("Category:"), label), (L("Caption:"), text)])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        insertCaption(label: label.stringValue, text: text.stringValue)
    }

    /// "Figure 1: text" in the Caption style after the picture's paragraph (above a table).
    func insertCaption(label: String, text: String) {
        guard let storage = textView.textStorage, let sheet = doc?.styles else { return }
        let ns = storage.string as NSString
        var at: Int
        if let g = tableGrid {
            at = g.range.location
        } else {
            let anchor = selectedImageIndex ?? textView.selectedRange().location
            at = NSMaxRange(ns.paragraphRange(for: NSRange(location: min(anchor, ns.length), length: 0)))
        }
        var attrs = sheet.attributes("Caption")
        attrs[Styles.styleKey] = "Caption"
        let out = NSMutableAttributedString()
        if at > 0, at == ns.length, ns.character(at: at - 1) != 10 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
        out.append(NSAttributedString(string: label + " ", attributes: attrs))
        let seq = label.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        out.append(Fields.reference(DocField(.sequence, argument: seq.isEmpty ? "Figure" : seq), attributes: attrs))
        out.append(NSAttributedString(string: (text.isEmpty ? "" : ": " + text) + "\n", attributes: attrs))
        let r = NSRange(location: at, length: 0)
        guard textView.shouldChangeText(in: r, replacementString: out.string) else { return }
        storage.replaceCharacters(in: r, with: out)
        textView.didChangeText()
        textView.undoManager?.setActionName(L("Insert Caption"))
        textView.setSelectedRange(NSRange(location: at + out.length - 1, length: 0))
        paged.refreshFields(force: true)
    }
}

/// More per-window state (picture selection).
final class EditorExtras2 {
    var imageIndex: Int?
    var handles: ImageHandles?
}

// MARK: - .docx pictures

extension DocxStyles {
    /// Wrap, position, border and crop of a w:drawing (wp:anchor or wp:inline).
    static func imageProps(_ drawing: XMLElement) -> DocImage? {
        let p = DocImage()
        var any = false
        if let anchor = descendants(drawing, named: "anchor").first {
            any = true
            if anchor.child("wrapSquare") != nil || anchor.child("wrapTight") != nil || anchor.child("wrapThrough") != nil { p.wrap = .square }
            else if anchor.child("wrapTopAndBottom") != nil { p.wrap = .topBottom }
            else { p.wrap = ["1", "true"].contains(anchor.attr("behindDoc") ?? "0") ? .behind : .inFront }
            func offset(_ e: XMLElement?) -> (CGFloat, String) {
                let v = e?.child("posOffset")?.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                return (CGFloat(v) / 12700, e?.attr("relativeFrom") ?? "margin")
            }
            let (x, rx) = offset(anchor.child("positionH"))
            let (y, ry) = offset(anchor.child("positionV"))
            p.offset = CGPoint(x: x, y: y)
            // Page-relative offsets are taken from the text area later (margins unknown here): approximated.
            if rx == "page" { p.offset.x -= 72 }
            if ry == "page" { p.offset.y -= 72 }
            if ["paragraph", "line"].contains(ry) { p.fromParagraph = true }
        }
        if let src = descendants(drawing, named: "srcRect").first {
            func f(_ k: String) -> CGFloat { CGFloat(src.attr(k).flatMap(Double.init) ?? 0) / 100_000 }
            p.crop = NSEdgeInsets(top: f("t"), left: f("l"), bottom: f("b"), right: f("r"))
            any = any || p.isCropped
        }
        if let ln = descendants(drawing, named: "ln").first, let w = ln.attr("w").flatMap(Double.init), w > 0, descendants(ln, named: "noFill").isEmpty {
            p.borderWidth = CGFloat(w) / 12700
            if let c = descendants(ln, named: "srgbClr").first?.attr("val"), let color = hexColor(c) { p.borderColor = color }
            any = true
        }
        return any ? p : nil
    }
}
