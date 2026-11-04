import AppKit
import ImageCaptureCore
import ImageIO
import PDFKit

/// Headless checks used while developing (not localised: developer output). Nothing here starts a real scan.
///
///     SCN42 --make-test-inputs dir             skewed page on glass, photos on glass, feeder pages (blank, skewed, upside down…)
///     SCN42 --process in.png out.png [--crop --deskew --rotate --enhance --photo --gray --bw --dpi n]
///     SCN42 --pipeline dir|files… out.pdf [--ocr --remove-blank --compress original|high|balanced|smallest --bw --gray --pdfa
///                                         --format pdf|tiff|jpeg|png|heic]
///     SCN42 --detect-photos glass.png [outdir]  photos on the glass → separate, straightened images
///     SCN42 --fake-scan dir out.pdf [--feeder --duplex --dpi n --photos]   the virtual scanner end to end
///     SCN42 --list-devices [seconds]           scanners Image Capture can see (read-only, default 3 s)
///     SCN42 --name "template"                  file name for a template now
enum CLI {
    static var status: Int32 = 0

    static func run(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        let rest = Array(args.dropFirst(2))
        setlinebuf(stdout)
        switch args[1] {
        case "--make-test-inputs":
            guard let dir = rest.first else { print("usage: --make-test-inputs dir"); status = 2; return true }
            do { print(try TestImages.write(to: URL(fileURLWithPath: dir)).joined(separator: "\n")) } catch { print("error: \(error)"); status = 1 }
        case "--process": process(rest)
        case "--pipeline": pipeline(rest)
        case "--detect-photos": detectPhotos(rest)
        case "--fake-scan": fakeScan(rest)
        case "--list-devices": listDevices(Double(rest.first ?? "") ?? 3)
        case "--name": print(Exporter.expand(rest.first ?? SaveOptions.defaultTemplate, counter: 7, title: "Invoice No 4217"))
        default: return false
        }
        return true
    }

