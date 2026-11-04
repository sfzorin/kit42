import CoreGraphics
import Foundation
import ImageIO

/// Area to clear on a page, in page (default user) space; `fill` is the sRGB colour of the box
/// drawn over it, also used for the pixels of images under it.
struct RedactionArea {
    var rect: CGRect
    var fill: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
    /// Also paint the box into the page content (redaction marks; edited text and whiteout boxes draw their own).
    var paint = false

    var gray: Double { Double(0.299 * fill.r + 0.587 * fill.g + 0.114 * fill.b) }
}

/// What a redaction pass removed.
struct RedactionReport {
    struct Page {
        var index: Int
        var text: [String] = []
        var glyphs = 0
        var images = 0
        var annotations = 0
        var rasterized: String?
    }
    var pages: [Page] = []

    var rasterizedPages: [Int] { pages.filter { $0.rasterized != nil }.map(\.index) }
    var isEmpty: Bool { pages.isEmpty }

    mutating func update(_ index: Int, _ change: (inout Page) -> Void) {
        if let i = pages.firstIndex(where: { $0.index == index }) { change(&pages[i]) } else {
            var p = Page(index: index)
            change(&p)
            pages.append(p)
            pages.sort { $0.index < $1.index }
        }
    }

    /// One line per page, for the command line.
    var lines: [String] {
        pages.map { p in
            var s = "p\(p.index + 1): removed \(p.glyphs) glyphs"
            if !p.text.isEmpty { s += " [" + p.text.joined(separator: " | ") + "]" }
            if p.images > 0 { s += ", \(p.images) image(s) cleared" }
            if p.annotations > 0 { s += ", \(p.annotations) annotation(s) removed" }
            if let r = p.rasterized { s += ", page rasterized (\(r))" }
            return s
        }
    }
}

/// True removal of page content under redaction areas: text-showing operators are rewritten so the
/// covered glyphs are gone (the rest of the line keeps its place: each removed glyph becomes an
/// equal TJ offset), image pixels under the areas are overwritten and the image re-encoded, Form
/// XObjects are processed recursively. Vector graphics are left alone (the box is drawn over them).
///
/// Works on files with a classic cross-reference table (what PDFKit writes) and returns the file
/// with an incremental update; `PDFCompactor` must run on the final file so that the old objects
/// do not survive. Pages that cannot be processed safely are reported in `failed`.
final class Redactor {
    fileprivate let file: PDFFileStructure
    private let cgDoc: CGPDFDocument
    private var updates: [Int: [UInt8]] = [:]
    /// Rewritten dictionaries (pages, resources), serialized into `updates` at the end.
    private var edited: [Int: PDFObject] = [:]
    /// XObjects replaced by redacted copies: they must not stay reachable through shared resources.
    fileprivate var replacedObjects = Set<Int>()
    private var nextNum: Int
    private var treeNodes: [Int] = []
    private var fonts: [UInt: RedactionFont] = [:]
    var report = RedactionReport()

    private init?(_ data: Data) {
        guard let file = try? PDFFileStructure(data), let size = file.trailer["Size"]?.int,
              let provider = CGDataProvider(data: data as CFData), let cg = CGPDFDocument(provider), !cg.isEncrypted else { return nil }
        self.file = file
        self.cgDoc = cg
        self.nextNum = size
    }

    /// Redacts `areas` (by page index). Returns nil when the file structure cannot be handled at all;
    /// otherwise the new file and the pages that could not be processed (left unchanged, with the reason).
    static func redact(_ data: Data, areas: [Int: [RedactionArea]]) -> (data: Data, failed: [Int: String], report: RedactionReport)? {
        guard let r = Redactor(data) else { return nil }
        let pages = r.pageObjects()
        guard pages.count == r.cgDoc.numberOfPages else { return nil }
        var failed: [Int: String] = [:]
        var done = Set<Int>()
        for (index, list) in areas.sorted(by: { $0.key < $1.key }) where index < pages.count && !list.isEmpty {
            let saved = (r.updates, r.nextNum, r.edited, r.replacedObjects)
            if let reason = r.redactPage(index, objectNumber: pages[index], areas: list) {
                failed[index] = reason
                (r.updates, r.nextNum, r.edited, r.replacedObjects) = saved
                r.report.pages.removeAll { $0.index == index }
            } else {
                done.insert(index)
            }
        }
        r.prune(pages: pages, redacted: done)
        for (num, obj) in r.edited { r.updates[num] = Array(obj.serialized.utf8) }
        return (r.write(data), failed, r.report)
    }

    private func current(_ num: Int) -> PDFObject? { edited[num] ?? (try? file.object(num)) }

