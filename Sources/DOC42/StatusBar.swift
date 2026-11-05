import AppKit
import Kit42
import NaturalLanguage

/// Bottom bar: words (of the selection), language, view layout, zoom slider.
/// The page position is the window subtitle (DocWindowController.updateStatus), so it is not repeated here.
final class DocStatusBar: NSView {
    static let height: CGFloat = 24
    let words = NSTextField(labelWithString: "")
    let language = NSTextField(labelWithString: "")
    let layout = NSSegmentedControl()
    let zoom = NSSlider(value: 100, minValue: 25, maxValue: 300, target: nil, action: nil)
    let zoomLabel = NSTextField(labelWithString: "100%")
    var onZoom: ((CGFloat) -> Void)?
    var onLayout: ((PagedView.ViewMode) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [words, language, zoomLabel] {
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            f.lineBreakMode = .byTruncatingTail
        }
        words.toolTip = L("Word count")
        language.toolTip = L("Language")
        layout.segmentCount = 4
        let symbols = ["doc", "book", "square.grid.2x2", "globe"]
        let tips = [L("Single Page"), L("Book View (Two Pages)"), L("Multiple Pages"), L("Web Layout")]
        for i in 0..<4 {
            layout.setImage(Theme42.symbol(symbols[i], size: 11), forSegment: i)
            layout.setToolTip(tips[i], forSegment: i)
            layout.setWidth(26, forSegment: i)
        }
        layout.trackingMode = .selectOne
        layout.selectedSegment = 0
        layout.controlSize = .mini
        layout.segmentStyle = .texturedRounded
        layout.target = self
        layout.action = #selector(layoutChanged(_:))
        zoom.controlSize = .mini
        zoom.target = self
        zoom.action = #selector(zoomChanged(_:))
        zoom.toolTip = L("Zoom")
        zoomLabel.alignment = .right
        let left = NSStackView(views: [words, language])
        left.spacing = 18
        let right = NSStackView(views: [layout, zoom, zoomLabel])
        right.spacing = 8
        for v in [left, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            zoom.widthAnchor.constraint(equalToConstant: 110),
            zoomLabel.widthAnchor.constraint(equalToConstant: 38),
        ])
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { false }

    func setZoom(_ z: CGFloat) {
        zoom.doubleValue = Double(z * 100)
        zoomLabel.stringValue = "\(Int((z * 100).rounded()))%"
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        let z = CGFloat(sender.doubleValue / 100)
        zoomLabel.stringValue = "\(Int((z * 100).rounded()))%"
        onZoom?(z)
    }

    @objc private func layoutChanged(_ sender: NSSegmentedControl) {
        onLayout?(PagedView.ViewMode(rawValue: sender.selectedSegment) ?? .single)
    }

    /// Dominant language of a text sample, in the interface language.
    static func languageName(_ text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(4000)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return "" }
        return Locale.current.localizedString(forLanguageCode: lang.rawValue)?.capitalized ?? lang.rawValue
    }
}

extension DocWindowController {
    func updateStatusBar() {
        updateStatus()
        guard !statusBar.isHidden, let storage = textView.textStorage else { return }
        let sel = textView.selectedRange()
        let all = TextStats.of(storage, NSRange(location: 0, length: storage.length), layout: nil)
        if sel.length > 0 {
            let part = TextStats.of(storage, sel, layout: nil)
            statusBar.words.stringValue = L("%d of %d words, %d characters", part.words, all.words, part.characters)
        } else {
            statusBar.words.stringValue = L("%d words, %d characters", all.words, all.characters)
        }
        if languageKey != storage.length / 500 {
            languageKey = storage.length / 500
            statusBar.language.stringValue = DocStatusBar.languageName(storage.string)
        }
        statusBar.setZoom(scroller.magnification)
        statusBar.layout.selectedSegment = paged.viewMode.rawValue
    }

    @objc func toggleStatusBarAction(_ sender: Any?) {
        setStatusBar(shown: statusBar.isHidden)
        UserDefaults.standard.set(!statusBar.isHidden, forKey: "doc.statusBar")
    }

    func setStatusBar(shown: Bool) {
        statusBar.isHidden = !shown
        statusHeight?.constant = shown ? DocStatusBar.height : 0
        if shown { updateStatusBar() }
    }

    @objc func viewModeAction(_ sender: Any?) {
        setViewMode(PagedView.ViewMode(rawValue: commandTag(of: sender)) ?? .single)
    }

    func setViewMode(_ m: PagedView.ViewMode) {
        if paged.viewMode != m { headerEditor?.commit() }
        paged.viewMode = m
        if m == .multi, scroller.magnification > 0.6 { scroller.magnification = 0.5 }
        if m == .book, scroller.magnification > 0.8 { scroller.magnification = 0.7 }
        if m == .single || m == .web { scroller.magnification = max(scroller.magnification, 1) }
        syncRulerSetup()
        updateStatusBar()
    }
}
