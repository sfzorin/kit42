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

    public init(_ elements: [Element]) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .bottom
        fullScreenMinHeight = Theme42.stripHeight

        stack.orientation = .horizontal
        stack.spacing = 8
        for element in elements {
            switch element {
            case .group(let items): stack.addArrangedSubview(group(items))
            case .tools(let commands): stack.addArrangedSubview(group(commands.map { .tool($0) }))
            case .buttons(let commands): stack.addArrangedSubview(group(commands.map { .command($0) }))
            case .view(let view): stack.addArrangedSubview(group([.view(view)]))
            }
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: Theme42.stripHeight))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 10),
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
        stack.arrangedSubviews.flatMap { ($0 as? StripGroup)?.items ?? [] }
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

/// Rounded capsule holding related controls.
final class StripGroup: NSView {
    let items: [NSView]

    init(_ views: [NSView]) {
        items = views
        super.init(frame: .zero)
        let stack = NSStackView(views: views)
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
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
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