    static func load(_ path: String) -> RawScan? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 10 && abs($0 - 72) > 0.5 ? $0 : nil } ?? 300
        return RawScan(image: image, dpi: dpi)
    }

    static func options(_ a: [String], defaults all: Bool) -> ProcessOptions {
        var o = ProcessOptions()
        let explicit = a.contains { ["--crop", "--deskew", "--rotate", "--enhance", "--photo"].contains($0) }
        let on = !explicit && all
        o.crop = on || a.contains("--crop")
        o.deskew = on || a.contains("--deskew")
        o.autoRotate = on || a.contains("--rotate")
        o.enhancement = a.contains("--photo") ? .photo : ((on || a.contains("--enhance")) ? .document : .none)
        o.colorMode = a.contains("--bw") ? .bw : (a.contains("--gray") ? .gray : .color)
        o.detectBlank = a.contains("--remove-blank")
        o.descreen = a.contains("--descreen")
        return o
    }

    static func value(_ a: [String], _ key: String) -> String? {
        guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func writePNG(_ image: CGImage, _ path: String, dpi: Double) {
        let ext = (path as NSString).pathExtension.lowercased()
        let type = ext == "jpg" || ext == "jpeg" ? "public.jpeg" : "public.png"
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        CGImageDestinationFinalize(dest)
        try? (out as Data).write(to: URL(fileURLWithPath: path))
    }

    static func process(_ a: [String]) {
        guard a.count >= 2, let raw = load(a[0]) else { print("usage: --process in out [--crop --deskew --rotate --enhance --bw]"); status = 2; return }
        var o = options(Array(a.dropFirst(2)), defaults: false)
        o.dpi = Double(value(a, "--dpi") ?? "") ?? raw.dpi
        let t = Date()
        let (image, report) = Processor.process(raw.image, o)
        print("\(a[0]): \(report.summary) time=\(String(format: "%.2f", Date().timeIntervalSince(t)))s")
        writePNG(image, a[1], dpi: o.dpi)
    }

    static func inputs(_ paths: [String]) -> [String] {
        var out: [String] = []
        for p in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
                out += files.filter { ["png", "jpg", "jpeg", "tif", "tiff", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (p as NSString).appendingPathComponent($0) }
            } else { out.append(p) }
        }
        return out
    }

    static func pipeline(_ a: [String]) {
        let positional = a.prefix { !$0.hasPrefix("--") }
        guard positional.count >= 2 else { print("usage: --pipeline dir|files… out.pdf [--ocr --remove-blank --compress balanced]"); status = 2; return }
        let flags = Array(a.dropFirst(positional.count))
        let out = positional.last!
        var o = options(flags, defaults: true)
        o.detectBlank = true
        let removeBlank = flags.contains("--remove-blank")
        var pages: [ScanPage] = []
        var removed = 0
        let start = Date()
        for path in inputs(Array(positional.dropLast())) {
            guard let raw = load(path) else { print("\(path): cannot read"); continue }
            let t = Date()
            let page = ScanPage.make(raw, options: o)
            print("\((path as NSString).lastPathComponent): \(page.report.summary) time=\(String(format: "%.2f", Date().timeIntervalSince(t)))s")
            if removeBlank && page.report.blank { removed += 1; continue }
            pages.append(page)
        }
        if flags.contains("--ocr") {
            for (i, p) in pages.enumerated() {
                p.text = OCR.recognize(p.image)
                let sample = OCR.text(p.text ?? []).replacingOccurrences(of: "\n", with: " | ")
                print("ocr page \(i + 1): \(p.text?.count ?? 0) lines: \(sample.prefix(160))")
            }
            if let title = pages.first?.text.flatMap(OCR.title) { print("title: \(title)") }
        }
        var save = SaveOptions()
        save.ocr = flags.contains("--ocr")
        save.compression = value(flags, "--compress").flatMap(Compression.named) ?? .balanced
        if flags.contains("--pdfa") { save.format = .pdfA }
        if let f = value(flags, "--format") { save.format = ["tiff": .tiff, "jpeg": .jpeg, "jpg": .jpeg, "png": .png, "heic": .heic, "pdf": .pdf][f] ?? .pdf }
        let url = URL(fileURLWithPath: out)
        do {
            let estimate = Exporter.estimate(pages.map(\.exportPage), save)
            let urls = try Exporter.write(pages.map(\.exportPage), folder: url.deletingLastPathComponent(), baseName: url.deletingPathExtension().lastPathComponent, options: save)
            for u in urls {
                let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print("wrote \(u.path): \(Exporter.sizeText(size)) (estimate \(Exporter.sizeText(estimate)))")
                if save.format.isPDF, let doc = PDFDocument(url: u) {
                    let text = (doc.string ?? "").replacingOccurrences(of: "\n", with: " ")
                    print("pdf: \(doc.pageCount) pages, searchable text \(text.count) chars: \(text.prefix(100))")
                }
            }
            print("pages: \(pages.count), blank removed: \(removed), compression: \(save.compression), total time \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        } catch { print("error: \(error.localizedDescription)"); status = 1 }
    }

    static func detectPhotos(_ a: [String]) {
        guard let path = a.first, let raw = load(path) else { print("usage: --detect-photos glass.png [outdir]"); status = 2; return }
        let found = Processor.detectPhotos(raw.image)
        print("photos: \(found.quads.count) (glass outlines \(found.glassCount), vision rectangles \(found.visionCount))")
        for (i, q) in found.quads.enumerated() {
            print(String(format: "photo %d: angle %.2f° size %.0fx%.0f box %@", i + 1, q.angle, q.width, q.height, q.description))
            if a.count > 1, let crop = Processor.perspectiveCrop(raw.image, q.inset(4)) {
                try? FileManager.default.createDirectory(atPath: a[1], withIntermediateDirectories: true)
                writePNG(crop, (a[1] as NSString).appendingPathComponent("photo-\(i + 1).png"), dpi: raw.dpi)
            }
        }
    }

    /// Drives the virtual scanner like the window does (overview → areas → scan, or the feeder).
    static func fakeScan(_ a: [String]) {
        guard a.count >= 2 else { print("usage: --fake-scan dir out.pdf [--feeder --duplex --dpi n --photos]"); status = 2; return }
        let scanner = FakeScanner(folder: URL(fileURLWithPath: a[0]))
        scanner.onStatus = { print("status: \($0.text)") }
        var settings = ScanSettings()
        settings.source = a.contains("--feeder") ? .feeder : .flatbed
        settings.duplex = a.contains("--duplex")
        settings.resolution = Int(value(a, "--dpi") ?? "") ?? 200
        settings.removeBlank = true
        settings.detectPhotos = a.contains("--photos")
        if settings.detectPhotos { settings.enhancement = .photo; settings.autoRotate = false }
        var pages: [ScanPage] = []
        var finished = false
        scanner.open()
        func scanAreas(_ areas: [CGRect]) {
            var queue = areas
            func next() {
                guard !queue.isEmpty else { finished = true; return }
                let area = queue.removeFirst()
                let req = ScanRequest(source: settings.source, resolution: settings.resolution, colorMode: settings.colorMode, bitDepth: 8,
                                      area: area, paper: nil, duplex: settings.duplex)
                scanner.scan(req, page: { raw in
                    let p = ScanPage.make(raw, options: settings.processing)
                    print("page \(pages.count + 1): \(raw.image.width)x\(raw.image.height)@\(Int(raw.dpi)) \(p.report.summary)")
                    if !(settings.removeBlank && p.report.blank) { pages.append(p) } else { print("  blank page removed") }
                }, done: { error in
                    if let error { print("scan error: \(error.localizedDescription)") }
                    next()
                })
            }
            next()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if settings.detectPhotos {
                scanner.overview { result in
                    guard case .success(let overview) = result else { print("overview failed"); finished = true; return }
                    let found = Processor.detectPhotos(overview).quads
                    let areas = found.map { Self.area(for: $0, in: overview) }
                    print("overview \(overview.width)x\(overview.height): \(areas.count) photos")
                    scanAreas(areas)
                }
            } else {
                scanAreas([CGRect(x: 0, y: 0, width: 1, height: 1)])
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        var save = SaveOptions()
        save.compression = .balanced
        save.ocr = false
        let url = URL(fileURLWithPath: a[1])
        if let urls = try? Exporter.write(pages.map(\.exportPage), folder: url.deletingLastPathComponent(), baseName: url.deletingPathExtension().lastPathComponent, options: save) {
            for u in urls { print("wrote \(u.path) \(Exporter.sizeText((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)), \(pages.count) pages") }
        }
    }

    /// Normalised scan area (origin top-left) around a quad found on an overview, with a small margin.
    static func area(for q: Quad, in image: CGImage) -> CGRect {
        let b = q.bounds.insetBy(dx: -CGFloat(image.width) * 0.012, dy: -CGFloat(image.width) * 0.012)
        let r = CGRect(x: b.minX / CGFloat(image.width), y: b.minY / CGFloat(image.height), width: b.width / CGFloat(image.width), height: b.height / CGFloat(image.height))
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Read-only discovery: lists what Image Capture sees; no session is opened.
    static func listDevices(_ seconds: Double) {
        final class Lister: NSObject, ICDeviceBrowserDelegate {
            var found: [ICDevice] = []
            func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) { found.append(device) }
            func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
        }
        let lister = Lister()
        let browser = ICDeviceBrowser()
        browser.delegate = lister
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue | ICDeviceLocationTypeMask.shared.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.bluetooth.rawValue | ICDeviceLocationTypeMask.remote.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        browser.start()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        browser.stop()
        if lister.found.isEmpty { print("no scanners found in \(Int(seconds)) s") }
        for d in lister.found {
            let s = d as? ICScannerDevice
            print("\(d.name ?? "?") — \(d.productKind ?? "") transport=\(d.transportType ?? "?") location=\(d.locationDescription ?? "?") uuid=\(d.uuidString ?? "?") units=\(s?.availableFunctionalUnitTypes.map(\.intValue) ?? [])")
        }
    }
}
