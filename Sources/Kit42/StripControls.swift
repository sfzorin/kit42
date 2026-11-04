import AppKit

/// Borderless icon button for tool strips: soft rounded hover, accent tint when on,
/// optional drop-down menu (shows a small chevron).
public final class StripButton: NSButton {
    public var isToggle = false
    /// When set, clicking shows this menu below the button.
    public var dropDown: NSMenu? { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    public init(command: Command, toggle: Bool = false) {
        super.init(frame: .zero)
        configure(symbol: command.symbol ?? "questionmark", toolTip: command.fullToolTip)
        action = command.action
        target = nil
        tag = command.tag
        isToggle = toggle
    }

    public init(symbol: String, toolTip: String, menu: NSMenu? = nil) {
        super.init(frame: .zero)
        configure(symbol: symbol, toolTip: toolTip)
        dropDown = menu
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func configure(symbol: String, toolTip: String) {
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        widthAnchor.constraint(equalToConstant: 30).isActive = true
    }

    public func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        needsDisplay = true
    }

    public var isOn: Bool = false { didSet { needsDisplay = true } }

    public override var intrinsicContentSize: NSSize { NSSize(width: dropDown == nil ? 30 : 38, height: 26) }

    public override func updateConstraints() {
        constraints.first { $0.firstAttribute == .width }?.constant = intrinsicContentSize.width
        super.updateConstraints()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    public override func mouseDown(with event: NSEvent) {
        if let dropDown {
            needsDisplay = true
            dropDown.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
            hovering = false
            return
        }
        super.mouseDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        if isOn {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        } else if hovering || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07).setFill()
            path.fill()
        }
        guard let image else { return }
        let tint: NSColor = !isEnabled ? .tertiaryLabelColor : isOn ? .controlAccentColor : .labelColor
        let size = image.size
        let iconX = dropDown == nil ? (bounds.width - size.width) / 2 : 7
        let rect = NSRect(x: iconX, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let tinted = NSImage(size: size, flipped: false) { b in
            image.draw(in: b)
            tint.set()
            b.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
        if dropDown != nil {
            let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
            if let chevron {
                let c = NSImage(size: chevron.size, flipped: false) { b in
                    chevron.draw(in: b)
                    NSColor.secondaryLabelColor.set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                c.draw(in: NSRect(x: bounds.width - chevron.size.width - 6, y: (bounds.height - chevron.size.height) / 2,
                                  width: chevron.size.width, height: chevron.size.height))
            }
        }
    }
}

/// Builds a drop-down menu from commands (with icons), used by StripButton.
public func commandMenu(_ commands: [Command]) -> NSMenu {
    let menu = NSMenu()
    commands.forEach { menu.addItem($0.menuItem()) }
    return menu
}

// MARK: - Colour

/// Pages-style colour button: an icon with a colour bar underneath; click opens a palette.
public final class ColorButton: NSButton {
    public var color: NSColor? { didSet { needsDisplay = true } }
    public var allowsNone: Bool
    private let symbol: String
    private var hovering = false { didSet { needsDisplay = true } }
    private var popover: NSPopover?

    public init(symbol: String, toolTip: String, color: NSColor?, allowsNone: Bool = true) {
        self.symbol = symbol
        self.color = color
        self.allowsNone = allowsNone
        super.init(frame: .zero)
        title = ""
        isBordered = false
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }

    public override func mouseDown(with event: NSEvent) {
        let palette = ColorPaletteViewController(selected: color, allowsNone: allowsNone) { [weak self] picked in
            guard let self else { return }
            self.color = picked
            self.popover?.performClose(nil)
            NSApp.sendAction(self.action!, to: self.target, from: self)
        }
        let p = NSPopover()
        p.contentViewController = palette
        p.behavior = .transient
        p.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        palette.popover = p
        popover = p
    }

    public override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let size = image.size
            let tinted = NSImage(size: size, flipped: false) { b in
                image.draw(in: b)
                NSColor.labelColor.set()
                b.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 4, width: size.width, height: size.height))
        }
        let bar = NSRect(x: 7, y: 4, width: bounds.width - 14, height: 3.5)
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 1.75, yRadius: 1.75)
        if let color {
            color.setFill()
            barPath.fill()
            if color.usingColorSpace(.sRGB).map({ $0.redComponent > 0.92 && $0.greenComponent > 0.92 && $0.blueComponent > 0.92 }) == true {
                NSColor.separatorColor.setStroke()
                barPath.lineWidth = 0.5
                barPath.stroke()
            }
        } else {
            NSColor.separatorColor.setStroke()
            barPath.lineWidth = 0.75
            barPath.stroke()
        }
    }
}

/// Curated palette: neutrals, vivid and soft tones, "No colour" and the system colour panel.
public final class ColorPaletteViewController: NSViewController {
    public weak var popover: NSPopover?
    private let onPick: (NSColor?) -> Void
    private let selected: NSColor?
    private let allowsNone: Bool