    /// Replaced images and forms can still be listed in resources shared with other pages (an indirect
    /// /Resources, or one inherited from the page tree). Those entries go when no other page draws them.
    private func prune(pages: [Int], redacted: Set<Int>) {
        guard !replacedObjects.isEmpty else { return }
        var needed = Set<Int>()
        for (i, num) in pages.enumerated() where !redacted.contains(i) {
            guard let page = current(num), let cgPage = cgDoc.page(at: i + 1)?.dictionary else { continue }
            let res = ResourceContext(object: inheritedResources(page), cg: nil)
            var content: [UInt8] = []
            if let s = CGPDF.stream(cgPage, "Contents") { content = CGPDF.data(s)?.bytes ?? [] }
            else if let arr = CGPDF.array(cgPage, "Contents") {
                for k in 0..<CGPDFArrayGetCount(arr) {
                    var s: CGPDFStreamRef?
                    if CGPDFArrayGetStream(arr, k, &s) { content += (CGPDF.data(s)?.bytes ?? []) + [0x0A] }
                }
            }
            for op in ContentParser.operations(content) where op.op == "Do" {
                if let name = op.operands.first?.nameValue, let n = res.xobjectNumber(name, resolve) { needed.insert(n) }
            }
        }
        let gone = replacedObjects.subtracting(needed)
        guard !gone.isEmpty else { return }
        func strip(_ xo: PDFObject) -> PDFObject? {
            guard case .dict(let pairs) = xo else { return nil }
            let kept = pairs.filter { if case .ref(let n, _) = $0.1 { return !gone.contains(n) } else { return true } }
            return kept.count == pairs.count ? nil : .dict(kept)
        }
        /// Resources dictionary with the entries removed (nil: unchanged); indirect parts are rewritten in place.
        func stripResources(_ res: PDFObject) -> PDFObject? {
            switch res["XObject"] {
            case .ref(let x, _)?:
                if let xo = current(x), let s = strip(xo) { edited[x] = s }
                return nil
            case .dict?:
                return strip(res["XObject"]!).map { res.setting("XObject", $0) }
            default:
                return nil
            }
        }
        for num in Set(pages + treeNodes) {
            guard let node = current(num) else { continue }
            switch node["Resources"] {
            case .ref(let r, _)?:
                if let res = current(r), let s = stripResources(res) { edited[r] = s }
            case .dict?:
                if let s = stripResources(node["Resources"]!) { edited[num] = node.setting("Resources", s) }
            default:
                break
            }
        }
    }

    // MARK: - Pages

    private func pageObjects() -> [Int] {
        guard case .ref(let root, _)? = file.trailer["Root"], let catalog = try? file.object(root),
              case .ref(let pagesRoot, _)? = catalog["Pages"] else { return [] }
        var out: [Int] = []
        var seen = Set<Int>()
        func walk(_ num: Int, depth: Int) {
            guard depth < 64, !seen.contains(num), let node = try? file.object(num) else { return }
            seen.insert(num)
            if let kids = (try? file.resolve(node["Kids"]))??.items, node["Type"]?.nameValue != "Page" {
                treeNodes.append(num)
                for case .ref(let k, _) in kids { walk(k, depth: depth + 1) }
            } else {
                out.append(num)
            }
        }
        walk(pagesRoot, depth: 0)
        return out
    }

    /// Resources of a page, following /Parent.
    private func inheritedResources(_ page: PDFObject) -> PDFObject {
        var node: PDFObject? = page
        var depth = 0
        while let n = node, depth < 64 {
            if let r = (try? file.resolve(n["Resources"])) ?? nil, case .dict = r { return r }
            node = (try? file.resolve(n["Parent"])) ?? nil
            depth += 1
        }
        return .dict([])
    }

    /// Nil on success, else why the page could not be processed.
    private func redactPage(_ index: Int, objectNumber: Int, areas: [RedactionArea]) -> String? {
        guard let pageDict = try? file.object(objectNumber), let cgPage = cgDoc.page(at: index + 1), let cgDict = cgPage.dictionary else {
            return "page object not found"
        }
        var content: [UInt8] = []
        if let s = CGPDF.stream(cgDict, "Contents") {
            guard let d = CGPDF.data(s), d.format == .raw else { return "unreadable content stream" }
            content = d.bytes
        } else if let arr = CGPDF.array(cgDict, "Contents") {
            for i in 0..<CGPDFArrayGetCount(arr) {
                var s: CGPDFStreamRef?
                guard CGPDFArrayGetStream(arr, i, &s), let d = CGPDF.data(s), d.format == .raw else { return "unreadable content stream" }
                content += d.bytes + [0x0A]
            }
        }
        let res = ResourceContext(object: inheritedResources(pageDict), cg: CGPDF.inherited(cgDict, "Resources"))
        let run = ContentRedaction(redactor: self, areas: areas, page: index)
        let rewritten = run.process(content, res: res, ctm: .identity, depth: 0)
        if let failure = run.failure { return failure }
        report.update(index) { p in
            p.glyphs += run.glyphs
            p.images += run.images
            p.text += run.removedText.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        var body = rewritten
        let paints = areas.filter(\.paint)
        if !paints.isEmpty {
            // The original content in its own q/Q (it may leave the state changed), then the boxes.
            var boxes = ""
            for a in paints {
                let r = a.rect
                boxes += "\(formatPDFNumber(Double(a.fill.r))) \(formatPDFNumber(Double(a.fill.g))) \(formatPDFNumber(Double(a.fill.b))) rg "
                    + "\(formatPDFNumber(r.minX)) \(formatPDFNumber(r.minY)) \(formatPDFNumber(r.width)) \(formatPDFNumber(r.height)) re f\n"
            }
            body = Array("q\n".utf8) + (rewritten ?? content) + Array("\nQ\nq\n\(boxes)Q\n".utf8)
        }
        guard body != nil || !res.added.isEmpty else { return nil }
        let contentNum = addStream(.dict([]), body ?? content)
        // /Thumb: an embedded preview picture of the page would still show what was removed.
        let newPage = pageDict.setting("Contents", .ref(contentNum, 0)).setting("Resources", res.resourcesObject(file)).removing("Thumb")
        edited[objectNumber] = newPage
        return nil
    }

    // MARK: - Objects

    fileprivate func font(_ dict: CGPDFDictionaryRef) -> RedactionFont {
        let key = unsafeBitCast(dict, to: UInt.self)
        if let f = fonts[key] { return f }
        let f = RedactionFont(dict)
        fonts[key] = f
        return f
    }

    fileprivate func object(_ num: Int) -> PDFObject? { try? file.object(num) }
    fileprivate func resolve(_ obj: PDFObject?) -> PDFObject? { (try? file.resolve(obj)) ?? nil }

    /// New stream object: `dict` without its old filter/length, the data deflated.
    fileprivate func addStream(_ dict: PDFObject, _ data: [UInt8], filter: String? = nil) -> Int {
        var d = dict.removing("Length").removing("Filter").removing("DecodeParms").removing("DL")
        var body = data
        if let filter {
            d = d.setting("Filter", .name(filter))
        } else if let z = zlibCompress(data) {
            body = z
            d = d.setting("Filter", .name("FlateDecode"))
        }
        d = d.setting("Length", .raw("\(body.count)"))
        let num = nextNum
        nextNum += 1
        updates[num] = Array(d.serialized.utf8) + Array("\nstream\n".utf8) + body + Array("\nendstream".utf8)
        return num
    }

    private func write(_ data: Data) -> Data {
        guard !updates.isEmpty, let size = file.trailer["Size"]?.int else { return data }
        var out = [UInt8](data)
        if out.last != 0x0A { out.append(0x0A) }
        var entries: [(num: Int, offset: Int)] = []
        for num in updates.keys.sorted() {
            entries.append((num, out.count))
            out += Array("\(num) \(num >= size ? 0 : file.gen(num)) obj\n".utf8) + updates[num]! + Array("\nendobj\n".utf8)
        }
        let xrefOffset = out.count
        var xref = "xref\n"
        for e in entries { xref += "\(e.num) 1\n" + String(format: "%010d %05d n\r\n", e.offset, e.num >= size ? 0 : file.gen(e.num)) }
        let trailer = file.trailer.removing("XRefStm").removing("Prev")
            .setting("Size", .raw("\(nextNum)")).setting("Prev", .raw("\(file.startxref)"))
        xref += "trailer\n\(trailer.serialized)\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(xref.utf8)
        return Data(out)
    }
}

// MARK: - Resources

/// A resource dictionary seen two ways: as file objects (to write a modified copy) and through
/// CGPDF (decoded streams, resolved references). New XObjects are collected in `added`.
private final class ResourceContext {
    let object: PDFObject
    let cg: CGPDFDictionaryRef?
    var added: [(name: String, num: Int)] = []
    /// XObject names drawn unchanged / replaced everywhere they were drawn: replaced ones that are not
    /// used anymore leave the dictionary, so the original image or form is no longer in the file.
    var used = Set<String>()
    var replaced = Set<String>()

