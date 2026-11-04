import AppKit

/// Thumbnail strip of the current folder at the bottom of the window.
final class Filmstrip: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let height: CGFloat = 92
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private let queue = OperationQueue()
    var urls: [URL] = [] { didSet { collection.reloadData() } }
    var current = -1 { didSet { updateSelection() } }
    var onSelect: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 76, height: 68)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(ThumbItem.self, forItemWithIdentifier: ThumbItem.id)

        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none

        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.blendingMode = .withinWindow
        let line = NSBox()
        line.boxType = .separator
        for v in [effect, scroll, line] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func reloadItem(_ url: URL) {
        ImageLoader.thumbnailCache.removeObject(forKey: url as NSURL)
        if let i = urls.firstIndex(of: url) { collection.reloadItems(at: [IndexPath(item: i, section: 0)]) }
    }

    private func updateSelection() {
        guard current >= 0, current < urls.count else { collection.deselectAll(nil); return }
        let path = IndexPath(item: current, section: 0)
        collection.selectionIndexPaths = [path]
        collection.scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbItem.id, for: indexPath) as! ThumbItem
        let url = urls[indexPath.item]
        item.url = url
        item.view.toolTip = url.lastPathComponent
        if let cached = ImageLoader.thumbnailCache.object(forKey: url as NSURL) {
            item.thumb.image = NSImage(cgImage: cached, size: .zero)
        } else {
            item.thumb.image = nil
            queue.addOperation { [weak item] in
                let image = ImageLoader.thumbnail(url, maxPixels: 160)
                OperationQueue.main.addOperation {
                    guard let item, item.url == url else { return }
                    item.thumb.image = image.map { NSImage(cgImage: $0, size: .zero) } ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                }
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let i = indexPaths.first?.item, i != current else { return }
        onSelect?(i)
    }
}

final class ThumbItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("thumb")
    let thumb = NSImageView()
    var url: URL?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4), thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 4), thumb.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : nil
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}