    static let palette: [[String]] = [
        ["000000", "434343", "666666", "999999", "B7B7B7", "D9D9D9", "EFEFEF", "FFFFFF"],
        ["E53935", "FB8C00", "FDD835", "43A047", "00ACC1", "1E88E5", "5E35B1", "D81B60"],
        ["F4C7C3", "FCE8B2", "FFF6C2", "C8E6C9", "B2EBF2", "BBDEFB", "D1C4E9", "F8BBD0"],
        ["B71C1C", "E65100", "F9A825", "1B5E20", "006064", "0D47A1", "311B92", "880E4F"],
    ]

    public init(selected: NSColor?, allowsNone: Bool, onPick: @escaping (NSColor?) -> Void) {
        self.selected = selected
        self.allowsNone = allowsNone
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func loadView() {
        let rows = Self.palette.map { row in
            NSStackView(views: row.map { swatch(hex: $0) })
        }
        rows.forEach { $0.spacing = 6 }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.spacing = 6

        var footer: [NSView] = []
        if allowsNone {
            let none = NSButton(title: L("No Colour"), image: NSImage(systemSymbolName: "slash.circle", accessibilityDescription: nil) ?? NSImage(),
                                target: self, action: #selector(pickNone))
            none.bezelStyle = .accessoryBarAction
            none.imagePosition = .imageLeading
            none.controlSize = .small
            footer.append(none)
        }
        footer.append(NSView())
        let more = NSButton(title: L("More Colours…"), image: NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(more))
        more.bezelStyle = .accessoryBarAction
        more.imagePosition = .imageLeading
        more.controlSize = .small
        footer.append(more)
        let bottom = NSStackView(views: footer)

        let root = NSStackView(views: [grid, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = root
    }

    private func swatch(hex: String) -> NSView {
        let color = Self.color(hex)
        let b = SwatchButton(color: color, selected: selected.map { Self.same($0, color) } ?? false)
        b.target = self
        b.action = #selector(picked(_:))
        return b
    }

    static func color(_ hex: String) -> NSColor {
        let v = Int(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        return abs(x.redComponent - y.redComponent) < 0.02 && abs(x.greenComponent - y.greenComponent) < 0.02 && abs(x.blueComponent - y.blueComponent) < 0.02
    }

    @objc private func picked(_ sender: SwatchButton) { onPick(sender.color) }
    @objc private func pickNone() { onPick(nil) }

    @objc private func more() {
        popover?.performClose(nil)
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        if let selected { panel.color = selected }
        panel.makeKeyAndOrderFront(nil)
        retainedForPanel = self
    }

    private var retainedForPanel: ColorPaletteViewController?

    @objc private func panelChanged(_ sender: NSColorPanel) { onPick(sender.color) }
}

final class SwatchButton: NSButton {
    let color: NSColor
    private let isSelected: Bool

    init(color: NSColor, selected: Bool) {
        self.color = color
        isSelected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        title = ""
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        if isSelected || isHighlighted {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

// MARK: - Size stepper

/// Compact "−  12  +" control for font sizes.
public final class SizeStepper: NSView, NSTextFieldDelegate {
    public var value: CGFloat = 12 { didSet { field.stringValue = Self.text(value) } }
    public var target: AnyObject?
    public var action: Selector?
    public var steps: [CGFloat] = [6, 7, 8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96]
    private let field = NSTextField()

    public init(toolTip: String) {
        super.init(frame: .zero)
        let minus = StripButton(symbol: "minus", toolTip: toolTip)
        minus.target = self
        minus.action = #selector(decrease)
        let plus = StripButton(symbol: "plus", toolTip: toolTip)
        plus.target = self
        plus.action = #selector(increase)
        for b in [minus, plus] {
            b.constraints.first { $0.firstAttribute == .width }?.constant = 22
        }
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.focusRingType = .none
        field.delegate = self
        field.toolTip = toolTip
        field.target = self
        field.action = #selector(typed)
        field.stringValue = Self.text(value)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let stack = NSStackView(views: [minus, field, plus])
        stack.spacing = 0
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

    static func text(_ v: CGFloat) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }

    private func commit(_ v: CGFloat) {
        value = min(409, max(1, v))
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    @objc private func decrease() { commit(steps.last { $0 < value - 0.01 } ?? max(1, value - 1)) }
    @objc private func increase() { commit(steps.first { $0 > value + 0.01 } ?? value + 1) }

    @objc private func typed() {
        guard let v = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) else { field.stringValue = Self.text(value); return }
        commit(CGFloat(v))
        window?.makeFirstResponder(nil)
    }
}

// MARK: - Plain pop-up

/// Borderless pop-up (font, style, number format) that sits inside a strip group.
public func stripPopUp(_ titles: [String], width: CGFloat, toolTip: String, target: AnyObject?, action: Selector) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.addItems(withTitles: titles)
    p.isBordered = false
    p.font = .systemFont(ofSize: 12, weight: .medium)
    p.controlSize = .regular
    p.toolTip = toolTip
    p.target = target
    p.action = action
    p.translatesAutoresizingMaskIntoConstraints = false
    p.widthAnchor.constraint(equalToConstant: width).isActive = true
    p.heightAnchor.constraint(equalToConstant: 26).isActive = true
    return p
}
