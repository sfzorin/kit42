import AppKit
import Kit42

/// Page margins and paragraph indents in centimetres. Margin boundaries have a separate
/// central hit area, so zero paragraph indents cannot cover them. One drag is one undoable edit.
final class DocRuler: NSView {
    enum Orientation { case horizontal, vertical }
    static let height: CGFloat = 30
    static let cm: CGFloat = 28.3465
    let orientation: Orientation
    weak var paged: PagedView?
    weak var headerTextView: NSTextView?
    var location = 0
    var setup = PageSetup() { didSet { needsDisplay = true } }
    var paragraph: NSParagraphStyle = .default { didSet { needsDisplay = true } }
    var onMargins: ((CGFloat, CGFloat, Int) -> Void)?
    var onVerticalMargins: ((CGFloat, CGFloat, Int) -> Void)?
    var onIndents: ((_ firstLine: CGFloat, _ head: CGFloat, _ tail: CGFloat) -> Void)?

    private enum Handle { case leadingMargin, trailingMargin, firstLine, head, tail }
    private struct Geometry {
        let origin: CGFloat
        let scale: CGFloat
        let setup: PageSetup
        let location: Int
        let column: Int
        let headerWidth: CGFloat?
    }
    private struct Drag {
        let handle: Handle
        let geometry: Geometry
        let paragraph: NSParagraphStyle
        let pointer: CGFloat
        let original: CGFloat
        var value: CGFloat
        var moved = false
    }
    private var drag: Drag?
    private var horizontal: Bool { orientation == .horizontal }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        horizontal ? NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
            : NSSize(width: Self.height, height: NSView.noIntrinsicMetric)
    }

    init(orientation: Orientation = .horizontal) {
        self.orientation = orientation
        super.init(frame: .zero)
        toolTip = horizontal
            ? L("Drag margin boundaries in the middle of the ruler; triangles adjust paragraph indents. Hold Option for precise adjustment.")
            : L("Drag the top and bottom margin boundaries. Hold Option for precise adjustment.")
    }
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func axis(_ point: NSPoint) -> CGFloat { horizontal ? point.x : point.y }
    private func rect(_ start: CGFloat, _ length: CGFloat, across: CGFloat, thickness: CGFloat) -> NSRect {
        horizontal ? NSRect(x: start, y: across, width: length, height: thickness)
            : NSRect(x: across, y: start, width: thickness, height: length)
    }

    private var geometry: Geometry? {
        if let drag { return drag.geometry }
        guard let paged, var card = (headerTextView?.superview as? PageCard) ?? paged.card(at: location) ?? paged.cards.first else { return nil }
        var at = location
        if headerTextView != nil, let container = card.textViews.first?.textContainer {
            at = paged.layoutManager.characterRange(forGlyphRange: paged.layoutManager.glyphRange(for: container), actualGlyphRange: nil).location
        }
        if !horizontal {
            // Follow the visible sheet while scrolling, even when the caret is on a different page.
            let visible = paged.visibleRect
            if !card.frame.intersects(visible), let next = paged.cards.first(where: { $0.frame.intersects(visible) }) {
                card = next
                if let container = card.textViews.first?.textContainer {
                    let glyphs = paged.layoutManager.glyphRange(for: container)
                    at = paged.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
                }
            }
        }
        let start = convert(NSPoint.zero, from: card)
        let end = convert(NSPoint(x: card.bounds.width, y: card.bounds.height), from: card)
        let length = horizontal ? card.bounds.width : card.bounds.height
        let scale = (axis(end) - axis(start)) / length
        guard length > 0, scale.isFinite, scale > 0 else { return nil }
        let tv = paged.textView(at: location)
        let column = card.textViews.firstIndex(where: { $0 === tv }) ?? 0
        return Geometry(origin: axis(start), scale: scale, setup: card.setup, location: at, column: column,
                        headerWidth: headerTextView?.bounds.width)
    }

    private func margins(_ g: Geometry) -> (leading: CGFloat, trailing: CGFloat) {
        var first = horizontal ? g.setup.margins.left : g.setup.margins.top
        var last = horizontal ? g.setup.margins.right : g.setup.margins.bottom
        if drag?.handle == .leadingMargin { first = drag!.value }
        if drag?.handle == .trailingMargin { last = drag!.value }
        return (first, last)
    }
    private func length(_ g: Geometry) -> CGFloat { horizontal ? g.setup.size.width : g.setup.size.height }
    private func column(_ g: Geometry) -> (start: CGFloat, width: CGFloat) {
        let m = margins(g), n = max(1, g.setup.columns), gap = g.setup.columnSpacing
        if let width = g.headerWidth { return (m.leading, width) }
        let width = max(36, (g.setup.size.width - m.leading - m.trailing - CGFloat(n - 1) * gap) / CGFloat(n))
        return (m.leading + CGFloat(g.column) * (width + gap), width)
    }
    private func indents(_ g: Geometry) -> (first: CGFloat, head: CGFloat, tail: CGFloat) {
        let p = drag?.paragraph ?? paragraph
        var first = p.firstLineHeadIndent, head = p.headIndent
        var tail = p.tailIndent <= 0 ? column(g).width + p.tailIndent : p.tailIndent
        switch drag?.handle {
        case .firstLine: first = drag!.value
        case .head: first += drag!.value - head; head = drag!.value
        case .tail: tail = drag!.value
        default: break
        }
        return (first, head, tail)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let across = horizontal ? bounds.height : bounds.width
        NSColor.separatorColor.setFill()
        rect(0, horizontal ? bounds.width : bounds.height, across: across - 0.5, thickness: 0.5).fill()
        guard let g = geometry else { return }
        let m = margins(g), start = g.origin + m.leading * g.scale
        let body = (length(g) - m.leading - m.trailing) * g.scale
        let page = rect(g.origin, length(g) * g.scale, across: 4, thickness: across - 8)
        NSColor.labelColor.withAlphaComponent(0.09).setFill(); page.fill()
        NSColor.textBackgroundColor.setFill(); rect(start, body, across: 4, thickness: across - 8).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.secondaryLabelColor]
        let lower = -Int(m.leading / Self.cm * 2), upper = Int((length(g) - m.leading) / Self.cm * 2)
        NSColor.tertiaryLabelColor.setFill()
        for half in lower...max(lower, upper) where half != 0 {
            let position = start + CGFloat(half) * Self.cm / 2 * g.scale
            guard position > g.origin + 2, position < g.origin + length(g) * g.scale - 2 else { continue }
            if half % 2 == 0 {
                let label = "\(abs(half / 2))" as NSString, size = label.size(withAttributes: attrs)
                if Self.cm * g.scale > (horizontal ? size.width : size.height) + 4 {
                    label.draw(at: horizontal ? NSPoint(x: position - size.width / 2, y: across / 2 - size.height / 2)
                               : NSPoint(x: across / 2 - size.width / 2, y: position - size.height / 2), withAttributes: attrs)
                } else { rect(position - 0.5, 1, across: across / 2 - 3, thickness: 6).fill() }
            } else { rect(position - 0.5, 1, across: across / 2 - 1.5, thickness: 3).fill() }
        }
        // Explicit boundary lines leave the central grip separate from the indent triangles.
        NSColor.secondaryLabelColor.setFill()
        for position in [start, start + body] {
            rect(position - 0.5, 1, across: horizontal ? 10 : 4, thickness: horizontal ? across - 20 : across - 8).fill()
        }
        if horizontal {
            let c = column(g), i = indents(g), x = g.origin + c.start * g.scale
            triangle(at: x + i.first * g.scale, top: true, active: drag?.handle == .firstLine)
            triangle(at: x + i.head * g.scale, top: false, active: drag?.handle == .head)
            triangle(at: x + i.tail * g.scale, top: false, active: drag?.handle == .tail)
        }
        if let drag, drag.moved {
            let value = drag.handle == .tail ? column(g).width - drag.value : drag.value
            let label = String(format: "%.2f %@", value / Self.cm, L("cm")) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
            let size = label.size(withAttributes: attributes)
            if horizontal {
                let x = min(bounds.width - size.width - 4, max(2, start + 8))
                NSColor.windowBackgroundColor.setFill(); NSRect(x: x, y: 9, width: size.width + 4, height: size.height).fill()
                label.draw(at: NSPoint(x: x + 2, y: 9), withAttributes: attributes)
            } else {
                let position = g.origin + (drag.handle == .leadingMargin ? m.leading : length(g) - m.trailing) * g.scale
                NSColor.controlAccentColor.setFill(); rect(position - 1, 2, across: 1, thickness: across - 2).fill()
            }
        }
    }

    private func triangle(at x: CGFloat, top: Bool, active: Bool) {
        let base: CGFloat = top ? 2 : bounds.height - 2, tip: CGFloat = top ? 8 : bounds.height - 8
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x - 5, y: base)); path.line(to: NSPoint(x: x + 5, y: base)); path.line(to: NSPoint(x: x, y: tip)); path.close()
        (active ? NSColor.controlAccentColor : .secondaryLabelColor).setFill(); path.fill()
    }

    private func handle(at point: NSPoint, geometry g: Geometry) -> Handle? {
        guard bounds.contains(point) else { return nil }
        let m = margins(g), position = axis(point)
        if horizontal {
            let c = column(g), i = indents(g), start = g.origin + c.start * g.scale
            if point.y <= 9, abs(position - (start + i.first * g.scale)) <= 6 { return .firstLine }
            if point.y >= bounds.height - 9 {
                if abs(position - (start + i.head * g.scale)) <= 6 { return .head }
                if abs(position - (start + i.tail * g.scale)) <= 6 { return .tail }
            }
        }
        guard paged?.viewMode != .web else { return nil }
        if abs(position - (g.origin + m.leading * g.scale)) <= 6 { return .leadingMargin }
        if abs(position - (g.origin + (length(g) - m.trailing) * g.scale)) <= 6 { return .trailingMargin }
        return nil
    }

    override func resetCursorRects() {
        guard let g = geometry else { return }
        let m = margins(g), across = horizontal ? bounds.height : bounds.width
        if paged?.viewMode != .web {
            for position in [g.origin + m.leading * g.scale, g.origin + (length(g) - m.trailing) * g.scale] {
                addCursorRect(rect(position - 6, 12, across: horizontal ? 10 : 0, thickness: horizontal ? across - 20 : across), cursor: horizontal ? .resizeLeftRight : .resizeUpDown)
            }
        }
        if horizontal {
            let c = column(g), i = indents(g), start = g.origin + c.start * g.scale
            for (position, y) in [(i.first, CGFloat(0)), (i.head, bounds.height - 9), (i.tail, bounds.height - 9)] {
                addCursorRect(NSRect(x: start + position * g.scale - 6, y: y, width: 12, height: 9), cursor: .resizeLeftRight)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let g = geometry, let handle = handle(at: point, geometry: g) else { return }
        // Capture originals before enabling preview; a click alone must never edit the document.
        let m = margins(g), i = indents(g)
        let value: CGFloat
        switch handle {
        case .leadingMargin: value = m.leading
        case .trailingMargin: value = m.trailing
        case .firstLine: value = i.first
        case .head: value = i.head
        case .tail: value = i.tail
        }
        drag = Drag(handle: handle, geometry: g, paragraph: paragraph, pointer: axis(point), original: value, value: value)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let delta = (axis(convert(event.locationInWindow, from: nil)) - d.pointer) / d.geometry.scale
        guard abs(delta * d.geometry.scale) >= 1 || d.moved else { return }
        let g = d.geometry, m = margins(g), c = column(g)
        var value = d.original + (d.handle == .trailingMargin ? -delta : delta)
        if !event.modifierFlags.contains(.option) { let snap = Self.cm / 4; value = (value / snap).rounded() * snap }
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        let minimum = horizontal ? max(Self.cm * 2, CGFloat(max(1, g.setup.columns)) * 36 + CGFloat(max(0, g.setup.columns - 1)) * g.setup.columnSpacing) : Self.cm * 2
        switch d.handle {
        case .leadingMargin: value = clamp(value, 0, length(g) - m.trailing - minimum)
        case .trailingMargin: value = clamp(value, 0, length(g) - m.leading - minimum)
        case .firstLine: value = clamp(value, 0, c.width - Self.cm)
        case .head:
            // Carry the first-line marker without letting either marker leave the column.
            let offset = d.paragraph.firstLineHeadIndent - d.paragraph.headIndent
            value = clamp(value, max(0, -offset), c.width - Self.cm - max(0, offset))
        case .tail: value = clamp(value, Self.cm, c.width)
        }
        d.value = value; d.moved = true; drag = d; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        let m = margins(d.geometry), i = indents(d.geometry), width = column(d.geometry).width
        drag = nil
        if d.moved, abs(d.value - d.original) > 0.001 {
            switch d.handle {
            case .leadingMargin, .trailingMargin:
                if horizontal { onMargins?(m.leading, m.trailing, d.geometry.location) }
                else { onVerticalMargins?(m.leading, m.trailing, d.geometry.location) }
            case .firstLine, .head, .tail:
                onIndents?(i.first, i.head, i.tail >= width - 0.5 ? 0 : i.tail - width)
            }
        }
        window?.invalidateCursorRects(for: self); needsDisplay = true
    }
    override func cancelOperation(_ sender: Any?) { drag = nil; needsDisplay = true }
}
