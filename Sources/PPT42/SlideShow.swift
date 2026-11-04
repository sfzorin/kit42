import AppKit
import Kit42
import QuartzCore

/// Borderless full-screen window that takes keys.
final class ShowWindow: NSWindow {
    weak var show: SlideShowController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { if show?.handleKey(event) != true { super.keyDown(with: event) } }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        PresentationDocument.testMode ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Draws the current slide picture letterboxed on black (or a black/white screen).
final class ShowView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var blank: NSColor? { didSet { needsDisplay = true } }
    var aspect: CGFloat = 16.0 / 9
    weak var show: SlideShowController?

    override var isFlipped: Bool { true }

    var slideRect: CGRect {
        let b = bounds
        var w = b.width, h = w / aspect
        if h > b.height { h = b.height; w = h * aspect }
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        if let blank { blank.setFill(); bounds.fill(); return }
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = slideRect
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) { show?.next() }
    override func rightMouseDown(with event: NSEvent) { show?.previous() }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 2, event.phase == .began || event.phase == [] else { return }
        if event.scrollingDeltaY < 0 { show?.next() } else { show?.previous() }
    }
    override var acceptsFirstResponder: Bool { true }
}

final class SlideShowController: NSObject {
    static var current: SlideShowController?
    weak var owner: DeckWindowController?
    let deck: Deck
    /// Indexes into deck.slides that are shown.
    let order: [Int]
    private(set) var position = 0
    /// Builds already revealed on the current slide.
    private(set) var step = 0
    private var window: ShowWindow?
    private let view = ShowView()
    private var presenter: PresenterWindowController?
    private let rehearse: Bool
    private var typed = ""
    private var autoTimer: Timer?
    private var transitionLayer: CALayer?
    let startedAt = Date()
    private var savedOptions: NSApplication.PresentationOptions = []
    private var cache: [String: CGImage] = [:]
    private var pixelWidth = 1920

    init(owner: DeckWindowController, deck: Deck, start: Int, rehearse: Bool) {
        self.owner = owner
        self.deck = deck
        self.rehearse = rehearse
        let showHidden = ShowSettings.showHidden
        order = deck.slides.indices.filter { showHidden || !deck.slides[$0].hidden }
        super.init()
        position = order.firstIndex { $0 >= start } ?? 0
        view.show = self
        view.aspect = deck.size.width / deck.size.height
    }

    var slideIndex: Int { order.indices.contains(position) ? order[position] : 0 }
    var slide: Slide { deck.slides[slideIndex] }
    var builds: [SlideObject] { slide.objects.filter { $0.build != nil } }

    // MARK: - Start and end

