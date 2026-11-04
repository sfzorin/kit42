import AppKit
import Kit42

/// Word/Writer-style ruler above the pages: page margins (grey) and the text area (white) in centimetres,
/// counted from the left margin. Dragging a margin edge changes the page margins; the triangles are the
/// current paragraph's first-line, left and right indents.
final class DocRuler: NSView {
    static let height: CGFloat = 24
    static let cm: CGFloat = 28.3465

    weak var paged: PagedView?
    /// Character index of the cursor: the ruler follows its page.
    var location = 0
    /// Current margins and paragraph indents.
    var setup = PageSetup() { didSet { needsDisplay = true } }
    var paragraph: NSParagraphStyle = .default { didSet { needsDisplay = true } }
    var onMargins: ((CGFloat, CGFloat) -> Void)?
    var onIndents: ((_ firstLine: CGFloat, _ head: CGFloat, _ tail: CGFloat) -> Void)?

    private enum Handle { case leftMargin, rightMargin, firstLine, head, tail }
    private var dragging: Handle?
    private var dragValue: CGFloat = 0   // points, in the handle's own terms

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    /// Page left edge (x in the ruler) and points → ruler pixels.
    private var geometry: (x: CGFloat, scale: CGFloat)? {
        guard let paged, let card = paged.card(at: location) ?? paged.cards.first else { return nil }
        let left = convert(NSPoint(x: card.frame.minX, y: 0), from: paged).x
        let right = convert(NSPoint(x: card.frame.maxX, y: 0), from: paged).x
        guard card.frame.width > 0 else { return nil }
        return (left, (right - left) / card.frame.width)
    }

    private func margins() -> (left: CGFloat, right: CGFloat) {
        var l = setup.margins.left, r = setup.margins.right
        if dragging == .leftMargin { l = dragValue }
        if dragging == .rightMargin { r = dragValue }
        return (l, r)
    }

    private func indents() -> (first: CGFloat, head: CGFloat, tail: CGFloat) {
        var f = paragraph.firstLineHeadIndent, h = paragraph.headIndent
        // Tail: ≤ 0 counts from the right margin, > 0 from the left one.
        let width = setup.size.width - margins().left - margins().right
        var t = paragraph.tailIndent <= 0 ? width + paragraph.tailIndent : paragraph.tailIndent
        switch dragging {
        case .firstLine: f = dragValue
        case .head:
            f += dragValue - h   // the left indent carries the first line along, as in Word
            h = dragValue
        case .tail: t = dragValue
        default: break
        }
        return (f, h, t)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
        guard let (x0, k) = geometry else { return }
        let (ml, mr) = margins()
        let page = NSRect(x: x0, y: 4, width: setup.size.width * k, height: bounds.height - 9)
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: page, xRadius: 2, yRadius: 2).fill()
        let textX = x0 + ml * k, textW = (setup.size.width - ml - mr) * k
        NSColor.textBackgroundColor.setFill()
        NSRect(x: textX, y: page.minY, width: textW, height: page.height).fill()

        // Ticks: every 0.5 cm, numbers every cm, counted from the left margin.
        let font = NSFont.systemFont(ofSize: 8.5)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        NSColor.tertiaryLabelColor.setFill()
        let startCm = -Int(ml / Self.cm * 2), endCm = Int((setup.size.width - ml) / Self.cm * 2)
        for half in startCm...max(startCm, endCm) {
            let x = textX + CGFloat(half) * Self.cm / 2 * k
            guard x >= page.minX + 2, x <= page.maxX - 2, half != 0 else { continue }
            if half % 2 == 0 {
                let s = "\(abs(half / 2))" as NSString
                let size = s.size(withAttributes: attrs)
                if Self.cm * k > size.width + 4 { s.draw(at: NSPoint(x: x - size.width / 2, y: page.midY - size.height / 2), withAttributes: attrs) }
                else { NSRect(x: x - 0.5, y: page.midY - 3, width: 1, height: 6).fill() }
            } else {
                NSRect(x: x - 0.5, y: page.midY - 1.5, width: 1, height: 3).fill()
            }
        }

