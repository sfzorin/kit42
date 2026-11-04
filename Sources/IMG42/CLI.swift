import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Headless checks used while developing (not localised: developer output).
///
///     IMG42 --info a.jpg b.gif …            format, size, frames/pages, orientation, alpha, error
///     IMG42 --edit in out [--brightness 20 --contrast 30 … --look sepia --auto --demo-marks
///                         --rotate right --flip h --resize 800x600 --crop x,y,w,h --remove-background --description "…"]
///     IMG42 --stats file                    mean luminance / alpha
///     IMG42 --ocr file                      recognised text
///     IMG42 --rotate file left|right        lossless orientation change
///     IMG42 --types                         readable / writable types
///     IMG42 --smart-lasso in "x,y;x,y;…" out.png [radius] [--no-subject]   Smart Lasso selection mask for a stroke
///     IMG42 --smart-lasso-eval in [--gt mask.png] [--radius r] [--noise a] [--seed n] [--vis out.png]
///                                           simulated rough strokes around the subject: IoU of plain vs Smart Lasso
enum CLI {
    static var status: Int32 = 0

    static func run(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        switch args[1] {
        case "--info": info(Array(args.dropFirst(2)))
        case "--edit": edit(Array(args.dropFirst(2)))
        case "--stats": args.dropFirst(2).forEach(stats)
        case "--ocr": args.dropFirst(2).forEach(ocr)
        case "--rotate": rotate(Array(args.dropFirst(2)))
        case "--smart-lasso": smartLasso(Array(args.dropFirst(2)))
        case "--smart-lasso-eval": SmartLassoEval.run(Array(args.dropFirst(2)))
        case "--types":
            print("read:", ImageFormats.readableTypes.map(\.identifier).joined(separator: " "))
            print("write:", ImageWriter.writableTypes.map(\.identifier).joined(separator: " "))
        default: return false
        }
        return true
    }

    static func info(_ files: [String]) {
        for f in files {
            let url = URL(fileURLWithPath: f)
            let l = ImageLoader.load(url)
            var parts = [url.lastPathComponent, l.typeIdentifier ?? "?"]
            if let image = l.image {
                parts.append("\(image.width)x\(image.height)")
                parts.append(l.isAnimated ? "frames=\(l.pages.count)" : "pages=\(l.pageCount)")
                parts.append("orientation=\(l.orientation.rawValue)")
                parts.append(l.hasAlpha ? "alpha" : "opaque")
                parts.append("OK")
            } else {
                parts.append("ERROR: \(l.error ?? "?")")
            }
            print(parts.joined(separator: "\t"))
        }
    }

    static func edit(_ a: [String]) {
        guard a.count >= 2 else { print("usage: --edit in out [options]"); status = 2; return }
        let input = URL(fileURLWithPath: a[0]), output = URL(fileURLWithPath: a[1])
        guard var base = ImageLoader.load(input).image else { print("cannot read \(a[0])"); status = 1; return }
        var adjustments = Adjustments()
        var marks: [Mark] = []
        var description: String?? = .none
        var i = 2
        func value() -> String { i += 1; return i < a.count ? a[i] : "" }
        while i < a.count {
            let opt = a[i]
            let name = String(opt.dropFirst(2))
            if let key = Adjustments.Key(rawValue: name) {
                adjustments[key] = Double(value()) ?? 0
            } else {
                switch opt {
                case "--look":
                    let v = value()
                    adjustments.look = ["mono": .mono, "noir": .noir, "sepia": .sepia, "invert": .invert][v] ?? .none
                case "--auto": adjustments.autoEnhance = true
                case "--demo-marks": marks = Mark.demo(for: CGSize(width: base.width, height: base.height))
                case "--rotate", "--flip":
                    let v = value()
                    let op: Orientation.Op = opt == "--rotate" ? (v == "left" ? .rotateLeft : .rotateRight) : (v == "v" ? .flipVertical : .flipHorizontal)
                    let t = Orientation.transform(op, size: CGSize(width: base.width, height: base.height))
                    marks = marks.map { $0.applying(t) }
                    base = Orientation.apply(op.orientation, to: base)
                case "--resize":
                    let p = value().split(separator: "x").compactMap { Double($0) }
                    if p.count == 2, let r = ImageLoader.render(size: CGSize(width: p[0], height: p[1]), { $0.draw(base, in: CGRect(x: 0, y: 0, width: p[0], height: p[1])) }) {
                        base = r
                    }
                case "--crop":
                    let p = value().split(separator: ",").compactMap { Double($0) }
                    if p.count == 4, let sel = PixelSelection.from(path: CGPath(rect: CGRect(x: p[0], y: p[1], width: p[2], height: p[3]), transform: nil),
                                                                   size: CGSize(width: base.width, height: base.height), isRectangle: true),
                       let c = PixelOps.extract(sel, from: base) { base = c }
                case "--remove-background":
                    do { if let r = try PixelOps.removeBackground(base) { base = r } else { print("no subject found") } } catch { print("remove background: \(error)") }
                case "--description": description = .some(value())
                default: print("unknown option \(opt)"); status = 2
                }
            }
            i += 1
        }
        let final = Mark.flatten(marks, onto: adjustments.render(base))
        let type = UTType(filenameExtension: output.pathExtension)?.identifier ?? UTType.png.identifier
        do {
            try ImageWriter.write(final, to: output, type: type, metadataFrom: input, description: description)
            print("wrote \(output.lastPathComponent) \(final.width)x\(final.height) \(type)")
        } catch {
            print("error: \(error.localizedDescription)")
            status = 1
        }
    }