    func start() {
        guard !order.isEmpty else { return }
        SlideShowController.current = self
        let screens = NSScreen.screens
        let main = NSScreen.main ?? screens.first!
        let test = PresentationDocument.testMode
        if !rehearse {
            let frame = test ? NSRect(x: -20000, y: -20000, width: 1280, height: 720) : main.frame
            let w = ShowWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.show = self
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.contentView = view
            view.wantsLayer = true
            if !test { w.level = .screenSaver }
            w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            window = w
            pixelWidth = Int(min(3840, frame.width * (main.backingScaleFactor)))
            w.setFrame(frame, display: false)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            if !test {
                savedOptions = NSApp.presentationOptions
                NSApp.presentationOptions = [.hideDock, .hideMenuBar]
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        // Presenter view: on the other display, or in a window when rehearsing.
        let other = screens.first { $0 != main }
        if rehearse || (ShowSettings.presenterView && other != nil) || ProcessInfo.processInfo.environment["K42_PRESENTER"] != nil {
            let p = PresenterWindowController(show: self, screen: rehearse ? nil : other, windowed: rehearse || test)
            presenter = p
            p.showWindow(nil)
            if rehearse { p.window?.makeKeyAndOrderFront(nil) }
        }
        render(animated: false)
    }

    func end() {
        autoTimer?.invalidate()
        if let w = window {
            if !PresentationDocument.testMode { NSApp.presentationOptions = savedOptions }
            w.orderOut(nil)
            w.close()
        }
        presenter?.close()
        presenter = nil
        window = nil
        if SlideShowController.current === self { SlideShowController.current = nil }
        if let owner, deck.slides.indices.contains(slideIndex), owner.deck.slides.count == deck.slides.count { owner.select(slide: slideIndex) }
        owner?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Rendering

    /// Picture of slide `i` with `revealed` builds.
    func image(slide i: Int, revealed: Int, width: Int? = nil) -> CGImage? {
        let key = "\(i):\(revealed):\(width ?? pixelWidth)"
        if let c = cache[key] { return c }
        let s = deck.slides[i]
        let pending = s.objects.filter { $0.build != nil }.dropFirst(revealed).map(\.id)
        var o = RenderOptions()
        o.hidden = Set(pending)
        o.number = Renderer.number(of: i, deck: deck)
        let img = Renderer.image(s, deck: deck, pixelWidth: width ?? pixelWidth, options: o)
        if let img { cache[key] = img }
        return img
    }

    private func render(animated: Bool, transition: Transition? = nil, build: BuildEffect? = nil, buildObject: SlideObject? = nil) {
        let old = view.image
        let new = image(slide: slideIndex, revealed: step)
        view.blank = nil
        if animated, let old, let new {
            if let build, let obj = buildObject {
                animateBuild(build, object: obj, old: old, new: new)
            } else if let t = transition, t.kind != .none {
                animateTransition(t, old: old, new: new)
            } else {
                view.image = new
            }
        } else {
            view.image = new
        }
        presenter?.update()
        scheduleAuto()
        // Warm the next picture.
        if position + 1 < order.count { DispatchQueue.main.async { [weak self] in guard let self else { return }; _ = self.image(slide: self.order[min(self.position + 1, self.order.count - 1)], revealed: 0) } }
    }

    private func overlay(_ image: CGImage) -> CALayer {
        transitionLayer?.removeFromSuperlayer()
        let l = CALayer()
        l.frame = view.slideRect
        l.contents = image
        l.contentsGravity = .resize
        l.masksToBounds = true
        view.layer?.addSublayer(l)
        transitionLayer = l
        return l
    }

    private func animateTransition(_ t: Transition, old: CGImage, new: CGImage) {
        guard view.layer != nil else { view.image = new; return }
        let l = overlay(old)
        view.image = new
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak l] in
            l?.removeFromSuperlayer()
            if self?.transitionLayer === l { self?.transitionLayer = nil }
        }
        let dur = max(0.15, min(t.duration, 3))
        switch t.kind {
        case .zoom:
            l.contents = new
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.3; scale.toValue = 1; scale.duration = dur
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = dur
            l.add(scale, forKey: "zoom"); l.add(fade, forKey: "fade")
        default:
            let tr = CATransition()
            tr.duration = dur
            tr.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let sub: CATransitionSubtype = ["l": .fromRight, "r": .fromLeft, "u": .fromBottom, "d": .fromTop][t.direction] ?? .fromRight
            switch t.kind {
            case .push: tr.type = .push; tr.subtype = sub
            case .cover: tr.type = .moveIn; tr.subtype = sub
            case .wipe:
                if let f = CIFilter(name: "CISwipeTransition") {
                    let angle: Double = ["l": .pi, "r": 0, "u": .pi / 2, "d": -.pi / 2][t.direction] ?? 0
                    f.setValue(angle, forKey: kCIInputAngleKey)
                    f.setValue(80.0, forKey: kCIInputWidthKey)
                    f.setValue(0.0, forKey: "inputOpacity")
                    tr.filter = f
                } else { tr.type = .reveal; tr.subtype = sub }
            case .dissolve:
                if let f = CIFilter(name: "CIDissolveTransition") { tr.filter = f } else { tr.type = .fade }
            case .split:
                if let f = CIFilter(name: "CIBarsSwipeTransition") { f.setValue(30.0, forKey: kCIInputWidthKey); tr.filter = f } else { tr.type = .fade }
            default: tr.type = .fade
            }
            l.add(tr, forKey: "transition")
            l.contents = new
        }
        CATransaction.commit()
    }

    private func animateBuild(_ effect: BuildEffect, object o: SlideObject, old: CGImage, new: CGImage) {
        guard effect != .appear, view.layer != nil else { view.image = new; return }
        // The object alone, animated over the previous state.
        var s = slide
        s.objects = [o]
        var opts = RenderOptions()
        opts.objectsOnly = true
        opts.number = Renderer.number(of: slideIndex, deck: deck)
        guard let objImage = Renderer.image(s, deck: deck, pixelWidth: pixelWidth, options: opts, opaque: false) else { view.image = new; return }
        let base = overlay(old)
        let objLayer = CALayer()
        objLayer.frame = base.bounds
        objLayer.contents = objImage
        objLayer.contentsGravity = .resize
        base.addSublayer(objLayer)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak base] in
            self?.view.image = new
            base?.removeFromSuperlayer()
            if self?.transitionLayer === base { self?.transitionLayer = nil }
        }
        let dur = 0.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = dur
        objLayer.add(fade, forKey: "fade")
        if effect == .flyIn {
            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = objLayer.position.y - base.bounds.height
            move.toValue = objLayer.position.y
            move.duration = dur
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            objLayer.add(move, forKey: "fly")
        } else if effect == .zoom {
            let r = Renderer.number(of: 0, deck: deck) >= 0 ? o.frame : .zero
            let sx = base.bounds.width / deck.size.width
            objLayer.anchorPoint = CGPoint(x: r.midX / deck.size.width, y: 1 - r.midY / deck.size.height)
            objLayer.frame = base.bounds
            _ = sx
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.2; scale.toValue = 1; scale.duration = dur
            objLayer.add(scale, forKey: "zoom")
        }
        CATransaction.commit()
    }

    private func scheduleAuto() {
        autoTimer?.invalidate()
        guard let t = slide.transition.advanceAfter, step >= builds.count else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, t), repeats: false) { [weak self] _ in self?.next() }
    }

    // MARK: - Navigation

    func next() {
        if view.blank != nil { view.blank = nil; return }
        if step < builds.count {
            let o = builds[step]
            step += 1
            render(animated: true, build: o.build, buildObject: o)
            return
        }
        guard position + 1 < order.count else {
            if ShowSettings.loop { go(to: 0) } else if !rehearse { end() }
            return
        }
        position += 1
        step = 0
        render(animated: true, transition: slide.transition)
    }

    func previous() {
        if view.blank != nil { view.blank = nil; return }
        if step > 0 { step -= 1; render(animated: false); return }
        guard position > 0 else { return }
        position -= 1
        step = builds.count
        render(animated: false)
    }

    func go(to p: Int) {
        position = min(max(0, p), order.count - 1)
        step = 0
        render(animated: true, transition: slide.transition)
    }

    /// Jump to slide number `n` (as numbered in the deck).
    func jump(toNumber n: Int) {
        let target = n - deck.firstSlideNumber
        if let p = order.firstIndex(where: { $0 >= target }) { go(to: p) }
    }

    func toggleBlank(_ c: NSColor) {
        view.blank = view.blank == nil ? c : nil
        presenter?.update()
    }

    var isBlank: Bool { view.blank != nil }

    /// Keys of the show and presenter windows.
    func handleKey(_ e: NSEvent) -> Bool {
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let c = chars.first, c.isNumber, chars.count == 1 { typed.append(c); return true }
        guard let scalar = chars.unicodeScalars.first else { return false }
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey, NSDownArrowFunctionKey, NSPageDownFunctionKey, 32: next()
        case 13, 3:
            if let n = Int(typed) { jump(toNumber: n) } else { next() }
            typed = ""
        case NSLeftArrowFunctionKey, NSUpArrowFunctionKey, NSPageUpFunctionKey, NSDeleteCharacter, NSBackspaceCharacter: previous()
        case NSHomeFunctionKey: go(to: 0)
        case NSEndFunctionKey: go(to: order.count - 1)
        case 27:
            if !typed.isEmpty { typed = "" } else { end() }
        default:
            switch chars {
            case "n": next()
            case "p": previous()
            case "b", ".": toggleBlank(.black)
            case "w", ",": toggleBlank(.white)
            case "q": end()
            default: return false
            }
        }
        return true
    }
}

