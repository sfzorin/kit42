import AppKit
import Kit42

/// Right panel: Slide / Shape / Text tabs.
final class InspectorController: NSViewController {
    weak var owner: DeckWindowController?
    private let tabs = NSSegmentedControl(labels: [L("Slide"), L("Shape"), L("Text")], trackingMode: .selectOne, target: nil, action: nil)
    private let slidePane = NSStackView(), shapePane = NSStackView(), textPane = NSStackView()
    private let scroll = NSScrollView()
    private var updating = false

    // Slide
    private let layoutPopup = NSPopUpButton()
    private let bgKind = NSPopUpButton()
    private let bgColor = ColorButton(symbol: "paintbrush.fill", toolTip: L("Background colour"), color: .white, allowsNone: false)
    private let bgColor2 = ColorButton(symbol: "paintbrush", toolTip: L("Second gradient colour"), color: .gray, allowsNone: false)
    private let bgAngle = NSTextField()
    private let bgAll = NSButton(title: L("Apply to All Slides"), target: nil, action: nil)
    private let transKind = NSPopUpButton()
    private let transDuration = NSTextField()
    private let transDirection = NSPopUpButton()
    private let hideSlide = NSButton(checkboxWithTitle: L("Hide slide in the show"), target: nil, action: nil)
    private let themePopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()

    // Shape
    private let posX = NSTextField(), posY = NSTextField(), width = NSTextField(), height = NSTextField(), rotation = NSTextField()
    private let fillKind = NSPopUpButton()
    private let fillColor = ColorButton(symbol: "paintbrush.fill", toolTip: L("Fill colour"), color: .systemBlue, allowsNone: false)
    private let fillColor2 = ColorButton(symbol: "paintbrush", toolTip: L("Second gradient colour"), color: .white, allowsNone: false)
    private let lineColor = ColorButton(symbol: "pencil.tip", toolTip: L("Line colour"), color: .black, allowsNone: true)
    private let lineWidth = NSTextField()
    private let lineDash = NSPopUpButton()
    private let headPopup = NSPopUpButton(), tailPopup = NSPopUpButton()
    private let opacity = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let corner = NSSlider(value: 16, minValue: 0, maxValue: 50, target: nil, action: nil)
    private let shadow = NSButton(checkboxWithTitle: L("Shadow"), target: nil, action: nil)
    private let buildPopup = NSPopUpButton()
    private let noSelection = NSTextField(wrappingLabelWithString: L("Select an object on the slide to change its size, fill and line."))

    // Text
    private let fontPopup = NSPopUpButton()
    private let sizeStepper = SizeStepper(toolTip: L("Font size"))
    private let styleButtons = NSSegmentedControl()
    private let textColor = ColorButton(symbol: "textformat", toolTip: L("Text colour"), color: .black, allowsNone: false)
    private let alignSeg = NSSegmentedControl()
    private let anchorSeg = NSSegmentedControl()
    private let bulletPopup = NSPopUpButton()
    private let spacingPopup = NSPopUpButton()
    private let autofitPopup = NSPopUpButton()
    private let noText = NSTextField(wrappingLabelWithString: L("Select a text box or shape, or click into text, to format it."))

