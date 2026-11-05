import AppKit
import Kit42

extension InspectorController {
    func buildAnimationPane() { animationPane.build() }
    func reloadAnimations() { animationPane.reload() }
}

extension DeckWindowController {
    /// Adds an animation for each selected object (after the slide's other animations).
    func addAnimation(_ e: AnimEffect, trigger: AnimTrigger = .onClick, duration: Double? = nil, delay: Double? = nil) {
        let ids = selection
        guard !ids.isEmpty, deck.slides.indices.contains(current) else { return }
        let i = current
        var added: [UUID] = []
        doc?.change(L("Add Animation")) { d in
            for (k, id) in ids.enumerated() {
                var a = Animation(target: id, effect: e, trigger: k == 0 ? trigger : .withPrevious)
                if let duration { a.duration = duration }
                if let delay { a.delay = delay }
                d.slides[i].animations.append(a)
                added.append(a.id)
            }
        }
        inspector.animationPane.selected = added.last
        inspector.reload()
        canvas.needsDisplay = true
    }

    func changeAnimation(_ id: UUID, _ name: String, _ body: @escaping (inout Animation) -> Void) {
        let i = current
        guard deck.slides.indices.contains(i) else { return }
        doc?.change(name) { d in
            if let k = d.slides[i].animations.firstIndex(where: { $0.id == id }) { body(&d.slides[i].animations[k]) }
        }
        canvas.needsDisplay = true
    }

    func removeAnimation(_ id: UUID) {
        let i = current
        guard deck.slides.indices.contains(i) else { return }
        doc?.change(L("Remove Animation")) { d in d.slides[i].animations.removeAll { $0.id == id } }
        canvas.needsDisplay = true
    }

    func moveAnimation(_ id: UUID, by delta: Int) {
        let i = current
        guard deck.slides.indices.contains(i) else { return }
        doc?.change(L("Reorder Animations")) { d in
            guard let k = d.slides[i].animations.firstIndex(where: { $0.id == id }) else { return }
            let t = min(max(0, k + delta), d.slides[i].animations.count - 1)
            let a = d.slides[i].animations.remove(at: k)
            d.slides[i].animations.insert(a, at: t)
        }
        canvas.needsDisplay = true
    }

    var animationTabShown: Bool { inspectorShown && inspector.selectedTab == 3 }
}

