import AppKit

/// Slim bar under the toolbar for a mode's tools (markup in PDF42, formatting in DOC42/XLS42).
/// Controls sit in soft rounded groups, like the inspector bars of Pages and Freeform.
public final class ToolStrip: NSTitlebarAccessoryViewController {
    public enum Item {
        /// Momentary icon button.
        case command(Command)
        /// Exclusive tool (highlighted when selected via `select(tag:)`).
        case tool(Command)
        /// Any control: StripButton with a drop-down, ColorButton, SizeStepper, pop-up…
        case view(NSView)
    }

    public enum Element {
        case group([Item])
        /// Shorthands
        case tools([Command])
        case buttons([Command])
        case view(NSView)
    }

    private let stack = NSStackView()
    private var toolButtons: [StripButton] = []
    private var groups: [StripGroup] = []
    /// Shown when the window is too narrow: the groups that did not fit, as a menu.
    private let overflow = StripButton(symbol: "chevron.right.2", toolTip: L("More"))

    public init(_ elements: [Element]) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        fullScreenMinHeight = Theme42.stripHeight

        stack.orientation = .horizontal
        stack.spacing = 8
        for element in elements {
            switch element {
            case .group(let items): groups.append(group(items))
            case .tools(let commands): groups.append(group(commands.map { .tool($0) }))
            case .buttons(let commands): groups.append(group(commands.map { .command($0) }))
            case .view(let view): groups.append(group([.view(view)]))
            }
        }
        // Groups further right give way first when the window is narrow.
        for (i, g) in groups.enumerated() {
            stack.addArrangedSubview(g)
            stack.setVisibilityPriority(i == 0 ? .mustHold : NSStackView.VisibilityPriority(rawValue: Float(900 - i)), for: g)
        }
        let more = StripGroup([overflow])
        more.isHidden = true
        stack.addArrangedSubview(more)
        stack.setVisibilityPriority(.mustHold, for: more)

        let container = StripContainer(frame: NSRect(x: 0, y: 0, width: 800, height: Theme42.stripHeight))
        container.onLayout = { [weak self] in self?.updateOverflow() }
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let center = stack.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        center.priority = .defaultLow
        NSLayoutConstraint.activate([
            center,
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            container.heightAnchor.constraint(equalToConstant: Theme42.stripHeight),
        ])
        view = container
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public var isShown: Bool {
        get { !isHidden }
        set { isHidden = !newValue }
    }

    /// Highlights the tool with `tag`, clearing the others.
    public func select(tag: Int) {
        toolButtons.forEach { $0.isOn = $0.tag == tag }
    }

    /// Marks momentary buttons as on/off (bold, italic… reflecting the selection).
    public func setState(_ on: Bool, for action: Selector, tag: Int = 0) {
        for case let b as StripButton in allButtons where b.action == action && b.tag == tag { b.isOn = on }
    }

    private var allButtons: [NSView] {
        groups.flatMap(\.items)
    }

    private var updatingOverflow = false

    private func updateOverflow() {
        guard !updatingOverflow else { return }
        updatingOverflow = true
        defer { updatingOverflow = false }
        let hidden = groups.filter { stack.detachedViews.contains($0) }
        let more = overflow.superview?.superview as? StripGroup
        if more?.isHidden != hidden.isEmpty { more?.isHidden = hidden.isEmpty }
        guard !hidden.isEmpty else { return }
        let menu = NSMenu()
        for (k, g) in hidden.enumerated() {
            if k > 0 { menu.addItem(.separator()) }
            for item in g.items {
                if let b = item as? StripButton {
                    if let drop = b.dropDown, let copy = drop.copy() as? NSMenu {
                        let sub = NSMenuItem(title: b.toolTip ?? "", action: nil, keyEquivalent: "")
                        sub.image = b.image
                        sub.submenu = copy
                        menu.addItem(sub)
                    } else if let action = b.action {
                        let mi = NSMenuItem(title: b.toolTip ?? "", action: action, keyEquivalent: "")
                        mi.tag = b.tag
                        mi.target = b.target
                        mi.image = b.image
                        menu.addItem(mi)
                    }
                }
            }
        }
        overflow.dropDown = menu
    }

    private func group(_ items: [Item]) -> StripGroup {
        let views: [NSView] = items.map { item in
            switch item {
            case .command(let c): return StripButton(command: c)
            case .tool(let c):
                let b = StripButton(command: c, toggle: true)
                toolButtons.append(b)
                return b
            case .view(let v): return v
            }
        }
        return StripGroup(views)
    }
}

/// Reports layout passes so the strip can refresh its overflow menu.
final class StripContainer: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        DispatchQueue.main.async { [weak self] in self?.onLayout?() }
    }
}

/// Rounded capsule holding related controls.
final class StripGroup: NSView {
    let items: [NSView]

    init(_ views: [NSView]) {
        items = views
        super.init(frame: .zero)
        let stack = NSStackView(views: views)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        path.fill()
        // labelColor-based hairline: separatorColor resolves much darker on non-vibrant backgrounds
        // (DOC42's strip showed heavy outlines while PDF42's were faint).
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
