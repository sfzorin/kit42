import AppKit
import Kit42
import PDFKit
import UniformTypeIdentifiers

/// Page thumbnails with multi-selection, drag-to-reorder and drop of PDF/image files.
final class ThumbnailGrid: NSScrollView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    weak var pdfView: PDFView?
    /// Called to move pages (indices) before `to`, and to insert files at an index.
    var onMove: (([Int], Int) -> Void)?
    var onDropFiles: (([URL], Int) -> Void)?

    private let collection = NSCollectionView()
    private var cache: [ObjectIdentifier: NSImage] = [:]
    private static let pageType = NSPasteboard.PasteboardType("com.sfzorin.pdf42.page-index")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 130, height: 168)
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 12, right: 6)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.id)
        collection.registerForDraggedTypes([Self.pageType, .fileURL])
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        documentView = collection
        hasVerticalScroller = true
        drawsBackground = false
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var selectedPages: [PDFPage] {
        guard let doc = pdfView?.document else { return [] }
        return collection.selectionIndexPaths.map(\.item).sorted().compactMap { doc.page(at: $0) }
    }

    func reload() {
        cache.removeAll()
        collection.reloadData()
        pageChanged()
    }

    /// Re-render one page (after annotations changed).
    func refresh(_ page: PDFPage) {
        cache[ObjectIdentifier(page)] = nil
        if let i = pdfView?.document?.index(for: page), i != NSNotFound { collection.reloadItems(at: [IndexPath(item: i, section: 0)]) }
    }

    @objc private func pageChanged(_ note: Notification? = nil) {
        if let note, note.object as? PDFView !== pdfView { return }
        guard let doc = pdfView?.document, let page = pdfView?.currentPage else { return }
        let i = doc.index(for: page)
        guard i != NSNotFound, i < collection.numberOfItems(inSection: 0) else { return }
        let path = IndexPath(item: i, section: 0)
        if collection.selectionIndexPaths.count <= 1, !collection.selectionIndexPaths.contains(path) {
            collection.selectionIndexPaths = [path]
            collection.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
        }
    }

    private func image(for page: PDFPage) -> NSImage {
        if let i = cache[ObjectIdentifier(page)] { return i }
        let i = page.thumbnail(of: NSSize(width: 220, height: 280), for: .cropBox)
        cache[ObjectIdentifier(page)] = i
        return i
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        pdfView?.document?.pageCount ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.id, for: indexPath) as! ThumbnailItem
        if let page = pdfView?.document?.page(at: indexPath.item) {
            item.configure(image: image(for: page), number: indexPath.item + 1)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard collectionView.selectionIndexPaths.count == 1, let i = indexPaths.first?.item, let page = pdfView?.document?.page(at: i) else { return }
        pdfView?.go(to: page)
    }

    // MARK: Drag & drop

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(indexPath.item)", forType: Self.pageType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        dropOperation.pointee = .before
        return info.draggingSource as? NSCollectionView === collection ? .move : .copy
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let target = indexPath.item
        if info.draggingSource as? NSCollectionView === collection {
            let indices = collection.selectionIndexPaths.map(\.item).sorted()
            let dragged = indices.isEmpty ? (info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: Self.pageType).flatMap(Int.init) } ?? []) : indices
            onMove?(dragged, target)
            return true
        }
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls, target)
        return true
    }
}

final class ThumbnailItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ThumbnailItem")
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.shadowOpacity = 0.25
        picture.layer?.shadowRadius = 2
        picture.layer?.shadowOffset = CGSize(width: 0, height: -1)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11, weight: .medium)
        for s in [picture, label] as [NSView] {
            s.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(s)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            picture.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            picture.widthAnchor.constraint(equalToConstant: 110),
            picture.heightAnchor.constraint(equalToConstant: 136),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
        ])
        view = v
    }

    func configure(image: NSImage, number: Int) {
        picture.image = image
        label.stringValue = "\(number)"
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : nil
            view.layer?.cornerRadius = 8
            label.textColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        }
    }
}