    init(object: PDFObject, cg: CGPDFDictionaryRef?) {
        self.object = object
        self.cg = cg
    }

    func resourcesObject(_ file: PDFFileStructure) -> PDFObject {
        guard !added.isEmpty else { return object }
        var xo = ((try? file.resolve(object["XObject"])) ?? nil) ?? .dict([])
        if case .dict = xo {} else { xo = .dict([]) }
        for a in added { xo = xo.setting(a.name, .ref(a.num, 0)) }
        let gone = Set(replaced.subtracting(used).map(AcroFormFixer.unescapeName))
        if case .dict(let pairs) = xo { xo = .dict(pairs.filter { !gone.contains(AcroFormFixer.unescapeName($0.0)) }) }
        return object.setting("XObject", xo)
    }

    func cgEntry(_ category: String, _ name: String) -> CGPDFObjectRef? {
        CGPDF.object(CGPDF.dict(cg, category), AcroFormFixer.unescapeName(name))
    }

    /// Object number of a named XObject in the file.
    func xobjectNumber(_ name: String, _ file: (PDFObject?) -> PDFObject?) -> Int? {
        guard case .dict(let pairs)? = file(object["XObject"]) else { return nil }
        let wanted = AcroFormFixer.unescapeName(name)
        for (k, v) in pairs where AcroFormFixer.unescapeName(k) == wanted {
            if case .ref(let n, _) = v { return n }
        }
        return nil
    }
}

// MARK: - Content rewriting

private final class ContentRedaction {
    unowned let redactor: Redactor
    let areas: [RedactionArea]
    let page: Int
    var failure: String?
    var glyphs = 0
    var images = 0
    var removedText: [String] = []

    init(redactor: Redactor, areas: [RedactionArea], page: Int) {
        self.redactor = redactor
        self.areas = areas
        self.page = page
    }

    struct GState {
        var ctm: CGAffineTransform
        var font: RedactionFont?
        var size: Double = 0
        var tc: Double = 0, tw: Double = 0, th: Double = 1, tl: Double = 0, rise: Double = 0
    }

    enum Chunk {
        case raw(Range<Int>)
        case text(String)
    }

    enum Element {
        case codes([UInt8])
        case shift(Double)
    }