        // Indent markers.
        let (f, h, t) = indents()
        let accent = NSColor.controlAccentColor
        triangle(at: textX + f * k, top: true, color: dragging == .firstLine ? accent : .secondaryLabelColor)
        triangle(at: textX + h * k, top: false, color: dragging == .head ? accent : .secondaryLabelColor)
        triangle(at: textX + t * k, top: false, color: dragging == .tail ? accent : .secondaryLabelColor)

        if let d = dragging {
            // Value while dragging.
            let value: CGFloat
            switch d {
            case .leftMargin: value = ml
            case .rightMargin: value = mr
            case .firstLine: value = f
            case .head: value = h
            case .tail: value = setup.size.width - ml - mr - t
            }
            let s = String(format: "%.2f %@", value / Self.cm, L("cm")) as NSString
            let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: accent]
            let size = s.size(withAttributes: label)
            let x = d == .leftMargin ? textX : d == .rightMargin ? textX + textW : d == .firstLine ? textX + f * k : d == .head ? textX + h * k : textX + t * k
            NSColor.windowBackgroundColor.setFill()
            let box = NSRect(x: min(bounds.width - size.width - 6, max(2, x + 6)), y: 1, width: size.width + 4, height: size.height)
            box.fill()
            s.draw(at: NSPoint(x: box.minX + 2, y: box.minY), withAttributes: label)
        }
    }

    private func triangle(at x: CGFloat, top: Bool, color: NSColor) {
        let p = NSBezierPath()
        if top {
            p.move(to: NSPoint(x: x - 4.5, y: 2)); p.line(to: NSPoint(x: x + 4.5, y: 2)); p.line(to: NSPoint(x: x, y: 8))
        } else {
            let b = bounds.height - 3
            p.move(to: NSPoint(x: x - 4.5, y: b)); p.line(to: NSPoint(x: x + 4.5, y: b)); p.line(to: NSPoint(x: x, y: b - 6))
        }
        p.close()
        color.setFill()
        p.fill()
    }

    private func handle(at point: NSPoint) -> Handle? {
        guard let (x0, k) = geometry else { return nil }
        let (ml, mr) = margins()
        let textX = x0 + ml * k
        let (f, h, t) = indents()
        let top = point.y < bounds.height / 2
        if top, abs(point.x - (textX + f * k)) <= 5 { return .firstLine }
        if !top, abs(point.x - (textX + h * k)) <= 5 { return .head }
        if !top, abs(point.x - (textX + t * k)) <= 5 { return .tail }
        if abs(point.x - textX) <= 4 { return .leftMargin }
        if abs(point.x - (x0 + (setup.size.width - mr) * k)) <= 4 { return .rightMargin }
        return nil
    }

    override func resetCursorRects() {
        guard let (x0, k) = geometry else { return }
        let (ml, mr) = margins()
        for x in [x0 + ml * k, x0 + (setup.size.width - mr) * k] {
            addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let h = handle(at: p), let (x0, k) = geometry else { return }
        dragging = h
        let (ml, mr) = margins()
        let (f, hd, t) = indents()
        switch h {
        case .leftMargin: dragValue = ml
        case .rightMargin: dragValue = mr
        case .firstLine: dragValue = f
        case .head: dragValue = hd
        case .tail: dragValue = t
        }
        let snap = Self.cm / 4
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            let x = convert(e.locationInWindow, from: nil).x
            var v = (x - x0) / k                       // points from the page's left edge
            if !e.modifierFlags.contains(.option) { v = (v / snap).rounded() * snap }
            let textWidth = setup.size.width - ml - mr
            switch h {
            case .leftMargin: dragValue = clamp(v, 0, setup.size.width - mr - Self.cm * 2)
            case .rightMargin: dragValue = clamp(setup.size.width - v, 0, setup.size.width - ml - Self.cm * 2)
            case .firstLine: dragValue = clamp(v - ml, 0, textWidth - Self.cm)
            case .head: dragValue = clamp(v - ml, 0, textWidth - Self.cm)
            case .tail: dragValue = clamp(v - ml, Self.cm, textWidth)
            }
            needsDisplay = true
        }
        let (nf, nh, nt) = indents()
        let (nl, nr) = margins()
        dragging = nil
        switch h {
        case .leftMargin, .rightMargin: onMargins?(nl, nr)
        case .firstLine, .head, .tail:
            let width = setup.size.width - nl - nr
            onIndents?(max(0, nf), nh, nt >= width - 0.5 ? 0 : nt - width)
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}