    static func stats(_ f: String) {
        guard let image = ImageLoader.load(URL(fileURLWithPath: f)).image else { print("\(f): cannot read"); status = 1; return }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var lum = 0.0, alpha = 0.0, sat = 0.0
        for i in 0..<(w * h) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            lum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            sat += max(r, g, b) - min(r, g, b)
            alpha += Double(px[i * 4 + 3])
        }
        let n = Double(w * h)
        print(String(format: "%@\t%dx%d\tluminance=%.1f\tchroma=%.1f\talpha=%.1f", (f as NSString).lastPathComponent, w, h, lum / n, sat / n, alpha / n))
    }

    static func ocr(_ f: String) {
        guard let image = ImageLoader.load(URL(fileURLWithPath: f)).image else { print("\(f): cannot read"); status = 1; return }
        for line in PixelOps.recognizeText(image) { print(line.text, "\t", line.box.integral) }
    }

    static func rotate(_ a: [String]) {
        guard a.count == 2 else { return }
        let url = URL(fileURLWithPath: a[0])
        let current = ImageLoader.load(url).orientation
        let op: Orientation.Op = a[1] == "left" ? .rotateLeft : a[1] == "right" ? .rotateRight : a[1] == "v" ? .flipVertical : .flipHorizontal
        let new = Orientation.compose(op, after: current)
        let ok = Orientation.rewriteLosslessly(url, orientation: new)
        print("\(url.lastPathComponent): orientation \(current.rawValue) → \(new.rawValue) \(ok ? "lossless OK" : "FAILED")")
        if !ok { status = 1 }
    }

    static func smartLasso(_ a: [String]) {
        guard a.count >= 3, let image = ImageLoader.load(URL(fileURLWithPath: a[0])).image else { print("usage: --smart-lasso in \"x,y;…\" out.png [radius]"); status = 2; return }
        let pts = a[1].split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }.filter { $0.count == 2 }.map { CGPoint(x: $0[0], y: $0[1]) }
        let radius = a.count > 3 ? CGFloat(Double(a[3]) ?? 12) : 12
        let noSubject = a.contains("--no-subject")
        let start = Date()
        let subject = noSubject ? nil : SmartLasso.subjectMask(for: image)
        let t1 = Date()
        guard let path = SmartLasso.refine(stroke: pts, radius: radius, image: image, subject: subject),
              let sel = PixelSelection.from(path: path, size: CGSize(width: image.width, height: image.height)) else { print("no selection"); status = 1; return }
        let t2 = Date()
        do {
            try ImageWriter.write(sel.mask, to: URL(fileURLWithPath: a[2]), type: "public.png")
            print(String(format: "wrote %@ bounds=%@ subject=%.2fs refine=%.3fs", a[2], NSStringFromRect(sel.bounds.integral), t1.timeIntervalSince(start), t2.timeIntervalSince(t1)))
        } catch { print("error: \(error)"); status = 1 }
    }
}