    /// Rewritten stream, or nil when nothing in it (or in its forms) changed.
    func process(_ content: [UInt8], res: ResourceContext, ctm: CGAffineTransform, depth: Int) -> [UInt8]? {
        guard depth < 16 else { failure = "forms nested too deeply"; return nil }
        let ops = ContentParser.operations(content)
        var chunks: [Chunk] = []
        var changed = false
        var gs = GState(ctm: ctm)
        var stack: [GState] = []
        var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
        // Open marked-content sections: chunk index, operation, whether a glyph inside was removed.
        var marked: [(chunk: Int, op: ContentOp, tainted: Bool)] = []

        func nums(_ op: ContentOp) -> [Double]? {
            let n = op.operands.compactMap(\.number)
            return n.count == op.operands.count ? n : nil
        }
        func moveLine(_ tx: Double, _ ty: Double) {
            tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
            tm = tlm
        }

        /// Shows `items` (strings and TJ offsets); returns the rewritten elements, or nil if no glyph was removed.
        func show(_ items: [CToken]) -> [Element]? {
            var out: [Element] = []
            var removed = false
            var piece = ""
            for item in items {
                switch item {
                case .number(let n):
                    tm = CGAffineTransform(translationX: -n / 1000 * gs.size * gs.th, y: 0).concatenating(tm)
                    out.append(.shift(n))
                case .string(let bytes):
                    guard let font = gs.font else {
                        if !bytes.isEmpty { failure = failure ?? "text in an unknown font" }
                        continue
                    }
                    if let reason = font.unsupported { failure = failure ?? reason; continue }
                    var offset = 0
                    for (code, len) in font.codes(bytes) {
                        let w0 = font.width(code)
                        let spacing = gs.tc + (len == 1 && code == 32 ? gs.tw : 0)
                        let tx = (w0 / 1000 * gs.size + spacing) * gs.th
                        let trm = CGAffineTransform(a: gs.size * gs.th, b: 0, c: 0, d: gs.size, tx: 0, ty: gs.rise)
                            .concatenating(tm).concatenating(gs.ctm)
                        let box = CGRect(x: 0, y: font.descent / 1000, width: max(0, w0) / 1000, height: (font.ascent - font.descent) / 1000)
                            .applying(trm)
                        if covered(box) {
                            let scale = gs.size * gs.th
                            if abs(scale) < 1e-9 {
                                if abs(tx) > 1e-9 { failure = failure ?? "text with zero font size" }
                            } else {
                                out.append(.shift(-tx / scale * 1000))
                            }
                            removed = true
                            glyphs += 1
                            piece += font.text(code)
                        } else {
                            out.append(.codes(Array(bytes[offset..<offset + len])))
                        }
                        offset += len
                        tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
                    }
                default:
                    break
                }
            }
            if removed {
                removedText.append(piece)
                for k in marked.indices { marked[k].tainted = true }
            }
            return removed ? out : nil
        }

        func tj(_ elements: [Element]) -> String {
            var parts: [String] = []
            var codes: [UInt8] = []
            var shift: Double = 0
            func flushCodes() { if !codes.isEmpty { parts.append(CToken.string(codes).serialized); codes = [] } }
            func flushShift() { if abs(shift) > 1e-6 { parts.append(formatPDFNumber(shift)) }; shift = 0 }
            for e in elements {
                switch e {
                case .codes(let c): flushShift(); codes += c
                case .shift(let s): flushCodes(); shift += s
                }
            }
            flushCodes(); flushShift()
            return "[" + parts.joined(separator: " ") + "] TJ"
        }

        for op in ops {
            if failure != nil { return nil }
            var replacement: String?
            switch op.op {
            case "q": stack.append(gs)
            case "Q": if let g = stack.popLast() { gs = g }
            case "cm":
                if let n = nums(op), n.count == 6 {
                    gs.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(gs.ctm)
                }
            case "BT": tm = .identity; tlm = .identity
            case "Tc": if let v = op.operands.first?.number { gs.tc = v }
            case "Tw": if let v = op.operands.first?.number { gs.tw = v }
            case "Tz": if let v = op.operands.first?.number { gs.th = v / 100 }
            case "TL": if let v = op.operands.first?.number { gs.tl = v }
            case "Ts": if let v = op.operands.first?.number { gs.rise = v }
            case "Tf":
                if op.operands.count == 2, let name = op.operands[0].nameValue, let size = op.operands[1].number {
                    gs.size = size
                    var dict: CGPDFDictionaryRef?
                    if let obj = res.cgEntry("Font", name), CGPDFObjectGetValue(obj, .dictionary, &dict), let dict {
                        gs.font = redactor.font(dict)
                    } else {
                        gs.font = nil
                    }
                }
            case "Td":
                if let n = nums(op), n.count == 2 { moveLine(n[0], n[1]) }
            case "TD":
                if let n = nums(op), n.count == 2 { gs.tl = -n[1]; moveLine(n[0], n[1]) }
            case "Tm":
                if let n = nums(op), n.count == 6 {
                    tlm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                    tm = tlm
                }
            case "T*": moveLine(0, -gs.tl)
            case "Tj":
                if let s = op.operands.last, case .string = s, let out = show([s]) { replacement = tj(out) }
            case "TJ":
                if let a = op.operands.last?.items, let out = show(a) { replacement = tj(out) }
            case "'":
                moveLine(0, -gs.tl)
                if let s = op.operands.last, case .string = s, let out = show([s]) { replacement = "T* " + tj(out) }
            case "\"":
                if op.operands.count == 3, let aw = op.operands[0].number, let ac = op.operands[1].number {
                    gs.tw = aw; gs.tc = ac
                    moveLine(0, -gs.tl)
                    if let out = show([op.operands[2]]) {
                        replacement = "\(formatPDFNumber(aw)) Tw \(formatPDFNumber(ac)) Tc T* " + tj(out)
                    }
                }
            case "gs":
                if let name = op.operands.first?.nameValue, let obj = res.cgEntry("ExtGState", name) {
                    var d: CGPDFDictionaryRef?
                    if CGPDFObjectGetValue(obj, .dictionary, &d), CGPDF.object(d, "Font") != nil { gs.font = nil }
                }
            case "Do":
                if let name = op.operands.first?.nameValue {
                    if let newName = xobject(name, res: res, ctm: gs.ctm, depth: depth) {
                        replacement = "/\(newName) Do"
                        res.replaced.insert(name)
                        if let n = res.xobjectNumber(name, redactor.resolve) { redactor.replacedObjects.insert(n) }
                    } else {
                        res.used.insert(name)
                    }
                }
            case "BI":
                if intersects(CGRect(x: 0, y: 0, width: 1, height: 1).applying(gs.ctm)) { failure = failure ?? "inline image under the area" }
            case "BDC", "BMC":
                marked.append((chunks.count, op, false))
            case "EMC":
                if let m = marked.popLast(), m.tainted, m.op.op == "BDC", case .dict(let pairs)? = m.op.operands.last {
                    // /ActualText, /Alt and /E would still carry the removed text.
                    let kept = pairs.filter { !["ActualText", "Alt", "E"].contains($0.0) }
                    if kept.count != pairs.count {
                        let tag = m.op.operands.first?.serialized ?? "/Span"
                        chunks[m.chunk] = .text("\(tag) \(CToken.dict(kept).serialized) BDC")
                        changed = true
                    }
                }
            default:
                break
            }
            if let replacement {
                chunks.append(.text(replacement))
                changed = true
            } else {
                chunks.append(.raw(op.range))
            }
        }
        if failure != nil || !changed { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(content.count + 256)
        for c in chunks {
            switch c {
            case .raw(let r): out += content[r]
            case .text(let s): out += Array(s.utf8)
            }
            out.append(0x0A)
        }
        return out
    }

    // MARK: Geometry

    /// A glyph goes when the area covers at least 30% of its width and of its height.
    func covered(_ box: CGRect) -> Bool {
        for a in areas {
            let r = a.rect
            let i = box.intersection(r)
            if i.isNull { continue }
            let wr = box.width > 0.01 ? i.width / box.width : (box.midX >= r.minX && box.midX <= r.maxX ? 1 : 0)
            let hr = box.height > 0.01 ? i.height / box.height : (box.midY >= r.minY && box.midY <= r.maxY ? 1 : 0)
            if wr >= 0.3, hr >= 0.3 { return true }
        }
        return false
    }

    func intersects(_ box: CGRect) -> Bool {
        areas.contains { let i = box.intersection($0.rect); return !i.isNull && i.width > 0.01 && i.height > 0.01 }
    }

    // MARK: XObjects

    /// Name of the replacement XObject when `name` (drawn with `ctm`) had to change.
    func xobject(_ name: String, res: ResourceContext, ctm: CGAffineTransform, depth: Int) -> String? {
        var stream: CGPDFStreamRef?
        guard let obj = res.cgEntry("XObject", name), CGPDFObjectGetValue(obj, .stream, &stream), let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        let subtype = CGPDF.name(dict, "Subtype")
        if subtype == "Image" {
            guard intersects(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)) else { return nil }
            guard let num = res.xobjectNumber(name, redactor.resolve), let original = redactor.object(num) else {
                failure = "image object not found"; return nil
            }
            switch ImageRedaction.redact(stream, dict: dict, object: original, ctm: ctm, areas: areas) {
            case .unchanged: return nil
            case .failed(let reason): failure = reason; return nil
            case .replaced(let newDict, let data, let filter):
                let n = redactor.addStream(newDict, data, filter: filter)
                images += 1
                let newName = "PDF42R\(n)"
                res.added.append((newName, n))
                return newName
            }
        }
        guard subtype == "Form" else { return nil }
        let matrix = CGPDF.matrix(CGPDF.array(dict, "Matrix")) ?? .identity
        let formCTM = matrix.concatenating(ctm)
        let ownCG = CGPDF.dict(dict, "Resources")
        let inherited = ownCG == nil
        // Cheap test first: a form whose box is nowhere near the areas cannot change. (Forms using the
        // parent's resources are always read: the names they use must stay in the parent's dictionary.)
        let bbox = CGPDF.numbers(CGPDF.array(dict, "BBox"))
        if bbox.count == 4, !inherited {
            let r = CGRect(x: min(bbox[0], bbox[2]), y: min(bbox[1], bbox[3]), width: abs(bbox[2] - bbox[0]), height: abs(bbox[3] - bbox[1]))
            if !intersects(r.applying(formCTM)) { return nil }
        }
        guard let num = res.xobjectNumber(name, redactor.resolve), let original = redactor.object(num) else {
            failure = "form object not found"; return nil
        }
        guard let content = CGPDF.data(stream), content.format == .raw else { failure = "unreadable form"; return nil }
        let child = ResourceContext(object: inherited ? res.object : (redactor.resolve(original["Resources"]) ?? .dict([])),
                                    cg: inherited ? res.cg : ownCG)
        let rewritten = process(content.bytes, res: child, ctm: formCTM, depth: depth + 1)
        if failure != nil { return nil }
        guard rewritten != nil || !child.added.isEmpty else {
            if inherited { res.used.formUnion(child.used) }
            return nil
        }
        var newDict = original
        if !child.added.isEmpty || inherited { newDict = newDict.setting("Resources", child.resourcesObject(redactor.file)) }
        let n = redactor.addStream(newDict, rewritten ?? content.bytes)
        let newName = "PDF42R\(n)"
        res.added.append((newName, n))
        return newName
    }
}

// MARK: - Images

private enum ImageRedaction {
    enum Result {
        case unchanged
        case failed(String)
        case replaced(PDFObject, [UInt8], filter: String?)
    }