/// Inspector › Animation: the slide's animations in order, with effect, start, duration, delay and options.
final class AnimationPane: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: DeckWindowController?
    var selected: UUID?
    private let table = NSTableView()
    private let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let removeButton = NSButton(), upButton = NSButton(), downButton = NSButton()
    private let effectPopup = NSPopUpButton(), triggerPopup = NSPopUpButton(), directionPopup = NSPopUpButton()
    private let duration = NSTextField(), delay = NSTextField(), amount = NSTextField()
    private let colorButton = ColorButton(symbol: "paintbrush.fill", toolTip: L("Colour"), color: .systemOrange, allowsNone: false)
    private var details = NSGridView()
    private let hint = NSTextField(wrappingLabelWithString: L("Select an object on the slide, then add an entrance, emphasis, exit or motion effect."))
    private var anims: [Animation] = []
    private var updating = false

    convenience init(owner: DeckWindowController) {
        self.init(frame: .zero)
        self.owner = owner
    }

    func build() {
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let header = NSTextField(labelWithString: L("ANIMATIONS"))
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("a"))
        col.width = 230
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        addButton.bezelStyle = .rounded
        addButton.addItem(withTitle: L("Add"))
        addButton.menu?.items.first?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        for cls in AnimClass.allCases {
            let header = NSMenuItem(title: [L("Entrance"), L("Exit"), L("Emphasis"), L("Motion Path")][AnimClass.allCases.firstIndex(of: cls)!], action: nil, keyEquivalent: "")
            header.isEnabled = false
            addButton.menu?.addItem(header)
            for e in AnimEffect.of(cls) {
                let item = NSMenuItem(title: "   " + e.name, action: #selector(addEffect(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = e.rawValue
                addButton.menu?.addItem(item)
            }
        }
        for (b, sym, tip, sel) in [(removeButton, "minus", L("Remove"), #selector(remove)), (upButton, "chevron.up", L("Move Up"), #selector(up)),
                                   (downButton, "chevron.down", L("Move Down"), #selector(down))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.toolTip = tip
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
        }
        let buttons = NSStackView(views: [addButton, removeButton, upButton, downButton])
        buttons.spacing = 4

        func popup(_ p: NSPopUpButton, _ titles: [String]) {
            p.removeAllItems(); p.addItems(withTitles: titles)
            p.target = self; p.action = #selector(detailsChanged)
            p.translatesAutoresizingMaskIntoConstraints = false
            p.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        popup(effectPopup, AnimEffect.allCases.map(\.name))
        popup(triggerPopup, AnimTrigger.allCases.map(\.name))
        popup(directionPopup, [L("From Bottom"), L("From Top"), L("From Left"), L("From Right")])
        for f in [duration, delay, amount] {
            f.target = self; f.action = #selector(detailsChanged)
            f.alignment = .right
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        colorButton.target = self
        colorButton.action = #selector(detailsChanged)
        func unit(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.textColor = .tertiaryLabelColor; t.font = .systemFont(ofSize: 11); return t }
        func row(_ label: String, _ views: [NSView]) -> [NSView] {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabelColor
            let st = NSStackView(views: views); st.spacing = 6
            return [l, st]
        }
        details = NSGridView(views: [row(L("Effect:"), [effectPopup]), row(L("Start:"), [triggerPopup]), row(L("Duration:"), [duration, unit(L("s"))]),
                                     row(L("Delay:"), [delay, unit(L("s"))]), row(L("Direction:"), [directionPopup]),
                                     row(L("Amount:"), [amount, unit("")]), row(L("Colour:"), [colorButton])])
        details.rowSpacing = 8
        details.columnSpacing = 10
        details.column(at: 0).xPlacement = .trailing
        details.column(at: 0).width = 90
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 240
        setViews([header, scroll, buttons, details, hint], in: .top)
    }

    func reload() {
        guard let owner, !(subviews.isEmpty) else { return }
        updating = true
        defer { updating = false }
        anims = owner.mode == .normal ? owner.currentSlide?.animations ?? [] : []
        table.reloadData()
        if let sel = selected, let k = anims.firstIndex(where: { $0.id == sel }) {
            table.selectRowIndexes([k], byExtendingSelection: false)
        } else if let id = owner.selection.first, let k = anims.firstIndex(where: { $0.target == id }) {
            selected = anims[k].id
            table.selectRowIndexes([k], byExtendingSelection: false)
        } else {
            selected = nil
            table.deselectAll(nil)
        }
        addButton.isEnabled = owner.mode == .normal && !owner.selection.isEmpty
        let a = selected.flatMap { id in anims.first { $0.id == id } }
        removeButton.isEnabled = a != nil
        upButton.isEnabled = a != nil
        downButton.isEnabled = a != nil
        details.isHidden = a == nil
        hint.isHidden = !(anims.isEmpty || a == nil) || !owner.selection.isEmpty && !anims.isEmpty
        guard let a else { return }
        effectPopup.selectItem(at: AnimEffect.allCases.firstIndex(of: a.effect) ?? 0)
        triggerPopup.selectItem(at: AnimTrigger.allCases.firstIndex(of: a.trigger) ?? 0)
        duration.stringValue = String(format: "%.2f", a.duration)
        delay.stringValue = String(format: "%.2f", a.delay)
        let dirs = ["b", "t", "l", "r"]
        if a.effect == .path {
            directionPopup.removeAllItems()
            directionPopup.addItems(withTitles: [L("Down"), L("Up"), L("Left"), L("Right"), L("Custom")])
            let end = a.path.last ?? .zero
            let k = a.path.count == 2 && end.x == 0 && end.y > 0 ? 0 : a.path.count == 2 && end.x == 0 && end.y < 0 ? 1
                : a.path.count == 2 && end.y == 0 && end.x < 0 ? 2 : a.path.count == 2 && end.y == 0 && end.x > 0 ? 3 : 4
            directionPopup.selectItem(at: k)
        } else {
            directionPopup.removeAllItems()
            directionPopup.addItems(withTitles: [L("From Bottom"), L("From Top"), L("From Left"), L("From Right")])
            directionPopup.selectItem(at: dirs.firstIndex(of: a.direction) ?? 0)
        }
        setRow(directionPopup, hidden: !(a.effect == .flyIn || a.effect == .flyOut || a.effect == .wipe || a.effect == .path))
        setRow(amount, hidden: !(a.effect == .spin || a.effect == .grow))
        amount.stringValue = a.effect == .spin ? "\(Int(a.amount))" : "\(Int((a.amount * 100).rounded()))"
        (amount.superview?.subviews.last as? NSTextField)?.stringValue = a.effect == .spin ? "°" : "%"
        setRow(colorButton, hidden: a.effect != .colorChange)
        colorButton.color = (a.color ?? PColor(scheme: "accent2")).resolved(owner.deck.theme)
    }

    private func setRow(_ v: NSView, hidden: Bool) {
        guard let st = v.superview, let cell = details.cell(for: st) else { return }
        cell.row?.isHidden = hidden
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { anims.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = anims[row]
        // Click number of the row's group.
        var click = 0
        for k in 0...row where anims[k].trigger == .onClick { click += 1 }
        let name = owner?.currentSlide?.object(a.target).map { $0.name.isEmpty ? L("Object %d", $0.id) : $0.name } ?? "?"
        let mark = a.trigger == .onClick ? "\(click)" : a.trigger == .withPrevious ? "  ⇉" : "  ⇢"
        let t = NSTextField(labelWithString: "\(mark)  \(a.effect.name) — \(name)")
        t.lineBreakMode = .byTruncatingTail
        t.font = .systemFont(ofSize: 12)
        let colors: [AnimClass: NSColor] = [.entrance: .systemGreen, .exit: .systemRed, .emphasis: .systemYellow, .motion: .systemBlue]
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = colors[a.effect.cls]?.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let st = NSStackView(views: [dot, t])
        st.spacing = 6
        return st
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        let r = table.selectedRow
        selected = anims.indices.contains(r) ? anims[r].id : nil
        if let a = selected.flatMap({ id in anims.first { $0.id == id } }), owner?.selection != [a.target] { owner?.selection = [a.target] }
        reload()
        owner?.canvas.needsDisplay = true
    }

    // MARK: Actions

    @objc private func addEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = AnimEffect(rawValue: raw) else { return }
        owner?.addAnimation(e)
    }

    @objc private func remove() { if let id = selected { owner?.removeAnimation(id); selected = nil } }
    @objc private func up() { if let id = selected { owner?.moveAnimation(id, by: -1) } }
    @objc private func down() { if let id = selected { owner?.moveAnimation(id, by: 1) } }

    @objc private func detailsChanged() {
        guard !updating, let owner, let id = selected, let cur = anims.first(where: { $0.id == id }) else { return }
        let e = AnimEffect.allCases[max(0, effectPopup.indexOfSelectedItem)]
        let trig = AnimTrigger.allCases[max(0, triggerPopup.indexOfSelectedItem)]
        let dur = max(0.001, Double(duration.stringValue.replacingOccurrences(of: ",", with: ".")) ?? cur.duration)
        let del = max(0, Double(delay.stringValue.replacingOccurrences(of: ",", with: ".")) ?? cur.delay)
        let k = directionPopup.indexOfSelectedItem
        let amt = Double(amount.stringValue.replacingOccurrences(of: ",", with: "."))
        let col = colorButton.color.map { PColor($0) }
        owner.changeAnimation(id, L("Animation")) { a in
            if a.effect != e {
                // A new kind of effect starts from its own defaults.
                var n = Animation(target: a.target, effect: e, trigger: trig)
                n.id = a.id
                n.delay = del
                a = n
                return
            }
            a.trigger = trig
            a.duration = dur
            a.delay = del
            if e == .path {
                if k < 4 { a.path = Animation.linePath(["b", "t", "l", "r"][k]) }
            } else if k >= 0 {
                a.direction = ["b", "t", "l", "r"][min(3, k)]
            }
            if let amt { a.amount = e == .spin ? amt : max(0.05, amt / 100) }
            if e == .colorChange, let col { a.color = col }
        }
    }
}

/// Canvas overlay while the Animation tab is shown: order numbers and motion paths.
enum AnimationMarkers {
    static func draw(_ slide: Slide, deck: Deck, selected: UUID?, in ctx: CGContext, toView: (CGPoint) -> CGPoint) {
        var click = 0
        var badges: [Int: [String]] = [:]
        for a in slide.animations {
            if a.trigger == .onClick { click += 1 }
            badges[a.target, default: []].append("\(max(1, click))")
            guard a.effect == .path, a.path.count > 1, let o = slide.object(a.target) else { continue }
            let c = CGPoint(x: o.frame.midX, y: o.frame.midY)
            let pts = a.path.map { toView(CGPoint(x: c.x + $0.x * deck.size.width, y: c.y + $0.y * deck.size.height)) }
            ctx.saveGState()
            ctx.setStrokeColor((a.id == selected ? NSColor.systemBlue : NSColor.systemGray).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addLines(between: pts)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(NSColor.systemGreen.cgColor)
            ctx.fillEllipse(in: CGRect(x: pts[0].x - 4, y: pts[0].y - 4, width: 8, height: 8))
            ctx.setFillColor(NSColor.systemRed.cgColor)
            if let l = pts.last { ctx.fillEllipse(in: CGRect(x: l.x - 4, y: l.y - 4, width: 8, height: 8)) }
            ctx.restoreGState()
        }
        for (id, nums) in badges {
            guard let o = slide.object(id) else { continue }
            let p = toView(CGPoint(x: o.frame.minX, y: o.frame.minY))
            let s = NSAttributedString(string: nums.joined(separator: ","), attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
            let sz = s.size()
            let r = CGRect(x: p.x - sz.width - 10, y: p.y, width: sz.width + 8, height: 15)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(NSColor.systemIndigo.cgColor)
            ctx.fillPath()
            s.draw(at: CGPoint(x: r.minX + 4, y: r.minY + 1))
        }
    }
}
