import AppKit
import Kit42

/// File › New from Template…: the six built-in themes (and template files).
final class TemplateGallery: NSWindowController {
    static var shared: TemplateGallery?

    static func show() {
        if shared == nil { shared = TemplateGallery() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        shared?.window?.orderFrontRegardless()
    }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("New from Template")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        if PresentationDocument.testMode { w.setFrameOrigin(NSPoint(x: 40, y: 40)) } else { w.center() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    static func preview(_ i: Int) -> NSImage {
        var d = Deck.makeDefault(theme: i)
        d.setText(slide: 0, placeholder: "ctrTitle", [Paragraph(L(Themes.all[i].theme.name))])
        d.setText(slide: 0, placeholder: "subTitle", [Paragraph(L("Presentation"))])
        return Renderer.nsImage(d.slides[0], deck: d, pixelWidth: 400)
    }

    private func build() {
        var rows: [NSView] = []
        var row: [NSView] = []
        for (i, e) in Themes.all.enumerated() {
            let img = Self.preview(i)
            img.size = NSSize(width: 200, height: 112.5)
            let b = NSButton(title: L(e.theme.name), image: img, target: self, action: #selector(pick(_:)))
            b.tag = i
            b.imagePosition = .imageAbove
            b.bezelStyle = .accessoryBarAction
            b.showsBorderOnlyWhileMouseInside = true
            b.imageScaling = .scaleNone
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 216).isActive = true
            b.heightAnchor.constraint(equalToConstant: 146).isActive = true
            b.setContentHuggingPriority(.required, for: .vertical)
            row.append(b)
            if row.count == 3 { rows.append(NSStackView(views: row)); row = [] }
        }
        if !row.isEmpty { rows.append(NSStackView(views: row)) }
        let open = NSButton(title: L("Open Template File…"), target: self, action: #selector(openFile))
        open.bezelStyle = .rounded
        let stack = NSStackView(views: rows + [open])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for r in rows { (r as? NSStackView)?.alignment = .top; r.setContentHuggingPriority(.required, for: .vertical) }
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        window?.setContentSize(root.fittingSize)
    }

    @objc private func pick(_ sender: NSButton) {
        window?.close()
        Self.newDocument(Deck.makeDefault(theme: sender.tag))
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "potx"), .init(filenameExtension: "otp"), .init(filenameExtension: "pptx"), .init(filenameExtension: "odp")].compactMap { $0 }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            do {
                let deck = try DeckIO.read(data, ext: url.pathExtension)
                self?.window?.close()
                Self.newDocument(deck)
            } catch { NSAlert(error: error).runModal() }
        }
    }

    /// A new untitled presentation with `deck`.
    static func newDocument(_ deck: Deck) {
        guard let doc = try? NSDocumentController.shared.makeUntitledDocument(ofType: "org.openxmlformats.presentationml.presentation") as? PresentationDocument else { return }
        doc.replaceDeck(deck)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
    }
}

extension AppDelegate {
    @objc func newFromTemplateAction(_ sender: Any?) { TemplateGallery.show() }
}