    /// Pixel rectangle (and, for rotated or skewed images, the exact polygon) covered by each area.
    struct Region {
        var fill: RedactionArea
        var x0: Int, x1: Int, y0: Int, y1: Int
        var polygon: [CGPoint]?

        func contains(_ x: Int, _ y: Int) -> Bool {
            guard let polygon else { return true }
            let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            var sign = 0
            for k in 0..<polygon.count {
                let a = polygon[k], b = polygon[(k + 1) % polygon.count]
                let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                let s = cross > 0 ? 1 : cross < 0 ? -1 : 0
                if s == 0 { continue }
                if sign == 0 { sign = s } else if s != sign { return false }
            }
            return true
        }
    }

    static func regions(width: Int, height: Int, ctm: CGAffineTransform, areas: [RedactionArea]) -> [Region] {
        let det = ctm.a * ctm.d - ctm.b * ctm.c
        guard abs(det) > 1e-12 else { return [] }
        let inv = ctm.inverted()
        let image = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        let axisAligned = (abs(ctm.b) < 1e-9 && abs(ctm.c) < 1e-9) || (abs(ctm.a) < 1e-9 && abs(ctm.d) < 1e-9)
        var out: [Region] = []
        for a in areas {
            let i = image.intersection(a.rect)
            guard !i.isNull, i.width > 0.01, i.height > 0.01 else { continue }
            let r = a.rect
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                .map { $0.applying(inv) }
                .map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let x0 = max(0, Int(floor(xs.min()!))), x1 = min(width, Int(ceil(xs.max()!)))
            let y0 = max(0, Int(floor(ys.min()!))), y1 = min(height, Int(ceil(ys.max()!)))
            guard x1 > x0, y1 > y0 else { continue }
            out.append(Region(fill: a, x0: x0, x1: x1, y0: y0, y1: y1, polygon: axisAligned ? nil : corners))
        }
        return out
    }

