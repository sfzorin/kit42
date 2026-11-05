import AppKit
import Kit42

extension SlideShowController: NSWindowDelegate {
    /// Closing the show window (present in a window) ends the show.
    func windowWillClose(_ notification: Notification) {
        if SlideShowController.current === self { DispatchQueue.main.async { [weak self] in self?.end() } }
    }
}

/// Slide show tools: laser pointer (L), pen (P, E erases), slide overview (G), cursor (C).
enum ShowTool { case none, laser, pen }

/// Drawn over the slide in the show: ink per slide and the laser dot (slide coordinates, 0…1).
final class ShowOverlay: NSView {
    weak var show: SlideShowController?
    var tool: ShowTool = .none { didSet { updateTracking(); needsDisplay = true } }
    var laser: CGPoint?
    /// Strokes of the current slide, in fractions of the slide rect.
    var strokes: [[CGPoint]] = [] { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { tool == .none ? nil : super.hitTest(point) }

    private func updateTracking() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
        if tool == .laser { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private var slideRect: CGRect { (superview as? ShowView)?.slideRect ?? bounds }

    private func unit(_ p: CGPoint) -> CGPoint {
        let r = slideRect
        return CGPoint(x: (p.x - r.minX) / max(1, r.width), y: (p.y - r.minY) / max(1, r.height))
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .laser else { return }
        laser = unit(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { laser = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        switch tool {
        case .pen: strokes.append([unit(convert(event.locationInWindow, from: nil))])
        case .laser: show?.next()
        case .none: break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if tool == .pen, !strokes.isEmpty { strokes[strokes.count - 1].append(unit(convert(event.locationInWindow, from: nil))) }
        else if tool == .laser { mouseMoved(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if tool == .pen { show?.saveInk(strokes) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = slideRect
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(max(2, r.width / 400))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes where s.count > 0 {
            if s.count == 1 { let p = view(s[0]); ctx.fillEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)); continue }
            ctx.addLines(between: s.map(view))
            ctx.strokePath()
        }
        if tool == .laser, let l = laser {
            let p = view(l), d = max(10, r.width / 90)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.35).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - d, y: p.y - d, width: d * 2, height: d * 2))
            ctx.setFillColor(NSColor.systemRed.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        }
    }
}

/// G in the show: all slides in a grid; click one (or arrows + Return) to go there, Esc closes.
final class ShowOverview: NSView {
    weak var show: SlideShowController?
    var images: [CGImage] = []
    var selected = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var columns: Int { max(2, Int(ceil(sqrt(Double(max(1, images.count)) * 1.4)))) }

    func cell(_ i: Int) -> CGRect {
        let cols = columns, rows = Int(ceil(Double(images.count) / Double(cols)))
        let gap: CGFloat = 16
        let aspect = show.map { $0.deck.size.width / $0.deck.size.height } ?? 16 / 9
        var w = (bounds.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        var h = w / aspect
        let totalH = h * CGFloat(rows) + gap * CGFloat(rows + 1)
        if totalH > bounds.height { h = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(max(1, rows)); w = h * aspect }
        let ox = (bounds.width - (w * CGFloat(cols) + gap * CGFloat(cols - 1))) / 2
        let oy = max(gap, (bounds.height - (h * CGFloat(rows) + gap * CGFloat(rows - 1))) / 2)
        return CGRect(x: ox + CGFloat(i % cols) * (w + gap), y: oy + CGFloat(i / cols) * (h + gap), width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.96).setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, img) in images.enumerated() {
            let r = cell(i)
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
            ctx.restoreGState()
            if i == selected {
                NSColor.controlAccentColor.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: -3, dy: -3)); p.lineWidth = 4; p.stroke()
            }
            let n = NSAttributedString(string: "\(i + 1)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            n.draw(at: CGPoint(x: r.minX, y: r.maxY + 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = images.indices.first(where: { cell($0).contains(p) }) { show?.closeOverview(go: i) }
    }

    override func keyDown(with event: NSEvent) {
        guard let s = event.charactersIgnoringModifiers?.unicodeScalars.first else { return }
        switch Int(s.value) {
        case NSRightArrowFunctionKey: selected = min(images.count - 1, selected + 1)
        case NSLeftArrowFunctionKey: selected = max(0, selected - 1)
        case NSDownArrowFunctionKey: selected = min(images.count - 1, selected + columns)
        case NSUpArrowFunctionKey: selected = max(0, selected - columns)
        case 13, 3: show?.closeOverview(go: selected)
        case 27: show?.closeOverview(go: nil)
        default: if event.charactersIgnoringModifiers?.lowercased() == "g" { show?.closeOverview(go: nil) }
        }
    }
}