// MARK: - Presenter view

/// Current and next slide, notes, timer and clock (second display, or a window when rehearsing).
final class PresenterWindowController: NSWindowController, NSWindowDelegate {
    weak var show: SlideShowController?
    private let currentView = ShowView()
    private let nextView = ShowView()
    private let notes = NSTextView()
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let clockLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let nextLabel = NSTextField(labelWithString: L("Next"))
    private var timer: Timer?

    init(show: SlideShowController, screen: NSScreen?, windowed: Bool) {
        self.show = show
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 760)
        let w: NSWindow
        if windowed {
            w = ShowWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L("Presenter View")
            if PresentationDocument.testMode { w.setFrameOrigin(NSPoint(x: -20000, y: -20000)) } else { w.center() }
        } else {
            w = ShowWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.setFrame(frame, display: false)
        }
        (w as? ShowWindow)?.show = show
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(white: 0.08, alpha: 1)
        super.init(window: w)
        w.delegate = self
        build()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        guard let w = window else { return }
        let root = NSView()
        currentView.show = show
        nextView.show = show
        for v in [currentView, nextView] { v.aspect = show.map { $0.deck.size.width / $0.deck.size.height } ?? 16 / 9 }
        for l in [timerLabel, clockLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 30, weight: .medium)
            l.textColor = .white
        }
        positionLabel.font = .systemFont(ofSize: 16, weight: .medium)
        positionLabel.textColor = NSColor(white: 0.75, alpha: 1)
        nextLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nextLabel.textColor = NSColor(white: 0.6, alpha: 1)
        notes.isEditable = false
        notes.drawsBackground = false
        notes.textColor = .white
        notes.font = NSFont(name: "Helvetica Neue", size: 22) ?? .systemFont(ofSize: 22)
        let notesScroll = NSScrollView()
        notesScroll.documentView = notes
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notes.autoresizingMask = [.width]
        notes.isVerticallyResizable = true
        notes.textContainer?.widthTracksTextView = true
        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
            b.bezelStyle = .rounded
            b.imagePosition = .imageLeading
            return b
        }
        let buttons = NSStackView(views: [button(L("Previous"), "chevron.left", #selector(prev)), button(L("Next"), "chevron.right", #selector(nextSlide)),
                                          button(L("Black Screen"), "moon", #selector(black)), button(L("End Show"), "xmark", #selector(endShow))])
        buttons.spacing = 8
        let top = NSStackView(views: [timerLabel, positionLabel, NSView(), clockLabel])
        top.spacing = 18
        let right = NSStackView(views: [nextLabel, nextView, notesScroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        for v in [top, currentView, right, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24), top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            currentView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            currentView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 16),
            currentView.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.6, constant: -36),
            currentView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            right.leadingAnchor.constraint(equalTo: currentView.trailingAnchor, constant: 24),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            right.topAnchor.constraint(equalTo: currentView.topAnchor),
            right.bottomAnchor.constraint(equalTo: currentView.bottomAnchor),
            nextView.widthAnchor.constraint(equalTo: right.widthAnchor),
            nextView.heightAnchor.constraint(equalTo: nextView.widthAnchor, multiplier: 1 / (show.map { $0.deck.size.width / $0.deck.size.height } ?? 16 / 9)),
            notesScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        w.contentView = root
        w.makeFirstResponder(currentView)
    }

    func update() {
        guard let show else { return }
        let width = 1400
        currentView.image = show.image(slide: show.slideIndex, revealed: show.step, width: width)
        currentView.blank = show.isBlank ? .black : nil
        if show.step < show.builds.count {
            nextView.image = show.image(slide: show.slideIndex, revealed: show.step + 1, width: 900)
            nextLabel.stringValue = L("Next: build")
        } else if show.position + 1 < show.order.count {
            nextView.image = show.image(slide: show.order[show.position + 1], revealed: 0, width: 900)
            nextLabel.stringValue = L("Next")
        } else {
            nextView.image = nil
            nextLabel.stringValue = L("End of show")
        }
        notes.string = show.slide.notes.isEmpty ? L("No notes") : show.slide.notes
        notes.textColor = show.slide.notes.isEmpty ? NSColor(white: 0.5, alpha: 1) : .white
        positionLabel.stringValue = L("Slide %d of %d", show.position + 1, show.order.count)
    }

    private func tick() {
        guard let show else { return }
        let t = Int(Date().timeIntervalSince(show.startedAt))
        timerLabel.stringValue = String(format: t >= 3600 ? "%d:%02d:%02d" : "%02d:%02d", t >= 3600 ? t / 3600 : t / 60 % 60, t >= 3600 ? t / 60 % 60 : t % 60, t % 60)
        let f = DateFormatter()
        f.timeStyle = .short
        clockLabel.stringValue = f.string(from: Date())
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        if SlideShowController.current === show { DispatchQueue.main.async { [weak show] in show?.end() } }
    }

    override func close() {
        timer?.invalidate()
        super.close()
    }

    @objc private func prev() { show?.previous() }
    @objc private func nextSlide() { show?.next() }
    @objc private func black() { show?.toggleBlank(.black) }
    @objc private func endShow() { show?.end() }
}