    static func redact(_ stream: CGPDFStreamRef, dict: CGPDFDictionaryRef, object: PDFObject, ctm: CGAffineTransform,
                       areas: [RedactionArea]) -> Result {
        guard let w = CGPDF.number(dict, "Width").map(Int.init), let h = CGPDF.number(dict, "Height").map(Int.init), w > 0, h > 0,
              w * h < 400_000_000 else { return .failed("image without size") }
        let regions = regions(width: w, height: h, ctm: ctm, areas: areas)
        guard !regions.isEmpty else { return .unchanged }
        guard let decoded = CGPDF.data(stream) else { return .failed("image filter not supported") }
        switch decoded.format {
        case .raw: return raw(decoded.bytes, width: w, height: h, dict: dict, object: object, regions: regions)
        case .jpegEncoded, .JPEG2000: return encoded(decoded.bytes, width: w, height: h, object: object, regions: regions)
        @unknown default: return .failed("image format not supported")
        }
    }

    /// Samples as decoded by CGPDF: fill the covered pixels with the area colour in the image's colour space.
    static func raw(_ data: [UInt8], width: Int, height: Int, dict: CGPDFDictionaryRef, object: PDFObject, regions: [Region]) -> Result {
        let isMask = CGPDF.bool(dict, "ImageMask")
        let bpc = isMask ? 1 : Int(CGPDF.number(dict, "BitsPerComponent") ?? 8)
        guard [1, 2, 4, 8, 16].contains(bpc) else { return .failed("image with \(bpc) bits per component") }
        let maxValue = Double((1 << bpc) - 1)
        let decode = CGPDF.numbers(CGPDF.array(dict, "Decode"))
        // Target sample values per area.
        let n: Int
        var samples: (RedactionArea) -> [Int]
        func sample(_ t: Double, _ c: Int, _ dflt: (Double, Double)) -> Int {
            let lo = decode.count > 2 * c + 1 ? decode[2 * c] : dflt.0
            let hi = decode.count > 2 * c + 1 ? decode[2 * c + 1] : dflt.1
            guard abs(hi - lo) > 1e-9 else { return 0 }
            return Int(max(0, min(maxValue, ((t - lo) / (hi - lo) * maxValue).rounded())))
        }
        if isMask {
            n = 1
            // Leave the page unpainted there: the image mask no longer carries the shapes.
            samples = { _ in [sample(1, 0, (0, 1))] }
        } else {
            guard let obj = CGPDF.object(dict, "ColorSpace"), let cs = ColorSpace(obj, bpc: bpc) else { return .failed("image colour space not supported") }
            n = cs.components
            samples = { area in cs.values(area).enumerated().map { sample($0.element, $0.offset, cs.defaultDecode($0.offset, maxValue)) } }
        }
        let rowBytes = (width * n * bpc + 7) / 8
        guard data.count >= rowBytes * height else { return .failed("image data too short") }
        var bytes = data
        for region in regions {
            let values = samples(region.fill)
            for y in region.y0..<region.y1 {
                let row = y * rowBytes
                for x in region.x0..<region.x1 where region.contains(x, y) {
                    for c in 0..<n {
                        let v = values[c]
                        let index = x * n + c
                        switch bpc {
                        case 8: bytes[row + index] = UInt8(v)
                        case 16: bytes[row + index * 2] = UInt8(v >> 8); bytes[row + index * 2 + 1] = UInt8(v & 0xFF)
                        default:
                            let bit = index * bpc
                            let shift = 8 - bpc - bit % 8
                            let mask = UInt8(((1 << bpc) - 1) << shift)
                            bytes[row + bit / 8] = (bytes[row + bit / 8] & ~mask) | UInt8(v << shift)
                        }
                    }
                }
            }
        }
        let newDict = object.removing("Filter").removing("DecodeParms").removing("Length").removing("DL")
        return .replaced(newDict, Array(bytes[0..<rowBytes * height]), filter: nil)
    }