    init(owner: DeckWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    static let fonts = ["Helvetica Neue", "Avenir Next", "Gill Sans", "Futura", "Optima", "Georgia", "Palatino", "Times New Roman", "Baskerville",
                        "Arial", "Verdana", "Trebuchet MS", "Menlo", "Courier New"]

    override func loadView() {
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.segmentDistribution = .fillEqually
        for (pane, _) in [(slidePane, 0), (shapePane, 1), (textPane, 2)] {
            pane.orientation = .vertical
            pane.alignment = .leading
            pane.spacing = 10
        }
        buildSlidePane()
        buildShapePane()
        buildTextPane()

        let content = NSStackView(views: [tabs, slidePane, shapePane, textPane])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 20, right: 16)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), content.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            content.topAnchor.constraint(equalTo: flipped.topAnchor), content.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
        for pane in [slidePane, shapePane, textPane] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }
        scroll.documentView = flipped
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        view = effect
        tabChanged()
    }

    // MARK: - Building

    private func header(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func grid(_ rows: [(String, [NSView])]) -> NSGridView {
        let g = NSGridView(views: rows.map { r -> [NSView] in
            let l = NSTextField(labelWithString: r.0)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            let stack = NSStackView(views: r.1)
            stack.spacing = 6
            return [l, stack]
        })
        g.rowSpacing = 8
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .none
        for i in 0..<g.numberOfRows { g.row(at: i).yPlacement = .center }
        g.column(at: 0).width = 112
        return g
    }

    private func popup(_ p: NSPopUpButton, _ titles: [String], _ action: Selector, width: CGFloat = 150) {
        p.removeAllItems()
        p.addItems(withTitles: titles)
        p.target = self
        p.action = action
        p.controlSize = .regular
        p.translatesAutoresizingMaskIntoConstraints = false
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func field(_ f: NSTextField, _ action: Selector, width: CGFloat = 64) {
        f.target = self
        f.action = action
        f.alignment = .right
        f.controlSize = .regular
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func unit(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.textColor = .tertiaryLabelColor
        t.font = .systemFont(ofSize: 11)
        return t
    }

    private func buildSlidePane() {
        popup(layoutPopup, [], #selector(layoutChanged))
        popup(bgKind, [L("Master"), L("None"), L("Colour"), L("Gradient"), L("Picture…")], #selector(backgroundChanged), width: 110)
        for b in [bgColor, bgColor2] { b.target = self; b.action = #selector(backgroundChanged) }
        field(bgAngle, #selector(backgroundChanged), width: 44)
        bgAll.target = self
        bgAll.action = #selector(backgroundToAll)
        bgAll.controlSize = .small
        bgAll.bezelStyle = .rounded
        popup(transKind, TransitionKind.allCases.map(Transitions.name), #selector(transitionChanged), width: 110)
        field(transDuration, #selector(transitionChanged), width: 44)
        popup(transDirection, [L("From Right"), L("From Left"), L("From Bottom"), L("From Top")], #selector(transitionChanged), width: 140)
        hideSlide.target = self
        hideSlide.action = #selector(hideChanged)
        popup(themePopup, Themes.names, #selector(themeChanged))
        popup(sizePopup, [L("Widescreen 16:9"), L("Standard 4:3")], #selector(sizeChanged))
        slidePane.setViews([
            header(L("LAYOUT")), grid([(L("Layout:"), [layoutPopup])]),
            header(L("BACKGROUND")), grid([(L("Fill:"), [bgKind, bgColor, bgColor2]), (L("Angle:"), [bgAngle, unit("°")]), ("", [bgAll])]),
            header(L("TRANSITION")), grid([(L("Effect:"), [transKind]), (L("Duration:"), [transDuration, unit(L("s"))]), (L("Direction:"), [transDirection])]),
            hideSlide,
            header(L("PRESENTATION")), grid([(L("Theme:"), [themePopup]), (L("Slide size:"), [sizePopup])]),
        ], in: .top)
    }

    private func buildShapePane() {
        for f in [posX, posY, width, height] { field(f, #selector(geometryChanged)) }
        field(rotation, #selector(geometryChanged), width: 50)
        popup(fillKind, [L("None"), L("Colour"), L("Gradient")], #selector(fillChanged), width: 110)
        for b in [fillColor, fillColor2] { b.target = self; b.action = #selector(fillChanged) }
        lineColor.target = self
        lineColor.action = #selector(lineChanged)
        field(lineWidth, #selector(lineChanged), width: 44)
        popup(lineDash, [L("Solid"), L("Dashed"), L("Dotted"), L("Dash-Dot"), L("Long Dash")], #selector(lineChanged), width: 110)
        let heads = [L("None"), L("Triangle"), L("Arrow"), L("Stealth"), L("Circle"), L("Diamond")]
        popup(headPopup, heads, #selector(lineChanged), width: 96)
        popup(tailPopup, heads, #selector(lineChanged), width: 96)
        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacity.isContinuous = false
        corner.target = self
        corner.action = #selector(cornerChanged)
        corner.isContinuous = false
        for s in [opacity, corner] { s.translatesAutoresizingMaskIntoConstraints = false; s.widthAnchor.constraint(equalToConstant: 140).isActive = true }
        shadow.target = self
        shadow.action = #selector(shadowChanged)
        popup(buildPopup, [L("None"), L("Appear"), L("Fade In"), L("Fly In"), L("Zoom")], #selector(buildChanged), width: 110)
        noSelection.textColor = .secondaryLabelColor
        noSelection.preferredMaxLayoutWidth = 220
        shapePane.setViews([
            noSelection,
            header(L("SIZE AND POSITION")),
            grid([(L("Position:"), [posX, posY, unit(L("cm"))]), (L("Size:"), [width, height, unit(L("cm"))]), (L("Rotation:"), [rotation, unit("°")])]),
            header(L("FILL")), grid([(L("Fill:"), [fillKind, fillColor, fillColor2])]),
            header(L("LINE")), grid([(L("Colour:"), [lineColor, lineWidth, unit(L("pt"))]), (L("Dash:"), [lineDash]), (L("Start:"), [headPopup]), (L("End:"), [tailPopup])]),
            header(L("EFFECTS")), grid([(L("Opacity:"), [opacity]), (L("Corners:"), [corner]), ("", [shadow])]),
            header(L("ANIMATION")), grid([(L("Build in:"), [buildPopup])]),
        ], in: .top)
    }

    private func buildTextPane() {
        popup(fontPopup, Self.fonts, #selector(fontChanged), width: 160)
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped)
        styleButtons.segmentCount = 4
        for (i, s) in ["bold", "italic", "underline", "strikethrough"].enumerated() {
            styleButtons.setImage(NSImage(systemSymbolName: s, accessibilityDescription: s), forSegment: i)
            styleButtons.setWidth(32, forSegment: i)
        }
        styleButtons.trackingMode = .selectAny
        styleButtons.target = self
        styleButtons.action = #selector(styleChanged)
        textColor.target = self
        textColor.action = #selector(textColorChanged)
        alignSeg.segmentCount = 4
        for (i, s) in ["text.alignleft", "text.aligncenter", "text.alignright", "text.justify"].enumerated() {
            alignSeg.setImage(NSImage(systemSymbolName: s, accessibilityDescription: s), forSegment: i)
            alignSeg.setWidth(32, forSegment: i)
        }
        alignSeg.trackingMode = .selectOne
        alignSeg.target = self
        alignSeg.action = #selector(alignChanged)
        anchorSeg.segmentCount = 3
        for (i, s) in ["arrow.up.to.line", "arrow.up.and.down", "arrow.down.to.line"].enumerated() {
            anchorSeg.setImage(NSImage(systemSymbolName: s, accessibilityDescription: s), forSegment: i)
            anchorSeg.setWidth(32, forSegment: i)
        }
        anchorSeg.trackingMode = .selectOne
        anchorSeg.target = self
        anchorSeg.action = #selector(anchorChanged)
        popup(bulletPopup, [L("None"), L("Bullets"), L("Numbers")], #selector(bulletChanged), width: 110)
        popup(spacingPopup, ["0.9", "1.0", "1.15", "1.5", "2.0"], #selector(spacingChanged), width: 80)
        popup(autofitPopup, [L("Do Not Autofit"), L("Shrink Text on Overflow"), L("Resize Shape to Fit Text")], #selector(autofitChanged), width: 172)
        noText.textColor = .secondaryLabelColor
        noText.preferredMaxLayoutWidth = 220
        textPane.setViews([
            noText,
            header(L("FONT")),
            grid([(L("Font:"), [fontPopup]), (L("Size:"), [sizeStepper, textColor]), (L("Style:"), [styleButtons])]),
            header(L("PARAGRAPH")),
            grid([(L("Align:"), [alignSeg]), (L("Vertical:"), [anchorSeg]), (L("Bullets:"), [bulletPopup]), (L("Spacing:"), [spacingPopup])]),
            header(L("TEXT BOX")), grid([(L("Autofit:"), [autofitPopup])]),
        ], in: .top)
    }

    // MARK: - Tabs

    func select(tab: Int) {
        _ = view
        tabs.selectedSegment = tab
        tabChanged()
    }

    @objc private func tabChanged() {
        slidePane.isHidden = tabs.selectedSegment != 0
        shapePane.isHidden = tabs.selectedSegment != 1
        textPane.isHidden = tabs.selectedSegment != 2
        reload()
    }

    // MARK: - Reading the selection

    private func cm(_ v: CGFloat) -> String { String(format: "%.2f", v / pointsPerCm) }
    private func number(_ f: NSTextField) -> CGFloat? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".")).map { CGFloat($0) } }

    func reload() {
        guard isViewLoaded, let owner, !view.isHidden || true else { return }
        updating = true
        defer { updating = false }
        let deck = owner.deck
        let slide = owner.currentSlide
        let master = owner.mode == .master
        // Slide
        layoutPopup.removeAllItems()
        layoutPopup.addItems(withTitles: deck.layouts.map(Themes.displayName))
        if let s = slide { layoutPopup.selectItem(at: s.layout) }
        layoutPopup.isEnabled = !master && slide != nil
        let bg: Fill? = master ? deck.master.background : slide?.background
        switch bg {
        case nil: bgKind.selectItem(at: 0)
        case .none?: bgKind.selectItem(at: 1)
        case .solid(let c)?: bgKind.selectItem(at: 2); bgColor.color = c.resolved(deck.theme)
        case .gradient(let g)?:
            bgKind.selectItem(at: 3)
            bgColor.color = g.stops.first?.color.resolved(deck.theme)
            bgColor2.color = g.stops.last?.color.resolved(deck.theme)
            bgAngle.stringValue = "\(Int(g.angle))"
        case .picture?: bgKind.selectItem(at: 4)
        }
        bgKind.item(at: 0)?.isEnabled = !master
        let k = bgKind.indexOfSelectedItem
        bgColor.isHidden = !(k == 2 || k == 3)
        bgColor2.isHidden = k != 3
        setRowHidden(bgAngle, k != 3)
        bgAll.isEnabled = !master && slide != nil
        let t = slide?.transition ?? Transition()
        transKind.selectItem(at: TransitionKind.allCases.firstIndex(of: t.kind) ?? 0)
        transDuration.stringValue = String(format: "%.1f", t.duration)
        transDirection.selectItem(at: ["l", "r", "u", "d"].firstIndex(of: t.direction) ?? 0)
        transDirection.isEnabled = [.push, .wipe, .cover].contains(t.kind)
        for c in [transKind, transDuration, transDirection] as [NSControl] where master { c.isEnabled = false }
        hideSlide.state = slide?.hidden == true ? .on : .off
        hideSlide.isEnabled = !master && slide != nil
        themePopup.selectItem(at: Themes.all.firstIndex { $0.theme.name == deck.theme.name } ?? -1)
        if themePopup.indexOfSelectedItem < 0 { themePopup.setTitle(deck.theme.name) }
        sizePopup.selectItem(at: abs(deck.size.width / deck.size.height - 4.0 / 3) < 0.02 ? 1 : 0)

        // Shape
        let objs = owner.selectedObjects
        let o = objs.first
        noSelection.isHidden = o != nil
        for v in shapePane.arrangedSubviews where v !== noSelection { v.isHidden = o == nil }
        if let o {
            posX.stringValue = cm(o.frame.minX); posY.stringValue = cm(o.frame.minY)
            width.stringValue = cm(o.frame.width); height.stringValue = cm(o.frame.height)
            rotation.stringValue = "\(Int(o.rotation.rounded()))"
            switch o.fill {
            case .none: fillKind.selectItem(at: 0)
            case .solid(let c): fillKind.selectItem(at: 1); fillColor.color = c.resolved(deck.theme)
            case .gradient(let g):
                fillKind.selectItem(at: 2)
                fillColor.color = g.stops.first?.color.resolved(deck.theme)
                fillColor2.color = g.stops.last?.color.resolved(deck.theme)
            case .picture: fillKind.selectItem(at: 0)
            }
            fillKind.isEnabled = o.kind != .line && o.kind != .picture && o.kind != .table
            fillColor.isHidden = fillKind.indexOfSelectedItem == 0
            fillColor2.isHidden = fillKind.indexOfSelectedItem != 2
            lineColor.color = o.line.color?.resolved(deck.theme)
            lineWidth.stringValue = String(format: "%.1f", o.line.width)
            lineDash.selectItem(at: [Dash.solid, .dash, .dot, .dashDot, .lgDash].firstIndex(of: o.line.dash) ?? 0)
            headPopup.selectItem(at: Arrowhead.allCases.firstIndex(of: o.line.head) ?? 0)
            tailPopup.selectItem(at: Arrowhead.allCases.firstIndex(of: o.line.tail) ?? 0)
            headPopup.isEnabled = o.isLine
            tailPopup.isEnabled = o.isLine
            opacity.doubleValue = Double(o.opacity * 100)
            corner.isEnabled = o.geometry == "roundRect"
            corner.doubleValue = Double(o.adjust["adj"] ?? 16667) / 1000
            shadow.state = o.shadow ? .on : .off
            buildPopup.selectItem(at: o.build.map { (BuildEffect.allCases.firstIndex(of: $0) ?? 0) + 1 } ?? 0)
            buildPopup.isEnabled = !master
            for f in [posX, posY, width, height, rotation] { f.isEnabled = true }
        }

        // Text
        let hasText = owner.isEditingText || objs.contains { $0.text != nil || $0.table != nil }
        noText.isHidden = hasText
        for v in textPane.arrangedSubviews where v !== noText { v.isHidden = !hasText }
        if hasText {
            let r = owner.currentRunProps
            let l = owner.currentLevelStyle
            let family = deck.theme.font(r.font) ?? deck.theme.minorFont
            if fontPopup.item(withTitle: family) == nil { fontPopup.addItem(withTitle: family) }
            fontPopup.selectItem(withTitle: family)
            sizeStepper.value = r.size ?? 18
            textColor.color = (r.color ?? PColor(scheme: "tx1")).resolved(deck.theme)
            for (i, on) in [r.bold, r.italic, r.underline, r.strike].enumerated() { styleButtons.setSelected(on == true, forSegment: i) }
            alignSeg.selectedSegment = TextAlign.allCases.firstIndex(of: l.align ?? .left) ?? 0
            let a = o?.text?.anchor ?? .top
            anchorSeg.selectedSegment = a == .top ? 0 : a == .middle ? 1 : 2
            let bk = l.bullet?.kind ?? Bullet.Kind.none
            bulletPopup.selectItem(at: bk == .none ? 0 : bk == .char ? 1 : 2)
            let ls = l.lineSpacing ?? 1
            spacingPopup.selectItem(at: [0.9, 1.0, 1.15, 1.5, 2.0].firstIndex { abs($0 - ls) < 0.03 } ?? 1)
            let af = o?.text?.autofit ?? .none
            autofitPopup.selectItem(at: af == .none ? 0 : af == .shrink ? 1 : 2)
            autofitPopup.isEnabled = o?.text != nil
        }
    }

    /// Hides the grid row holding `view`.
    private func setRowHidden(_ view: NSView, _ hidden: Bool) {
        guard let stack = view.superview, let grid = stack.superview as? NSGridView, let cell = grid.cell(for: stack) else { return }
        cell.row?.isHidden = hidden
    }

    // MARK: - Slide actions

    @objc private func layoutChanged() {
        guard !updating else { return }
        owner?.layoutAction(NSMenuItem.tagged(layoutPopup.indexOfSelectedItem))
    }

    private func backgroundFill() -> Fill?? {
        switch bgKind.indexOfSelectedItem {
        case 0: return .some(nil)
        case 1: return .some(Fill.none)
        case 2: return .some(.solid(PColor(bgColor.color ?? .white)))
        case 3:
            let a = number(bgAngle) ?? 90
            return .some(.gradient(Gradient(stops: [GradientStop(position: 0, color: PColor(bgColor.color ?? .white)),
                                                    GradientStop(position: 1, color: PColor(bgColor2.color ?? .gray))], angle: a)))
        default: return nil
        }
    }

    @objc private func backgroundChanged() {
        guard !updating, let owner else { return }
        if bgKind.indexOfSelectedItem == 3, bgAngle.stringValue.isEmpty { bgAngle.stringValue = "90" }
        guard let fill = backgroundFill() else {
            // Picture…
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            guard let window = owner.window else { return }
            panel.beginSheetModal(for: window) { [weak self] r in
                guard r == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let owner = self?.owner else { self?.reload(); return }
                let i = owner.current, master = owner.mode == .master
                owner.doc?.change(L("Background")) { d in
                    let name = d.addMedia(data, ext: imageExtension(data))
                    if master { d.master.background = .picture(name) } else { d.slides[i].background = .picture(name) }
                }
            }
            return
        }
        let i = owner.current
        if owner.mode == .master {
            owner.doc?.change(L("Background")) { d in d.master.background = fill ?? d.master.background }
        } else if owner.currentSlide != nil {
            owner.doc?.change(L("Background")) { d in d.slides[i].background = fill }
        }
        reload()
    }

    @objc private func backgroundToAll() {
        guard let owner, let s = owner.currentSlide else { return }
        let bg = s.background
        owner.doc?.change(L("Background")) { d in for k in d.slides.indices { d.slides[k].background = bg } }
    }

    @objc private func transitionChanged() {
        guard !updating, let owner else { return }
        let kind = TransitionKind.allCases[max(0, transKind.indexOfSelectedItem)]
        let dur = Double(number(transDuration) ?? 0.7)
        let dir = ["l", "r", "u", "d"][max(0, transDirection.indexOfSelectedItem)]
        let idx = owner.selectedSlideIndexes
        owner.doc?.change(L("Transition")) { d in
            for i in idx { d.slides[i].transition.kind = kind; d.slides[i].transition.duration = min(10, max(0.1, dur)); d.slides[i].transition.direction = dir }
        }
    }

    @objc private func hideChanged() { if !updating { owner?.hideSlideAction(nil) } }
    @objc private func themeChanged() { if !updating { owner?.themeAction(NSMenuItem.tagged(themePopup.indexOfSelectedItem)) } }
    @objc private func sizeChanged() { if !updating { owner?.slideSizeAction(NSMenuItem.tagged(sizePopup.indexOfSelectedItem)) } }

    // MARK: - Shape actions

    @objc private func geometryChanged() {
        guard !updating, let owner, let o = owner.selectedObjects.first else { return }
        let x = (number(posX) ?? 0) * pointsPerCm, y = (number(posY) ?? 0) * pointsPerCm
        let w = max(0, (number(width) ?? 1) * pointsPerCm), h = max(0, (number(height) ?? 1) * pointsPerCm)
        let rot = (number(rotation) ?? 0).truncatingRemainder(dividingBy: 360)
        owner.changeSelected(L("Size and Position")) { obj in
            guard obj.id == o.id else { return }
            if obj.isLine {
                let a = obj.lineStart, b = obj.lineEnd
                obj.setLine(from: CGPoint(x: x + (a.x - obj.frame.minX), y: y + (a.y - obj.frame.minY)), to: CGPoint(x: x + (b.x - obj.frame.minX), y: y + (b.y - obj.frame.minY)))
                let flipH = obj.flipH, flipV = obj.flipV
                obj.frame = CGRect(x: x, y: y, width: w, height: h)
                obj.flipH = flipH; obj.flipV = flipV
            } else {
                obj.offset(by: CGSize(width: x - obj.frame.minX, height: y - obj.frame.minY))
                obj.setFrame(CGRect(x: x, y: y, width: max(1, w), height: max(1, h)))
            }
            obj.rotation = rot < 0 ? rot + 360 : rot
        }
    }

    @objc private func fillChanged() {
        guard !updating, let owner else { return }
        fillColor.isHidden = fillKind.indexOfSelectedItem == 0
        fillColor2.isHidden = fillKind.indexOfSelectedItem != 2
        let c1 = PColor(fillColor.color ?? .systemBlue), c2 = PColor(fillColor2.color ?? .white)
        let fill: Fill
        switch fillKind.indexOfSelectedItem {
        case 0: fill = .none
        case 1: fill = .solid(c1)
        default: fill = .gradient(Gradient(stops: [GradientStop(position: 0, color: c1), GradientStop(position: 1, color: c2)], angle: 90))
        }
        owner.changeSelected(L("Fill")) { o in if o.kind != .line && o.kind != .picture { o.fill = fill } }
    }

    @objc private func lineChanged() {
        guard !updating, let owner else { return }
        let color = lineColor.color.map { PColor($0) }
        let w = min(100, max(0.25, number(lineWidth) ?? 1))
        let dash = [Dash.solid, .dash, .dot, .dashDot, .lgDash][max(0, lineDash.indexOfSelectedItem)]
        let head = Arrowhead.allCases[max(0, headPopup.indexOfSelectedItem)], tail = Arrowhead.allCases[max(0, tailPopup.indexOfSelectedItem)]
        owner.changeSelected(L("Line")) { o in
            o.line.color = color
            o.line.width = w
            o.line.dash = dash
            if o.isLine { o.line.head = head; o.line.tail = tail }
        }
    }

    @objc private func opacityChanged() {
        guard !updating, let owner else { return }
        let v = CGFloat(opacity.doubleValue / 100)
        owner.changeSelected(L("Opacity")) { $0.opacity = v }
    }

    @objc private func cornerChanged() {
        guard !updating, let owner else { return }
        let v = Int(corner.doubleValue * 1000)
        owner.changeSelected(L("Corner Radius")) { o in if o.geometry == "roundRect" { o.adjust["adj"] = v } }
    }

    @objc private func shadowChanged() {
        guard !updating, let owner else { return }
        let on = shadow.state == .on
        owner.changeSelected(L("Shadow")) { $0.shadow = on }
    }

    @objc private func buildChanged() {
        guard !updating, let owner else { return }
        let i = buildPopup.indexOfSelectedItem
        let b: BuildEffect? = i <= 0 ? nil : BuildEffect.allCases[i - 1]
        owner.changeSelected(L("Animation")) { $0.build = b }
    }

    // MARK: - Text actions

    @objc private func fontChanged() { if !updating, let f = fontPopup.titleOfSelectedItem { owner?.setFont(f) } }
    @objc private func sizeStepped() { if !updating { owner?.setFontSize(sizeStepper.value) } }
    @objc private func textColorChanged() { if !updating, let c = textColor.color { owner?.setTextColor(PColor(c)) } }

    @objc private func styleChanged() {
        guard !updating, let owner else { return }
        let r = owner.currentRunProps
        let want = (0..<4).map { styleButtons.isSelected(forSegment: $0) }
        if want[0] != (r.bold ?? false) { owner.boldAction(nil) }
        if want[1] != (r.italic ?? false) { owner.italicAction(nil) }
        if want[2] != (r.underline ?? false) { owner.underlineAction(nil) }
        if want[3] != (r.strike ?? false) { owner.strikeAction(nil) }
    }

    @objc private func alignChanged() { if !updating { owner?.alignTextAction(NSMenuItem.tagged(alignSeg.selectedSegment)) } }
    @objc private func anchorChanged() { if !updating { owner?.anchorAction(NSMenuItem.tagged(anchorSeg.selectedSegment)) } }

    @objc private func bulletChanged() {
        guard !updating, let owner else { return }
        let i = bulletPopup.indexOfSelectedItem
        let cur = owner.currentLevelStyle.bullet?.kind ?? Bullet.Kind.none
        if (i == 1 && cur == .char) || (i == 2 && cur == .number) || (i == 0 && cur == .none) { return }
        owner.bulletsAction(NSMenuItem.tagged(i))
    }

    @objc private func spacingChanged() { if !updating { owner?.lineSpacingAction(NSMenuItem.tagged(spacingPopup.indexOfSelectedItem)) } }

    @objc private func autofitChanged() {
        guard !updating, let owner else { return }
        let a: Autofit = [.none, .shrink, .resize][max(0, autofitPopup.indexOfSelectedItem)]
        owner.commitEditing()
        owner.changeSelected(L("Autofit")) { o in o.text?.autofit = a }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSMenuItem {
    static func tagged(_ tag: Int) -> NSMenuItem {
        let i = NSMenuItem()
        i.tag = tag
        return i
    }
}
