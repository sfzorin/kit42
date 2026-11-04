import AppKit
import Kit42
import PDFKit

/// Sidebar: page thumbnails or the document outline.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Mode: Int { case thumbnails, outline }

    let thumbnails = PDFThumbnailView()
    private let pdfView: PDFView
    private let switcher = NSSegmentedControl(labels: [L("Thumbnails"), L("Contents")], trackingMode: .selectOne, target: nil, action: nil)
    private let outlineView = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: L("This document has no table of contents"))

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var mode: Mode = .thumbnails {
        didSet {
            switcher.selectedSegment = mode.rawValue
            thumbnails.isHidden = mode != .thumbnails
            outlineScroll.isHidden = mode != .outline
            if mode == .outline { reloadOutline() }
            emptyLabel.isHidden = mode != .outline || pdfView.document?.outlineRoot?.numberOfChildren ?? 0 > 0
        }
    }

    override func loadView() {
        let root = NSView()

        switcher.target = self
        switcher.action = #selector(switched(_:))
        switcher.controlSize = .small
        switcher.segmentDistribution = .fillEqually

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 104, height: 136)
        thumbnails.allowsMultipleSelection = true
        thumbnails.backgroundColor = .clear

        let column = NSTableColumn(identifier: .init("title"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)
        outlineScroll.documentView = outlineView
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true

        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center

        for v in [switcher, thumbnails, outlineScroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            switcher.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 40),
        ])
        for v in [thumbnails, outlineScroll] as [NSView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8),
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        mode = .thumbnails
    }

    @objc private func switched(_ sender: NSSegmentedControl) {
        mode = Mode(rawValue: sender.selectedSegment) ?? .thumbnails
    }

    func reloadOutline() {
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: false)
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? pdfView.document?.outlineRoot)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? pdfView.document?.outlineRoot)!.child(at: index)!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PDFOutline)?.numberOfChildren ?? 0 > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: (item as? PDFOutline)?.label ?? "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func outlineClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? PDFOutline else { return }
        if let dest = item.destination { pdfView.go(to: dest) }
        else if let action = item.action as? PDFActionGoTo { pdfView.go(to: action.destination) }
    }
}
