import AppKit
import Kit42
import UniformTypeIdentifiers

extension NSScrollView {
    /// Content size minus the content insets (the toolbar and titlebar accessories of a full-size content view).
    var visibleContentSize: CGSize {
        let s = contentSize, i = contentInsets
        return CGSize(width: max(1, s.width - i.left - i.right), height: max(1, s.height - i.top - i.bottom))
    }
}

/// What a click-drag on the canvas creates.
enum InsertTool: Equatable {
    case textBox
    case shape(String)
    case line(arrow: Bool)
}

/// The slide being edited: drawing, selection handles, move/resize/rotate with snapping, insertion, in-place text.
final class SlideCanvas: NSView {
    weak var owner: DeckWindowController?
    let editor = TextEditController()
    /// nil = zoom to fit.
    var zoom: CGFloat? { didSet { updateFrame() } }
    var insertTool: InsertTool? { didSet { window?.invalidateCursorRects(for: self); needsDisplay = true } }

    /// Slide shown while dragging (committed on mouse up).
    private var live: Slide?
    private var guides: [(CGPoint, CGPoint)] = []
    private var rubber: CGRect?
    private var creating: (start: CGPoint, end: CGPoint)?
    private let margin: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        editor.canvas = self
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var deck: Deck { owner?.deck ?? Deck.makeDefault() }
    var slide: Slide { live ?? owner?.displayedSlide ?? Slide(layout: 0) }
    var isMaster: Bool { owner?.mode == .master }

    // MARK: - Geometry

    /// The part of the scroll view not covered by the toolbar and format bar (full-size content view insets).
    private var visibleSize: CGSize { enclosingScrollView?.visibleContentSize ?? bounds.size }

    var fitScale: CGFloat {
        let v = visibleSize, s = deck.size
        return max(0.05, min((v.width - margin * 2) / s.width, (v.height - margin * 2) / s.height))
    }

    var scale: CGFloat { zoom ?? fitScale }

    var origin: CGPoint {
        let s = deck.size
        return CGPoint(x: max(margin, (bounds.width - s.width * scale) / 2).rounded(), y: max(margin, (bounds.height - s.height * scale) / 2).rounded())
    }

    var slideRect: CGRect { CGRect(origin: origin, size: CGSize(width: deck.size.width * scale, height: deck.size.height * scale)) }