    /// JPEG / JPEG 2000: decode, paint, re-encode as JPEG in DeviceGray or DeviceRGB.
    static func encoded(_ data: [UInt8], width: Int, height: Int, object: PDFObject, regions: [Region]) -> Result {
        guard let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .failed("image could not be decoded") }
        let gray = image.colorSpace?.model == .monochrome
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
              let buffer = ctx.data else { return .failed("image could not be decoded") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = buffer.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        let sx = Double(w) / Double(width), sy = Double(h) / Double(height)
        for region in regions {
            let f = region.fill
            let px: [UInt8] = gray ? [UInt8(f.gray * 255)] : [UInt8(f.fill.r * 255), UInt8(f.fill.g * 255), UInt8(f.fill.b * 255), 255]
            for y in Int(Double(region.y0) * sy)..<min(h, Int(ceil(Double(region.y1) * sy))) {
                for x in Int(Double(region.x0) * sx)..<min(w, Int(ceil(Double(region.x1) * sx)))
                where region.contains(Int(Double(x) / sx), Int(Double(y) / sy)) {
                    let o = y * ctx.bytesPerRow + x * px.count
                    for k in 0..<px.count { p[o + k] = px[k] }
                }
            }
        }
        guard let painted = ctx.makeImage() else { return .failed("image could not be encoded") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return .failed("image could not be encoded") }
        CGImageDestinationAddImage(dest, painted, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return .failed("image could not be encoded") }
        let newDict = object.removing("Filter").removing("DecodeParms").removing("Length").removing("DL").removing("Decode")
            .setting("ColorSpace", .name(gray ? "DeviceGray" : "DeviceRGB")).setting("BitsPerComponent", .raw("8"))
            .setting("Width", .raw("\(w)")).setting("Height", .raw("\(h)"))
        return .replaced(newDict, [UInt8](out as Data), filter: "DCTDecode")
    }
}

/// Colour spaces of image samples: number of components and the value of the area colour in each.
private struct ColorSpace {
    enum Family { case gray, rgb, cmyk, indexed(base: [[Double]]), ink(Int) }
    let family: Family
    let components: Int

    init?(_ obj: CGPDFObjectRef, bpc: Int) {
        var name: UnsafePointer<CChar>?
        var arr: CGPDFArrayRef?
        if CGPDFObjectGetValue(obj, .name, &name), let name {
            switch String(cString: name) {
            case "DeviceGray", "G", "CalGray": family = .gray; components = 1
            case "DeviceRGB", "RGB", "CalRGB": family = .rgb; components = 3
            case "DeviceCMYK", "CMYK": family = .cmyk; components = 4
            default: return nil
            }
            return
        }
        guard CGPDFObjectGetValue(obj, .array, &arr), let arr, let kind = CGPDF.name(arr, 0) else { return nil }
        switch kind {
        case "CalGray": family = .gray; components = 1
        case "CalRGB": family = .rgb; components = 3
        case "ICCBased":
            var s: CGPDFStreamRef?
            guard CGPDFArrayGetStream(arr, 1, &s), let s, let n = CGPDF.number(CGPDFStreamGetDictionary(s), "N") else { return nil }
            switch Int(n) {
            case 1: family = .gray; components = 1
            case 3: family = .rgb; components = 3
            case 4: family = .cmyk; components = 4
            default: return nil
            }
        case "Indexed", "I":
            var baseObj: CGPDFObjectRef?
            var hival: CGPDFInteger = 0
            guard CGPDFArrayGetObject(arr, 1, &baseObj), let baseObj, let base = ColorSpace(baseObj, bpc: 8),
                  CGPDFArrayGetInteger(arr, 2, &hival), hival >= 0, hival < 4096 else { return nil }
            var lookup: [UInt8] = []
            var str: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(arr, 3, &str), let str { lookup = CGPDF.bytes(str) }
            else if CGPDFArrayGetStream(arr, 3, &stream), let d = CGPDF.data(stream) { lookup = d.bytes }
            let nb = base.components
            var colors: [[Double]] = []
            for i in 0...Int(hival) {
                let c = (0..<nb).map { k -> Double in i * nb + k < lookup.count ? Double(lookup[i * nb + k]) / 255 : 0 }
                colors.append(base.rgb(c))
            }
            family = .indexed(base: colors)
            components = 1
        case "Separation": family = .ink(1); components = 1
        case "DeviceN":
            var names: CGPDFArrayRef?
            guard CGPDFArrayGetArray(arr, 1, &names), let names else { return nil }
            let n = CGPDFArrayGetCount(names)
            guard n > 0 else { return nil }
            family = .ink(n); components = n
        default: return nil
        }
    }

    func rgb(_ c: [Double]) -> [Double] {
        switch family {
        case .gray: return [c[0], c[0], c[0]]
        case .rgb: return c
        case .cmyk: return [(1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])]
        default: return [0, 0, 0]
        }
    }

    func defaultDecode(_ c: Int, _ maxValue: Double) -> (Double, Double) {
        if case .indexed = family { return (0, maxValue) }
        return (0, 1)
    }

