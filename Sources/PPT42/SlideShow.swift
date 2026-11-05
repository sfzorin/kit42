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

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = slideRect
        if let show, r.width > 0 {
            let q = CGPoint(x: (p.x - r.minX) / r.width * show.deck.size.width, y: (p.y - r.minY) / r.height * show.deck.size.height)
            if show.clickMedia(at: q) { return }
        }
        show?.next()
    }
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
    private var navigationGeneration = 0
    private var transitionLayer: CALayer?
    let startedAt = Date()
    private var savedOptions: NSApplication.PresentationOptions = []
    private var cache: [String: CGImage] = [:]
    private var pixelWidth = 1920
    let media = ShowMedia()
    private var mediaSlide: Int?

    /// Present in a window instead of full screen.
    let windowed: Bool
    let overlay = ShowOverlay()
    private var ink: [Int: [[CGPoint]]] = [:]
    private var overview: ShowOverview?
    private var cursorHidden = false

    init(owner: DeckWindowController, deck: Deck, start: Int, rehearse: Bool, windowed: Bool = false) {
        self.owner = owner
        self.deck = deck
        self.rehearse = rehearse
        self.windowed = windowed
        let showHidden = ShowSettings.showHidden
        order = deck.slides.indices.filter { showHidden || !deck.slides[$0].hidden }
        super.init()
        position = order.firstIndex { $0 >= start } ?? 0
        view.show = self
        view.aspect = deck.size.width / deck.size.height
    }

    var slideIndex: Int { order.indices.contains(position) ? order[position] : 0 }
    var slide: Slide { deck.slides[slideIndex] }
    /// Animation groups of the current slide (one per click; the first may play by itself).
    var timeline: AnimationTimeline { AnimationTimeline(slide.animations.filter { a in slide.object(a.target) != nil }) }
    var groupCount: Int { timeline.groups.count }

    // MARK: - Start and end

    func start() {
        guard !order.isEmpty else { return }
        SlideShowController.current = self
        let screens = NSScreen.screens
        let main = NSScreen.main ?? screens.first!
        let test = PresentationDocument.testMode
        if !rehearse {
            var frame = test ? NSRect(x: -20000, y: -20000, width: 1280, height: 720) : main.frame
            if windowed && !test {
                let vf = main.visibleFrame
                let w = min(vf.width * 0.8, 1280), h = w * deck.size.height / deck.size.width
                frame = NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
            }
            let w = ShowWindow(contentRect: frame, styleMask: windowed ? [.titled, .closable, .resizable, .miniaturizable] : [.borderless], backing: .buffered, defer: false)
            w.show = self
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.contentView = view
            view.wantsLayer = true
            overlay.show = self
            overlay.frame = view.bounds
            overlay.autoresizingMask = [.width, .height]
            view.addSubview(overlay)
            if windowed { w.title = L("Slide Show"); w.delegate = self }
            if !test && !windowed { w.level = .screenSaver }
            w.collectionBehavior = windowed ? [] : [.fullScreenAuxiliary, .canJoinAllSpaces]
            window = w
            pixelWidth = Int(min(3840, frame.width * (main.backingScaleFactor)))
            w.setFrame(frame, display: false)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            if !test && !windowed {
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
        playAutomaticGroup()
    }

    func end() {
        navigationGeneration += 1
        autoTimer?.invalidate()
        media.clear()
        MediaFiles.cleanUp()
        if let w = window {
            if !PresentationDocument.testMode && !windowed { NSApp.presentationOptions = savedOptions }
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
            if overlay.tool == .laser { overlay.tool = .none }
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

    /// Picture of slide `i` after `revealed` animation groups.
    func image(slide i: Int, revealed: Int, width: Int? = nil, hidden: Set<Int> = []) -> CGImage? {
        let key = "\(i):\(revealed):\(width ?? pixelWidth):\(hidden.sorted())"
        if let c = cache[key] { return c }
        let s = deck.slides[i].animated(after: revealed, size: deck.size)
        var o = RenderOptions()
        o.hidden = hidden
        o.number = Renderer.number(of: i, deck: deck)
        let img = Renderer.image(s, deck: deck, pixelWidth: width ?? pixelWidth, options: o)
        if let img { cache[key] = img }
        return img
    }

    private func render(animated: Bool, transition: Transition? = nil, group: Int? = nil) {
        let old = view.image
        if let group, animated, view.layer != nil {
            animateGroup(group)
        } else {
            let new = image(slide: slideIndex, revealed: step)
            view.blank = nil
            if animated, let old, let new, let t = transition, t.kind != .none { animateTransition(t, old: old, new: new) } else { view.image = new }
        }
        presenter?.update()
        scheduleAuto()
        overlay.strokes = ink[slideIndex] ?? []
        if mediaSlide != slideIndex, window != nil {
            mediaSlide = slideIndex
            media.load(slide, deck: deck)
            media.attach(to: view, slideRect: view.slideRect, slideSize: deck.size)
            media.startAutoplay()
        }
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

    /// Plays animation group `k` (step k → k + 1) with Core Animation over the slide without the animated objects.
    private func animateGroup(_ k: Int) {
        if ProcessInfo.processInfo.environment["K42_DEBUG"] != nil { print("animate group", k, "of", timeline.groups.count, timeline.groups.map { $0.items.map { $0.anim.effect.rawValue } }) }
        let tl = timeline
        guard tl.groups.indices.contains(k) else { view.image = image(slide: slideIndex, revealed: step); return }
        let g = tl.groups[k]
        let ids = Set(g.items.map { $0.anim.target })
        let from = slide.animated(after: k, size: deck.size), to = slide.animated(after: k + 1, size: deck.size)
        guard let baseImage = image(slide: slideIndex, revealed: k + 1, hidden: ids) else { return }
        let final = image(slide: slideIndex, revealed: k + 1)
        view.blank = nil
        let base = overlay(baseImage)
        view.image = final
        let flipped = base.contentsAreFlipped() == false
        let scale = base.bounds.width / deck.size.width
        func objectImage(_ s: Slide, _ id: Int) -> CGImage? {
            guard let o = s.object(id) else { return nil }
            var one = s
            one.objects = [o]
            var opts = RenderOptions()
            opts.objectsOnly = true
            opts.number = Renderer.number(of: slideIndex, deck: deck)
            return Renderer.image(one, deck: deck, pixelWidth: pixelWidth, options: opts, opaque: false)
        }
        func layer(_ img: CGImage, centre: CGPoint) -> CALayer {
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resize
            l.anchorPoint = CGPoint(x: centre.x / deck.size.width, y: flipped ? centre.y / deck.size.height : 1 - centre.y / deck.size.height)
            l.frame = base.bounds
            base.addSublayer(l)
            return l
        }
        // Slide y offsets in layer units (the layer tree may be flipped).
        func dy(_ v: CGFloat) -> CGFloat { (flipped ? v : -v) * scale }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak base] in
            base?.removeFromSuperlayer()
            if self?.transitionLayer === base { self?.transitionLayer = nil }
        }
        for it in g.items {
            let a = it.anim
            let state = a.effect.cls == .entrance ? to : from
            guard let o = state.object(a.target), let img = objectImage(state, a.target) else { continue }
            let c = CGPoint(x: o.frame.midX, y: o.frame.midY)
            let l = layer(img, centre: c)
            let begin = now + it.start + a.delay
            let dur = max(0.001, a.duration)
            func add(_ anim: CAAnimation, _ key: String, hold: Bool = true) {
                anim.beginTime = begin
                anim.duration = anim.duration > 0 ? anim.duration : dur
                anim.fillMode = .both
                anim.isRemovedOnCompletion = false
                l.add(anim, forKey: key)
            }
            func basic(_ path: String, _ f: Any, _ t: Any, timing: CAMediaTimingFunctionName = .easeInEaseOut) -> CABasicAnimation {
                let b = CABasicAnimation(keyPath: path)
                b.fromValue = f; b.toValue = t
                b.timingFunction = CAMediaTimingFunction(name: timing)
                return b
            }
            // Off-slide offset for flying in/out.
            let off: (CGFloat, CGFloat) = {
                switch a.direction {
                case "t": return (0, -(o.frame.maxY + 4))
                case "l": return (-(o.frame.maxX + 4), 0)
                case "r": return (deck.size.width - o.frame.minX + 4, 0)
                default: return (0, deck.size.height - o.frame.minY + 4)
                }
            }()
            switch a.effect {
            case .appear: add(basic("opacity", 0, 1), "o")
            case .fade, .wipe: add(basic("opacity", 0, 1), "o")
            case .flyIn:
                add(basic("transform.translation.x", off.0 * scale, 0, timing: .easeOut), "x")
                add(basic("transform.translation.y", dy(off.1), 0, timing: .easeOut), "y")
            case .zoom:
                add(basic("transform.scale", 0.05, 1), "s")
                add(basic("opacity", 0, 1), "o")
            case .disappear: add(basic("opacity", 1, 0), "o")
            case .fadeOut: add(basic("opacity", 1, 0), "o")
            case .flyOut:
                add(basic("transform.translation.x", 0, off.0 * scale, timing: .easeIn), "x")
                add(basic("transform.translation.y", 0, dy(off.1), timing: .easeIn), "y")
            case .zoomOut:
                add(basic("transform.scale", 1, 0.05), "s")
                add(basic("opacity", 1, 0), "o")
            case .pulse:
                let p = basic("transform.scale", 1, 1.05)
                p.duration = dur / 2
                p.autoreverses = true
                add(p, "s")
            case .spin:
                add(basic("transform.rotation.z", 0, (flipped ? 1 : -1) * CGFloat(a.amount) * .pi / 180), "r")
            case .grow: add(basic("transform.scale", 1, CGFloat(a.amount)), "s")
            case .colorChange:
                add(basic("opacity", 1, 0), "o")
                if let img2 = objectImage(to, a.target) {
                    let l2 = layer(img2, centre: c)
                    let f = basic("opacity", 0, 1)
                    f.beginTime = begin; f.duration = dur; f.fillMode = .both; f.isRemovedOnCompletion = false
                    l2.add(f, forKey: "o")
                }
            case .path:
                let xs = CAKeyframeAnimation(keyPath: "transform.translation.x")
                xs.values = a.path.map { $0.x * deck.size.width * scale }
                let ys = CAKeyframeAnimation(keyPath: "transform.translation.y")
                ys.values = a.path.map { dy($0.y * deck.size.height) }
                add(xs, "x"); add(ys, "y")
            }
        }
        CATransaction.commit()
    }

    private func scheduleAuto() {
        autoTimer?.invalidate()
        guard let t = slide.transition.advanceAfter, step >= groupCount else { return }
        autoTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, t + (timeline.groups.last?.duration ?? 0)), repeats: false) { [weak self] _ in self?.next() }
    }

    /// The first group plays by itself when it starts with "with/after previous".
    private func playAutomaticGroup() {
        guard step == 0, timeline.groups.first?.automatic == true else { return }
        step = 1
        render(animated: true, group: 0)
    }

    // MARK: - Navigation

    func next() {
        guard !order.isEmpty else { return }
        if view.blank != nil { view.blank = nil; return }
        if step < groupCount {
            step += 1
            render(animated: true, group: step - 1)
            return
        }
        guard position + 1 < order.count else {
            if ShowSettings.loop { go(to: 0) } else if !rehearse { end() }
            return
        }
        position += 1
        navigationGeneration += 1
        step = 0
        render(animated: true, transition: slide.transition)
        let delay = slide.transition.kind == .none ? 0 : slide.transition.duration
        let generation = navigationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.navigationGeneration == generation else { return }
            self.playAutomaticGroup()
        }
    }

    func previous() {
        guard !order.isEmpty else { return }
        navigationGeneration += 1
        if view.blank != nil { view.blank = nil; return }
        let first = timeline.groups.first?.automatic == true ? 1 : 0
        if step > first { step -= 1; render(animated: false); return }
        guard position > 0 else { return }
        position -= 1
        step = groupCount
        render(animated: false)
    }

    func go(to p: Int) {
        guard !order.isEmpty else { return }
        navigationGeneration += 1
        position = min(max(0, p), order.count - 1)
        step = 0
        render(animated: true, transition: slide.transition)
        playAutomaticGroup()
    }

    /// Jump to slide number `n` (as numbered in the deck).
    func jump(toNumber n: Int) {
        let target = n - deck.firstSlideNumber
        if let p = order.firstIndex(where: { $0 >= target }) { go(to: p) }
    }

    func saveInk(_ strokes: [[CGPoint]]) { ink[slideIndex] = strokes }

    func setTool(_ t: ShowTool) {
        overlay.tool = overlay.tool == t ? .none : t
        window?.makeFirstResponder(view)
    }

    func openOverview() {
        guard overview == nil, window != nil else { return }
        let o = ShowOverview()
        o.show = self
        o.images = order.compactMap { image(slide: $0, revealed: 0, width: 480) }
        o.selected = position
        o.frame = view.bounds
        o.autoresizingMask = [.width, .height]
        view.addSubview(o)
        window?.makeFirstResponder(o)
        overview = o
    }

    func closeOverview(go p: Int?) {
        overview?.removeFromSuperview()
        overview = nil
        window?.makeFirstResponder(view)
        if let p { go(to: p) }
    }

    func toggleCursor() {
        cursorHidden.toggle()
        if cursorHidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    /// A click on a video or audio clip plays or pauses it.
    func clickMedia(at p: CGPoint) -> Bool { media.toggle(at: p) }

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
            if overview != nil { closeOverview(go: nil) }
            else if overlay.tool != .none { overlay.tool = .none }
            else if !typed.isEmpty { typed = "" } else { end() }
        default:
            switch chars {
            case "n": next()
            case "l": setTool(.laser)
            case "p": setTool(.pen)
            case "e": overlay.strokes = []; saveInk([])
            case "g": openOverview()
            case "c": toggleCursor()
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
        if show.step < show.groupCount {
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
