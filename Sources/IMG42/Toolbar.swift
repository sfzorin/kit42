import AppKit
import Kit42

/// Main toolbar, laid out like Preview's image toolbar:
/// ‹ › · zoom − 1:1 + · Highlight ▾ · Remove Background, Rotate · Markup · Adjust · Info · Share · Search
final class ImageToolbar: NSObject, NSSharingServicePickerDelegate {
    weak var owner: ImageWindowController?
    private(set) var controller: ToolbarController!
    let highlight = NSSegmentedControl()
    let share = NSButton()

    var toolbar: NSToolbar { controller.toolbar }
    var searchField: NSSearchField? { controller.searchItem?.searchField }

    static let highlightColors: [(String, NSColor)] = [
        (L("Yellow"), .systemYellow), (L("Green"), .systemGreen), (L("Blue"), .systemBlue), (L("Pink"), .systemPink), (L("Purple"), .systemPurple),
    ]

    init(owner: ImageWindowController) {
        self.owner = owner
        super.init()

        highlight.segmentCount = 2
        highlight.trackingMode = .momentary
        highlight.setImage(NSImage(systemSymbolName: "highlighter", accessibilityDescription: L("Highlight")), forSegment: 0)
        highlight.setImage(Theme42.symbol("chevron.down", size: 9, weight: .semibold), forSegment: 1)
        highlight.setWidth(34, forSegment: 0)
        highlight.setWidth(22, forSegment: 1)
        highlight.setToolTip(L("Highlight"), forSegment: 0)
        highlight.setToolTip(L("Highlight colour"), forSegment: 1)
        highlight.target = self
        highlight.action = #selector(highlightClicked(_:))

        share.bezelStyle = .toolbar
        share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L("Share"))
        share.imagePosition = .imageOnly
        share.toolTip = L("Share")
        share.target = self
        share.action = #selector(shareClicked(_:))
        share.sendAction(on: .leftMouseDown)

        controller = ToolbarController(identifier: "IMG42.toolbar", elements: [
            .group(id: "navigate", label: L("Previous / Next"), [Cmd.previous, Cmd.next]),
            .flexibleSpace,
            .group(id: "zoom", label: L("Zoom"), [Cmd.zoomOut, Cmd.actualSize, Cmd.zoomIn]),
            .view(id: "highlight", label: L("Highlight"), highlight),
            .group(id: "image", label: L("Image"), [Cmd.removeBackground, Cmd.rotateLeft, Cmd.rotateRight]),
            .command(Cmd.markupBar),
            .command(Cmd.adjust),
            .command(Cmd.info),
            .view(id: "share", label: L("Share"), share),
            .search(id: "search", placeholder: L("Search Text"), action: #selector(ImageWindowController.searchChanged(_:))),
        ])
    }

    @objc private func highlightClicked(_ sender: NSSegmentedControl) {
        guard let owner else { return }
        if sender.selectedSegment == 0 {
            owner.highlightAction(nil)
        } else {
            let menu = NSMenu()
            for (i, (name, color)) in Self.highlightColors.enumerated() {
                let item = NSMenuItem(title: name, action: #selector(ImageWindowController.highlightAction(_:)), keyEquivalent: "")
                item.tag = i + 1
                item.target = owner
                item.image = Self.swatch(color)
                item.state = owner.highlightColor == color ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            color.setFill()
            p.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()   // visible on light and dark menus
            p.stroke()
            return true
        }
    }

    @objc private func shareClicked(_ sender: NSButton) {
        guard let items = owner?.shareItems(), !items.isEmpty else { return }
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
}