    /// The area colour in this space (decoded values).
    func values(_ a: RedactionArea) -> [Double] {
        let r = Double(a.fill.r), g = Double(a.fill.g), b = Double(a.fill.b)
        switch family {
        case .gray: return [a.gray]
        case .rgb: return [r, g, b]
        case .cmyk:
            let k = 1 - max(r, g, b)
            guard k < 1 else { return [0, 0, 0, 1] }
            return [(1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k]
        case .indexed(let colors):
            var best = 0, bestD = Double.infinity
            for (i, c) in colors.enumerated() {
                let d = (c[0] - r) * (c[0] - r) + (c[1] - g) * (c[1] - g) + (c[2] - b) * (c[2] - b)
                if d < bestD { bestD = d; best = i }
            }
            return [Double(best)]
        case .ink(let n):
            return Array(repeating: 1 - a.gray, count: n)
        }
    }
}

// MARK: - Compacting

/// Rewrites a file with a classic cross-reference table keeping only the objects reachable from the
/// trailer: older versions of redacted pages, content streams and images are dropped. Form fields
/// whose widgets are on no page anymore (removed under a redaction) leave /AcroForm too.
enum PDFCompactor {
    static func compact(_ data: Data) -> Data? {
        guard let file = try? PDFFileStructure(data) else { return nil }
        let bytes = file.bytes
        let overrides = orphanFieldsRemoved(file)
        var reachable = Set<Int>()
        var queue: [Int] = []
        func collect(_ o: PDFObject) {
            switch o {
            case .ref(let n, _): if !reachable.contains(n), file.offsets[n] != nil { reachable.insert(n); queue.append(n) }
            case .array(let a): a.forEach(collect)
            case .dict(let pairs): pairs.forEach { collect($0.1) }
            default: break
            }
        }
        collect(file.trailer.removing("Prev").removing("XRefStm"))
        var spans: [Int: Range<Int>] = [:]
        while let n = queue.popLast() {
            guard let entry = file.offsets[n] else { continue }
            var lexer = PDFLexer(bytes: bytes, pos: entry.offset)
            // PDFKit lists objects it did not write with offset 0: those stay missing (null).
            guard entry.offset > 0, lexer.word() == "\(n)", Int(lexer.word()) != nil else { continue }
            guard (try? lexer.expect("obj")) != nil, let value = try? lexer.parse() else { return nil }
            if let o = overrides[n] { collect(o); spans[n] = 0..<0; continue }
            collect(value)
            lexer.skipWhitespace()
            var end = lexer.pos
            if lexer.peek("stream") {
                var start = lexer.pos + 6
                if start < bytes.count, bytes[start] == 0x0D { start += 1 }
                if start < bytes.count, bytes[start] == 0x0A { start += 1 }
                var length: Int?
                switch value["Length"] {
                case .raw(let s)?: length = Int(s)
                case .ref(let ln, _)?: length = (try? file.object(ln))?.int
                default: break
                }
                var found: Int?
                if let length, start + length <= bytes.count {
                    var l = PDFLexer(bytes: bytes, pos: start + length)
                    l.skipWhitespace()
                    if l.peek("endstream") { found = l.pos }
                }
                guard let streamEnd = found ?? AcroFormFixer.find("endstream", in: bytes, from: start) else { return nil }
                end = streamEnd + 9
            }
            guard let objEnd = AcroFormFixer.find("endobj", in: bytes, from: end) else { return nil }
            spans[n] = entry.offset..<(objEnd + 6)
        }
        guard let size = file.trailer["Size"]?.int else { return nil }
        var header = Array("%PDF-1.7".utf8)
        if bytes.starts(with: Array("%PDF-".utf8)), let eol = bytes.prefix(32).firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            header = Array(bytes[0..<eol])
        }
        var out = header + [0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        var offsets: [Int: Int] = [:]
        for n in spans.keys.sorted() {
            offsets[n] = out.count
            if let o = overrides[n] {
                out += Array("\(n) \(file.gen(n)) obj\n\(o.serialized)\nendobj\n".utf8)
            } else {
                out += bytes[spans[n]!]
                out.append(0x0A)
            }
        }
        let count = max(size, (spans.keys.max() ?? 0) + 1)
        let xrefOffset = out.count
        var xref = "xref\n0 \(count)\n"
        // Free entries form a list through the unused numbers.
        let free = (1..<count).filter { offsets[$0] == nil }
        var nextFree: [Int: Int] = [:]
        for (k, n) in free.enumerated() { nextFree[n] = k + 1 < free.count ? free[k + 1] : 0 }
        xref += String(format: "%010d 65535 f\r\n", free.first ?? 0)
        for n in 1..<count {
            if let o = offsets[n] {
                xref += String(format: "%010d %05d n\r\n", o, file.gen(n))
            } else {
                xref += String(format: "%010d 00001 f\r\n", nextFree[n] ?? 0)
            }
        }
        let trailer = file.trailer.removing("Prev").removing("XRefStm").setting("Size", .raw("\(count)"))
        xref += "trailer\n\(trailer.serialized)\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(xref.utf8)
        return Data(out)
    }

    /// Catalog or /AcroForm object rewritten without fields that have no widget on a page.
    private static func orphanFieldsRemoved(_ file: PDFFileStructure) -> [Int: PDFObject] {
        guard case .ref(let root, _)? = file.trailer["Root"], let catalog = try? file.object(root), catalog["AcroForm"] != nil else { return [:] }
        var formNum: Int?
        var form: PDFObject
        if case .ref(let n, _)? = catalog["AcroForm"] {
            guard let f = try? file.object(n) else { return [:] }
            formNum = n; form = f
        } else { form = catalog["AcroForm"]! }
        guard let fields = ((try? file.resolve(form["Fields"])) ?? nil)?.items, !fields.isEmpty else { return [:] }
        // Widgets on pages.
        var onPages = Set<Int>()
        var seen = Set<Int>()
        func walk(_ num: Int, _ depth: Int) {
            guard depth < 64, !seen.contains(num), let node = try? file.object(num) else { return }
            seen.insert(num)
            for case .ref(let a, _) in ((try? file.resolve(node["Annots"])) ?? nil)?.items ?? [] { onPages.insert(a) }
            for case .ref(let k, _) in ((try? file.resolve(node["Kids"])) ?? nil)?.items ?? [] { walk(k, depth + 1) }
        }
        if case .ref(let pages, _)? = catalog["Pages"] { walk(pages, 0) }
        func hasWidget(_ num: Int, _ depth: Int) -> Bool {
            guard depth < 32, let f = try? file.object(num) else { return false }
            if onPages.contains(num) { return true }
            let kids = ((try? file.resolve(f["Kids"])) ?? nil)?.items ?? []
            if kids.isEmpty { return f["Subtype"]?.nameValue != "Widget" && f["FT"] == nil }   // not a widget: keep
            return kids.contains { if case .ref(let k, _) = $0 { return hasWidget(k, depth + 1) } else { return true } }
        }
        let kept = fields.filter { if case .ref(let n, _) = $0 { return hasWidget(n, 0) } else { return true } }
        guard kept.count != fields.count else { return [:] }
        form = form.setting("Fields", .array(kept))
        if let formNum { return [formNum: form] }
        return [root: catalog.setting("AcroForm", form)]
    }
}