    func toSlide(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
    func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    func toView(_ r: CGRect) -> CGRect { CGRect(origin: toView(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale)) }

    func updateFrame() {
        let v = visibleSize, s = deck.size
        let w = max(v.width, s.width * scale + margin * 2), h = max(v.height, s.height * scale + margin * 2)
        if frame.size != CGSize(width: w, height: h) { setFrameSize(CGSize(width: w, height: h)) }
        editor.layout()
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.updateFrame() }
        if let scroll = enclosingScrollView {
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in self?.updateFrame() }
        }
    }

    func slideChanged() {
        editor.end()
        live = nil
        updateFrame()
    }

    func deckChanged() {
        if !editor.isActive { live = nil }
        needsDisplay = true
        editor.layout()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let owner else { return }
        // Insets or the notes pane changed without a frame notification: fit again.
        let v = visibleSize, s = deck.size
        let want = CGSize(width: max(v.width, s.width * scale + margin * 2), height: max(v.height, s.height * scale + margin * 2))
        if abs(want.width - frame.width) > 0.5 || abs(want.height - frame.height) > 0.5 { DispatchQueue.main.async { [weak self] in self?.updateFrame() } }
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard !deck.slides.isEmpty || isMaster else {
            let s = NSAttributedString(string: L("No slides. Add one with Insert › New Slide."), attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.secondaryLabelColor])
            s.draw(at: CGPoint(x: bounds.midX - s.size().width / 2, y: bounds.midY - 10))
            return
        }
        let r = slideRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(r)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        var options = RenderOptions()
        options.editing = true
        options.number = Renderer.number(of: owner.current, deck: deck)
        if let id = editor.objectID { options.textHidden = [id] }
        if isMaster {
            Renderer.drawMaster(deck: deck, objects: slide.objects, in: ctx, textHidden: options.textHidden, layout: owner.editedLayout.map { deck.layouts[$0] })
        } else {
            Renderer.draw(slide, deck: deck, in: ctx, options: options)
        }
        ctx.restoreGState()
        drawSelection(ctx)
        if owner.mode == .normal { CommentMarkers.draw(slide, in: ctx, toView: { self.toView($0) }, scale: scale) }
        if owner.mode == .normal, owner.animationTabShown {
            AnimationMarkers.draw(slide, deck: deck, selected: owner.inspector.animationPane.selected, in: ctx, toView: { self.toView($0) })
        }
        // Guides, rubber band, creation preview
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemPink.cgColor)
        ctx.setLineWidth(1)
        for (a, b) in guides {
            ctx.move(to: toView(a)); ctx.addLine(to: toView(b))
        }
        ctx.strokePath()
        ctx.restoreGState()
        if let rubber {
            let vr = toView(rubber)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            vr.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: vr.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        if let c = creating, let tool = insertTool {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            if case .line = tool {
                ctx.move(to: toView(c.start)); ctx.addLine(to: toView(c.end)); ctx.strokePath()
            } else {
                let rr = toView(normalized(c.start, c.end, square: NSEvent.modifierFlags.contains(.shift)))
                if case .shape(let prst) = tool {
                    ctx.translateBy(x: rr.minX, y: rr.minY)
                    ctx.addPath(Shapes.path(prst, size: rr.size))
                    ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
                    ctx.drawPath(using: .fillStroke)
                } else {
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    ctx.stroke(rr)
                }
            }
            ctx.restoreGState()
        }
    }

    /// Corners of an object's (rotated) frame in slide coordinates.
    func corners(_ o: SlideObject) -> [CGPoint] {
        let f = o.frame, c = CGPoint(x: f.midX, y: f.midY), a = o.rotation * .pi / 180
        return [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY)].map { rotate($0, around: c, by: a) }
    }

    func rotate(_ p: CGPoint, around c: CGPoint, by a: CGFloat) -> CGPoint {
        guard a != 0 else { return p }
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    /// Handle positions (slide coordinates): 8 resize handles clockwise from top-left, then rotation.
    func handles(_ o: SlideObject) -> [CGPoint] {
        if o.isLine { return [o.lineStart, o.lineEnd] }
        let f = o.frame, c = CGPoint(x: f.midX, y: f.midY), a = o.rotation * .pi / 180
        let local = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.maxX, y: f.midY),
                     CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.minX, y: f.midY),
                     CGPoint(x: f.midX, y: f.minY - 22 / scale)]
        return local.map { rotate($0, around: c, by: a) }
    }

    /// Adjust handles (yellow diamonds) of a preset shape, in slide coordinates.
    func adjustHandles(_ o: SlideObject) -> [CGPoint] {
        guard !o.isLine, o.custom == nil, o.kind == .shape || o.kind == .textBox || o.kind == .picture,
              let def = PresetDef.all[o.geometry], !def.handles.isEmpty else { return [] }
        return def.handlePoints(size: o.frame.size, adjust: o.adjust).map { toSlideSpace($0, of: o) }
    }

    func toSlideSpace(_ q: CGPoint, of o: SlideObject) -> CGPoint {
        let f = o.frame
        let x = o.flipH ? f.width - q.x : q.x, y = o.flipV ? f.height - q.y : q.y
        return rotate(CGPoint(x: f.minX + x, y: f.minY + y), around: CGPoint(x: f.midX, y: f.midY), by: o.rotation * .pi / 180)
    }

    func toShapeSpace(_ p: CGPoint, of o: SlideObject) -> CGPoint {
        let f = o.frame
        let q = rotate(p, around: CGPoint(x: f.midX, y: f.midY), by: -o.rotation * .pi / 180)
        let x = q.x - f.minX, y = q.y - f.minY
        return CGPoint(x: o.flipH ? f.width - x : x, y: o.flipV ? f.height - y : y)
    }

    private func drawSelection(_ ctx: CGContext) {
        guard let owner else { return }
        let accent = NSColor.controlAccentColor
        let objects = owner.selection.compactMap { slide.object($0) }
        for o in objects {
            let pts = corners(o).map(toView)
            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            if !o.isLine {
                ctx.addLines(between: pts)
                ctx.closePath()
                ctx.strokePath()
            }
            let single = objects.count == 1 && !editor.isActive
            if single || o.isLine {
                let hs = handles(o)
                if !o.isLine {
                    ctx.move(to: toView(hs[1])); ctx.addLine(to: toView(hs[8])); ctx.strokePath()
                }
                for (i, h) in hs.enumerated() {
                    let v = toView(h)
                    let r = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
                    ctx.setFillColor(NSColor.white.cgColor)
                    if i == 8 || o.isLine { ctx.fillEllipse(in: r); ctx.strokeEllipse(in: r) } else { ctx.fill(r); ctx.stroke(r) }
                }
                if single {
                    for h in adjustHandles(o) {
                        let v = toView(h)
                        ctx.move(to: CGPoint(x: v.x, y: v.y - 5)); ctx.addLine(to: CGPoint(x: v.x + 5, y: v.y))
                        ctx.addLine(to: CGPoint(x: v.x, y: v.y + 5)); ctx.addLine(to: CGPoint(x: v.x - 5, y: v.y)); ctx.closePath()
                        ctx.setFillColor(NSColor.systemYellow.cgColor)
                        ctx.setStrokeColor(NSColor(white: 0.25, alpha: 1).cgColor)
                        ctx.drawPath(using: .fillStroke)
                    }
                    ctx.setStrokeColor(accent.cgColor)
                }
            }
            ctx.restoreGState()
        }
        if objects.count > 1 {
            let union = objects.map { bounds(of: $0) }.reduce(objects.map { bounds(of: $0) }[0]) { $0.union($1) }
            ctx.saveGState()
            ctx.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(toView(union).insetBy(dx: -3, dy: -3))
            ctx.restoreGState()
        }
    }

    /// Axis-aligned bounds of an object as drawn (rotation included).
    func bounds(of o: SlideObject) -> CGRect {
        if o.isLine { return o.frame }
        let pts = corners(o)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: - Hit testing

    func hit(_ p: CGPoint, in list: [SlideObject]? = nil) -> SlideObject? {
        let tol = 4 / scale
        for o in (list ?? slide.objects).reversed() {
            if o.isLine {
                if distance(p, o.lineStart, o.lineEnd) <= max(tol, o.line.width / 2 + 2 / scale) { return o }
                continue
            }
            let c = CGPoint(x: o.frame.midX, y: o.frame.midY)
            let q = rotate(p, around: c, by: -o.rotation * .pi / 180)
            if o.frame.insetBy(dx: -tol, dy: -tol).contains(q) {
                // Empty placeholders and unfilled shapes are still easy to grab.
                return o
            }
        }
        return nil
    }

    func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    enum Grab { case handle(Int), move }

    func grabHandle(_ p: CGPoint) -> (SlideObject, Int)? {
        guard let owner, owner.selection.count == 1, let o = slide.object(owner.selection[0]) else { return nil }
        for (i, h) in handles(o).enumerated() where hypot(h.x - p.x, h.y - p.y) <= 6 / scale {
            return (o, i)
        }
        return nil
    }

    // MARK: - Mouse

    private enum Drag {
        case move(start: CGPoint, original: Slide, ids: [Int])
        case resize(id: Int, handle: Int, original: SlideObject)
        case rotate(id: Int, original: SlideObject)
        case lineEnd(id: Int, end: Int, original: SlideObject)
        case adjust(id: Int, handle: Int, original: SlideObject)
        case rubber(start: CGPoint, base: [Int])
        case create(start: CGPoint)
    }
    private var drag: Drag?
    private var moved = false

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        let p = toSlide(v)
        if editor.isActive {
            if editor.container.frame.contains(v) { return }
            editor.end()
        }
        moved = false
        if owner.mode == .normal, CommentMarkers.rects(slide, scale: scale).contains(where: { $0.1.contains(p) }) {
            owner.showInspector(true, tab: 4)
            return
        }
        if insertTool != nil {
            drag = .create(start: p)
            creating = (p, p)
            return
        }
        if event.clickCount == 2, let o = hit(p) {
            doubleClick(o, at: p)
            return
        }
        if owner.selection.count == 1, let o = slide.object(owner.selection[0]),
           let k = adjustHandles(o).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 6 / scale }) {
            drag = .adjust(id: o.id, handle: k, original: o)
            live = slide
            return
        }
        if let (o, h) = grabHandle(p) {
            if o.isLine { drag = .lineEnd(id: o.id, end: h, original: o) }
            else if h == 8 { drag = .rotate(id: o.id, original: o) }
            else { drag = .resize(id: o.id, handle: h, original: o) }
            live = slide
            return
        }
        let shift = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        if let o = hit(p) {
            if shift {
                if owner.selection.contains(o.id) { owner.selection.removeAll { $0 == o.id } } else { owner.selection.append(o.id) }
            } else if !owner.selection.contains(o.id) {
                owner.selection = [o.id]
            }
            if owner.selection.contains(o.id) {
                drag = .move(start: p, original: slide, ids: owner.selection)
                live = slide
            }
        } else {
            if !shift { owner.selection = [] }
            drag = .rubber(start: p, base: owner.selection)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner, let drag else { return }
        let p = toSlide(convert(event.locationInWindow, from: nil))
        moved = true
        let shift = event.modifierFlags.contains(.shift)
        let noSnap = event.modifierFlags.contains(.command) || !owner.snapToGuides
        guides = []
        switch drag {
        case .create(let start):
            var end = p
            if case .line = insertTool, shift { end = snapAngle(start, p) }
            creating = (start, end)
        case .rubber(let start, let base):
            let r = normalized(start, p, square: false)
            rubber = r
            let inside = slide.objects.filter { r.intersects(bounds(of: $0)) }.map(\.id)
            owner.selection = base + inside.filter { !base.contains($0) }
        case .move(let start, let original, let ids):
            var d = CGSize(width: p.x - start.x, height: p.y - start.y)
            if shift { if abs(d.width) > abs(d.height) { d.height = 0 } else { d.width = 0 } }
            let moving = original.objects.filter { ids.contains($0.id) }
            if !noSnap, let first = moving.first {
                let union = moving.map { bounds(of: $0) }.reduce(bounds(of: first)) { $0.union($1) }.offsetBy(dx: d.width, dy: d.height)
                let (sx, sy, g) = snap(union, excluding: Set(ids), in: original)
                d.width += sx; d.height += sy
                guides = g
            }
            var s = original
            for id in ids { s.update(id) { $0.offset(by: d) } }
            live = s
        case .resize(let id, let handle, let o):
            var s = slide
            let f = resized(o, handle: handle, to: p, keepAspect: shift || (o.kind == .picture && !event.modifierFlags.contains(.option)), snap: !noSnap)
            s.update(id) { $0.setFrame(f) }
            live = s
        case .rotate(let id, let o):
            let c = CGPoint(x: o.frame.midX, y: o.frame.midY)
            var a = atan2(p.y - c.y, p.x - c.x) * 180 / .pi + 90
            if shift { a = (a / 15).rounded() * 15 }
            a = a.truncatingRemainder(dividingBy: 360)
            if a < 0 { a += 360 }
            if abs(a - 360) < 2 || abs(a) < 2 { a = 0 }
            var s = slide
            s.update(id) { $0.rotation = a }
            live = s
        case .adjust(let id, let k, let o):
            guard let def = PresetDef.all[o.geometry] else { break }
            let local = toShapeSpace(p, of: o)
            let adj = def.drag(handle: k, to: local, size: o.frame.size, adjust: o.adjust)
            var s = slide
            s.update(id) { $0.adjust = adj }
            live = s
        case .lineEnd(let id, let end, let o):
            var q = p
            let other = end == 0 ? o.lineEnd : o.lineStart
            if shift { q = snapAngle(other, p) }
            var s = slide
            s.update(id) { end == 0 ? $0.setLine(from: q, to: other) : $0.setLine(from: other, to: q) }
            live = s
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let owner else { return }
        defer { drag = nil; guides = []; rubber = nil; creating = nil; needsDisplay = true }
        guard let drag else { return }
        switch drag {
        case .create(let start):
            let end = creating?.end ?? start
            create(from: start, to: end, square: event.modifierFlags.contains(.shift))
        case .rubber:
            break
        case .move, .resize, .rotate, .lineEnd, .adjust:
            if moved, let s = live {
                let name: String
                switch drag {
                case .move: name = L("Move")
                case .rotate: name = L("Rotate")
                case .adjust: name = L("Adjust Shape")
                default: name = L("Resize")
                }
                owner.commit(slide: s, name: name)
            }
            live = nil
        }
    }

    private func doubleClick(_ o: SlideObject, at p: CGPoint) {
        guard let owner else { return }
        owner.selection = [o.id]
        if isMaster { return }
        if o.kind == .table, let t = o.table {
            let local = CGPoint(x: p.x - o.frame.minX, y: p.y - o.frame.minY)
            for r in t.cells.indices { for c in t.cells[r].indices where !t.cells[r][c].merged && t.rect(row: r, column: c).contains(local) {
                editor.begin(o, cell: (r, c), at: p)
                return
            } }
            return
        }
        if o.kind == .chart {
            owner.editChart(o)
            return
        }
        if o.placeholder?.type == "pic" || (o.kind == .picture && o.media == nil) {
            owner.insertImageAction(nil)
            return
        }
        if o.kind == .group, let child = hit(p, in: o.children), child.text != nil {
            editor.begin(child, at: p)
            return
        }
        if o.kind == .shape || o.kind == .textBox { editor.begin(o, at: p) }
    }

    private func normalized(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if square { let m = max(abs(w), abs(h)); w = w < 0 ? -m : m; h = h < 0 ? -m : m }
        return CGRect(x: min(a.x, a.x + w), y: min(a.y, a.y + h), width: abs(w), height: abs(h))
    }

    private func snapAngle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let ang = atan2(b.y - a.y, b.x - a.x), len = hypot(b.x - a.x, b.y - a.y)
        let s = (ang / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(s) * len, y: a.y + sin(s) * len)
    }

    private func create(from a: CGPoint, to b: CGPoint, square: Bool) {
        guard let owner, let tool = insertTool else { return }
        insertTool = nil
        var r = normalized(a, b, square: square)
        let click = r.width < 4 && r.height < 4
        switch tool {
        case .line(let arrow):
            var o = SlideObject(id: 0, kind: .line, frame: .zero)
            o.geometry = arrow ? "straightConnector1" : "line"
            let end = click ? CGPoint(x: a.x + 160, y: a.y) : b
            o.setLine(from: a, to: end)
            o.line = LineStyle(color: PColor(scheme: "tx1"), width: 2, tail: arrow ? .triangle : .none)
            owner.insert([o])
        case .textBox:
            if click { r = CGRect(x: a.x, y: a.y, width: 320, height: 40) }
            owner.insertTextBox(in: r, autoHeight: click)
        case .shape(let prst):
            if click { r = CGRect(x: a.x - 80, y: a.y - 55, width: 160, height: 110) }
            owner.insertShape(prst, in: r)
        }
    }

    // MARK: - Snapping

    /// Offsets that snap `r` to the slide's edges/centre and other objects; plus the guides to draw.
    private func snap(_ r: CGRect, excluding: Set<Int>, in s: Slide) -> (CGFloat, CGFloat, [(CGPoint, CGPoint)]) {
        let size = deck.size
        let threshold = 6 / scale
        var xs: [CGFloat] = [0, size.width / 2, size.width], ys: [CGFloat] = [0, size.height / 2, size.height]
        for o in s.objects where !excluding.contains(o.id) {
            let b = bounds(of: o)
            xs += [b.minX, b.midX, b.maxX]
            ys += [b.minY, b.midY, b.maxY]
        }
        func best(_ values: [CGFloat], _ targets: [CGFloat]) -> (CGFloat, CGFloat)? {
            var out: (CGFloat, CGFloat)?
            for v in values { for t in targets where abs(t - v) <= threshold && (out == nil || abs(t - v) < abs(out!.0)) { out = (t - v, t) } }
            return out
        }
        var dx: CGFloat = 0, dy: CGFloat = 0
        var g: [(CGPoint, CGPoint)] = []
        if let (d, t) = best([r.minX, r.midX, r.maxX], xs) { dx = d; g.append((CGPoint(x: t, y: 0), CGPoint(x: t, y: size.height))) }
        if let (d, t) = best([r.minY, r.midY, r.maxY], ys) { dy = d; g.append((CGPoint(x: 0, y: t), CGPoint(x: size.width, y: t))) }
        return (dx, dy, g)
    }

    /// New frame when dragging resize handle `h` (0…7 clockwise from top-left) to `p`, keeping the opposite side fixed.
    private func resized(_ o: SlideObject, handle h: Int, to p: CGPoint, keepAspect: Bool, snap: Bool) -> CGRect {
        let f = o.frame, c = CGPoint(x: f.midX, y: f.midY), a = o.rotation * .pi / 180
        var m = rotate(p, around: c, by: -a)
        m = CGPoint(x: m.x - c.x, y: m.y - c.y)
        if snap, o.rotation == 0 {
            let threshold = 6 / scale
            var xs: [CGFloat] = [0, deck.size.width / 2, deck.size.width], ys: [CGFloat] = [0, deck.size.height / 2, deck.size.height]
            for other in slide.objects where other.id != o.id { let b = bounds(of: other); xs += [b.minX, b.maxX, b.midX]; ys += [b.minY, b.maxY, b.midY] }
            let ax = m.x + c.x, ay = m.y + c.y
            if let t = xs.min(by: { abs($0 - ax) < abs($1 - ax) }), abs(t - ax) <= threshold { m.x = t - c.x; guides.append((CGPoint(x: t, y: 0), CGPoint(x: t, y: deck.size.height))) }
            if let t = ys.min(by: { abs($0 - ay) < abs($1 - ay) }), abs(t - ay) <= threshold { m.y = t - c.y; guides.append((CGPoint(x: 0, y: t), CGPoint(x: deck.size.width, y: t))) }
        }
        let hw = f.width / 2, hh = f.height / 2
        // Local positions of handles and of the opposite anchor.
        let pos: [CGPoint] = [CGPoint(x: -hw, y: -hh), CGPoint(x: 0, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: 0),
                              CGPoint(x: hw, y: hh), CGPoint(x: 0, y: hh), CGPoint(x: -hw, y: hh), CGPoint(x: -hw, y: 0)]
        let anchor = pos[(h + 4) % 8]
        var x0 = anchor.x, x1 = m.x, y0 = anchor.y, y1 = m.y
        if h == 1 || h == 5 { x0 = -hw; x1 = hw }
        if h == 3 || h == 7 { y0 = -hh; y1 = hh }
        var w = max(4, abs(x1 - x0)), hgt = max(4, abs(y1 - y0))
        if keepAspect, f.width > 0, f.height > 0, h % 2 == 0 {
            let ratio = f.width / f.height
            if w / hgt > ratio { hgt = w / ratio } else { w = hgt * ratio }
            x1 = x0 + (x1 >= x0 ? w : -w)
            y1 = y0 + (y1 >= y0 ? hgt : -hgt)
        }
        let lc = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
        let nc = rotate(CGPoint(x: c.x + lc.x, y: c.y + lc.y), around: c, by: a)
        return CGRect(x: nc.x - w / 2, y: nc.y - hgt / 2, width: w, height: hgt)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let owner else { return }
        let chars = event.charactersIgnoringModifiers ?? ""
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let objects = owner.selectedObjects
        if let scalar = chars.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey:
                if objects.isEmpty {
                    let back = Int(scalar.value) == NSLeftArrowFunctionKey || Int(scalar.value) == NSUpArrowFunctionKey
                    owner.select(slide: owner.current + (back ? -1 : 1))
                    return
                }
                var d = CGSize.zero
                switch Int(scalar.value) {
                case NSLeftArrowFunctionKey: d.width = -step
                case NSRightArrowFunctionKey: d.width = step
                case NSUpArrowFunctionKey: d.height = -step
                default: d.height = step
                }
                var s = slide
                for id in owner.selection { s.update(id) { $0.offset(by: d) } }
                owner.commit(slide: s, name: L("Move"))
                return
            case NSPageUpFunctionKey: owner.select(slide: owner.current - 1); return
            case NSPageDownFunctionKey: owner.select(slide: owner.current + 1); return
            case NSDeleteCharacter, NSBackspaceCharacter, NSDeleteFunctionKey:
                owner.deleteAction(nil); return
            case 27:
                if insertTool != nil { insertTool = nil } else { owner.selection = [] }
                return
            case 9:
                let ids = slide.objects.map(\.id)
                guard !ids.isEmpty else { return }
                let i = owner.selection.first.flatMap { ids.firstIndex(of: $0) } ?? -1
                let back = event.modifierFlags.contains(.shift)
                owner.selection = [ids[(i + (back ? -1 : 1) + ids.count) % ids.count]]
                return
            case 13, 3:
                if objects.count == 1, let o = objects.first, o.kind == .shape || o.kind == .textBox, !isMaster {
                    editor.begin(o, at: nil, selectAll: true)
                }
                return
            default: break
            }
        }
        // Typing with a text object selected starts editing it.
        if objects.count == 1, let o = objects.first, o.kind == .shape || o.kind == .textBox, !isMaster,
           event.modifierFlags.intersection([.command, .control]).isEmpty, let c = event.characters, !c.isEmpty,
           c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            editor.begin(o, at: nil, selectAll: o.text?.isEmpty ?? true)
            editor.textView.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) { owner?.copyObjects(cut: false) }
    @objc func cut(_ sender: Any?) { owner?.copyObjects(cut: true) }
    @objc func paste(_ sender: Any?) { owner?.pasteObjects() }
    @objc override func selectAll(_ sender: Any?) {
        owner?.selection = slide.objects.map(\.id)
    }

    @objc func delete(_ sender: Any?) { owner?.deleteAction(sender) }

    override func resetCursorRects() {
        if insertTool != nil { addCursorRect(visibleRect, cursor: .crosshair) }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        images(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let datas = images(from: sender.draggingPasteboard)
        guard !datas.isEmpty, let owner else { return false }
        let p = toSlide(convert(sender.draggingLocation, from: nil))
        owner.insertImages(datas, at: p)
        return true
    }

    func images(from pb: NSPasteboard) -> [Data] {
        var out: [Data] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for u in urls where (UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) ?? false) {
                if let d = try? Data(contentsOf: u) { out.append(d) }
            }
        }
        if out.isEmpty, let d = pb.data(forType: .png) ?? pb.data(forType: .tiff) { out.append(d) }
        return out
    }
}
