import AppKit
import Kit42

/// One page of the document being scanned.
final class ScanPage {
    let id = UUID()
    /// Geometry-corrected scan (cropped, straight, upright) before clean-up; kept JPEG-compressed in memory.
    private(set) var base: CGImage
    /// What is shown and saved.
    private(set) var image: CGImage
    var dpi: Double
    var options: ProcessOptions
    var report: ProcessReport
    /// Recognised text (nil = not recognised yet).
    var text: [TextLine]?
    private var cachedThumbnail: NSImage?

    init(base: CGImage, image: CGImage, dpi: Double, options: ProcessOptions, report: ProcessReport) {
        self.base = ScanPage.compact(base)
        self.image = image
        self.dpi = dpi
        self.options = options
        self.report = report
    }

    /// Runs the whole pipeline on a raw scan.
    static func make(_ raw: RawScan, options: ProcessOptions) -> ScanPage {
        var o = options
        o.dpi = raw.dpi
        var geometry = o
        // Photos are straightened by their outline only (text skew would read their lines).
        geometry.deskew = o.deskew && o.enhancement != .photo
        geometry.enhancement = .none
        geometry.colorMode = .color
        geometry.brightness = 0
        geometry.contrast = 0
        let (base, report) = Processor.process(raw.image, geometry)
        let finished = Processor.finish(base, o) ?? base
        var r = report
        r.outputSize = CGSize(width: finished.width, height: finished.height)
        return ScanPage(base: base, image: finished, dpi: raw.dpi, options: o, report: r)
    }

    /// A JPEG-backed copy (decoded when drawn): a page costs a few MB instead of tens.
    static func compact(_ image: CGImage) -> CGImage {
        guard image.bitsPerPixel > 1, let data = Exporter.jpegData(image, quality: 0.94, dpi: 300), let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        return jpeg
    }

    var thumbnail: NSImage {
        if let cachedThumbnail { return cachedThumbnail }
        let side = 260
        let s = Double(side) / Double(max(image.width, image.height))
        let bmp = Bitmap(image, gray: image.colorSpace?.model == .monochrome).resized(width: max(1, Int(Double(image.width) * s)), height: max(1, Int(Double(image.height) * s)))
        let t = NSImage(cgImage: bmp.cgImage() ?? image, size: NSSize(width: bmp.width, height: bmp.height))
        cachedThumbnail = t
        return t
    }

    var exportPage: ExportPage {
        ExportPage(image: image, dpi: dpi, text: text, title: text.flatMap(OCR.title))
    }

    /// Re-runs clean-up with new options (enhancement, colour mode, brightness…).
    func refinish(_ o: ProcessOptions) {
        var opts = o
        opts.dpi = dpi
        options = opts
        image = Processor.finish(base, opts) ?? base
        cachedThumbnail = nil
    }

    func rotate(clockwise degrees: Int) {
        if let b = Processor.rotate90(base, clockwise: degrees) { base = ScanPage.compact(b) }
        image = Processor.rotate90(image, clockwise: degrees).map { image.bitsPerPixel == 1 ? (Bitmap($0, gray: true).oneBitImage(threshold: 128) ?? $0) : $0 } ?? image
        text = nil
        cachedThumbnail = nil
    }

    /// State for undo of rotation and clean-up.
    struct Snapshot {
        let base: CGImage, image: CGImage, options: ProcessOptions, text: [TextLine]?
    }
    var snapshot: Snapshot { Snapshot(base: base, image: image, options: options, text: text) }
    func restore(_ s: Snapshot) {
        base = s.base
        image = s.image
        options = s.options
        text = s.text
        cachedThumbnail = nil
    }
}

/// The pages of one window, with undo for every change.
final class ScanDocument {
    private(set) var pages: [ScanPage] = []
    let undo = UndoManager()
    var onChange: (() -> Void)?
    /// Changed since the last save.
    var isDirty = false

    var isEmpty: Bool { pages.isEmpty }

    private func changed(_ name: String) {
        isDirty = true
        undo.setActionName(name)
        onChange?()
    }

    func insert(_ new: [ScanPage], at index: Int, name: String = L("Add Pages")) {
        let i = min(max(0, index), pages.count)
        pages.insert(contentsOf: new, at: i)
        let ids = Set(new.map(\.id))
        undo.registerUndo(withTarget: self) { d in d.remove(ids: ids, name: name) }
        changed(name)
    }

    func append(_ new: [ScanPage]) { insert(new, at: pages.count) }

    func remove(ids: Set<UUID>, name: String = L("Delete Pages")) {
        let removed = pages.enumerated().filter { ids.contains($0.element.id) }
        guard !removed.isEmpty else { return }
        pages.removeAll { ids.contains($0.id) }
        undo.registerUndo(withTarget: self) { d in
            for (i, p) in removed { d.pages.insert(p, at: min(i, d.pages.count)) }
            d.undo.registerUndo(withTarget: d) { $0.remove(ids: ids, name: name) }
            d.changed(name)
        }
        changed(name)
    }

    /// Moves the pages at `indices` so they start at `destination` (index in the current array, before removal).
    func move(_ indices: IndexSet, to destination: Int) {
        let before = pages
        let moving = indices.map { pages[$0] }
        var rest = pages.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        let shift = indices.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(0, destination - shift), rest.count))
        guard rest.map(\.id) != before.map(\.id) else { return }
        setOrder(rest, name: L("Move Pages"))
    }

    func setOrder(_ order: [ScanPage], name: String) {
        let old = pages
        pages = order
        undo.registerUndo(withTarget: self) { $0.setOrder(old, name: name) }
        changed(name)
    }

    func replace(_ page: ScanPage, with new: [ScanPage], name: String = L("Rescan Page")) {
        guard let i = pages.firstIndex(where: { $0 === page }) else { append(new); return }
        var order = pages
        order.replaceSubrange(i...i, with: new)
        setOrder(order, name: name)
    }

    /// Changes pages in place (rotate, enhance) with undo.
    func modify(_ targets: [ScanPage], name: String, _ change: (ScanPage) -> Void) {
        let before = targets.map { ($0, $0.snapshot) }
        targets.forEach(change)
        registerRestore(before, name: name)
        changed(name)
    }

    private func registerRestore(_ states: [(ScanPage, ScanPage.Snapshot)], name: String) {
        undo.registerUndo(withTarget: self) { d in
            let redo = states.map { ($0.0, $0.0.snapshot) }
            states.forEach { $0.0.restore($0.1) }
            d.registerRestore(redo, name: name)
            d.changed(name)
        }
    }

    /// OCR results are not an edit (no undo), but the document must be saved again to keep them.
    func setText(_ page: ScanPage, _ lines: [TextLine]) {
        page.text = lines
        onChange?()
    }
}
