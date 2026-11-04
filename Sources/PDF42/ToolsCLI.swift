import AppKit
import PDFKit

/// Headless modes for the page tools (testing without the UI):
///   PDF42 --watermark in.pdf out.pdf "TEXT" [pages]      PDF42 --number-pages in.pdf out.pdf [format 0|1|2] [position 0…5] [skip-first]
///   PDF42 --split in.pdf outdir 1-2,3 | every:N | each   PDF42 --merge out.pdf a.pdf b.png …
///   PDF42 --compare a.pdf b.pdf [marked.pdf]                      PDF42 --edit-text in.pdf out.pdf "old" "new"
///   PDF42 --redact in.pdf out.pdf x,y,w,h[@page] … [white]   (page space, pages from 1; prints what was removed)
///   PDF42 --add-field in.pdf out.pdf                     PDF42 --fill in.pdf out.pdf name=value …     PDF42 --fields file.pdf
enum ToolsCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 3 else { return nil }
        let a = Array(args.dropFirst(2))
        func open(_ path: String) -> PDFDocument {
            guard let d = PDFDocument(url: URL(fileURLWithPath: path)) else { fail("cannot open \(path)") }
            return d
        }
        func save(_ pdf: PDFDocument, _ path: String) {
            guard let baked = PageOverlay.bake(pdf) else { fail("cannot write") }
            do { try AcroFormFixer.ensureFields(baked.data).write(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
            baked.report.lines.forEach { print($0) }
        }
        switch args[1] {
        case "--watermark" where a.count >= 3:
            let pdf = open(a[0])
            var spec = WatermarkSpec()
            spec.text = a[2]
            let pages = PDFTools.pageIndices(a.count > 3 ? a[3] : "", pageCount: pdf.pageCount) ?? []
            for i in pages { if let p = pdf.page(at: i) { p.addAnnotation(WatermarkOverlay(spec: spec, page: p)) } }
            save(pdf, a[1])
            print("watermarked \(pages.count) pages")
        case "--number-pages" where a.count >= 2:
            let pdf = open(a[0])
            var spec = PageNumberSpec()
            if a.count > 2, let f = Int(a[2]).flatMap(PageNumberSpec.Format.init) { spec.format = f }
            if a.count > 3, let p = Int(a[3]).flatMap(PageNumberSpec.Position.init) { spec.position = p }
            spec.skipFirst = a.contains("skip-first")
            let labels = spec.labels(for: Array(0..<pdf.pageCount))
            for (i, text) in labels { if let p = pdf.page(at: i) { p.addAnnotation(PageNumberOverlay(text: text, spec: spec, page: p)) } }
            save(pdf, a[1])
            print("numbered \(labels.count) pages")
        case "--split" where a.count >= 3:
            let pdf = open(a[0])
            let mode = a[2]
            let groups: [[Int]]?
            if mode == "each" { groups = PDFTools.everyN(1, pageCount: pdf.pageCount) }
            else if mode.hasPrefix("every:") { groups = Int(mode.dropFirst(6)).map { PDFTools.everyN($0, pageCount: pdf.pageCount) } }
            else { groups = PDFTools.parseRanges(mode, pageCount: pdf.pageCount) }
            guard let groups else { fail("bad ranges \(mode)") }
            let dir = URL(fileURLWithPath: a[1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = URL(fileURLWithPath: a[0]).deletingPathExtension().lastPathComponent
            for (group, part) in zip(groups, PDFTools.split(PageOverlay.bakedDocument(pdf), groups: groups)) {
                let url = dir.appendingPathComponent(PDFTools.partName(base, group))
                part.write(to: url)
                print("\(url.lastPathComponent): \(part.pageCount) pages")
            }
        case "--merge" where a.count >= 2:
            let out = PDFTools.merge(a.dropFirst().map { URL(fileURLWithPath: $0) })
            out.write(to: URL(fileURLWithPath: a[0]))
            print("pages: \(out.pageCount)")
        case "--compare" where a.count >= 2:
            let base = open(a[0])
            let changes = PDFTools.compare(base, open(a[1]))
            if a.count > 2 {   // also write the base document with the changes highlighted
                EditorWindowController.addCompareHighlights(changes, to: base)
                base.write(to: URL(fileURLWithPath: a[2]))
            }
            for c in changes {
                print("p\(c.page + 1): -[\(c.removed.map(\.text).joined(separator: " "))] +[\(c.added.joined(separator: " "))]")
            }
            print("changes: \(changes.count)")
        case "--edit-text" where a.count >= 4:
            let pdf = open(a[0])
            guard let hit = pdf.findString(a[2], withOptions: []).first, let page = hit.pages.first else { fail("text not found: \(a[2])") }
            page.addAnnotation(EditedTextOverlay.make(replacing: hit, on: page, with: a[3]))
            save(pdf, a[1])
            print("edited on page \(pdf.index(for: page) + 1)")
        case "--redact" where a.count >= 3:
            let pdf = open(a[0])
            let white = a.contains("white")
            var marks = 0
            for spec in a.dropFirst(2) where spec != "white" {
                let parts = spec.split(separator: "@")
                let n = parts[0].split(separator: ",").compactMap { Double($0) }
                let pageIndex = parts.count > 1 ? (Int(parts[1]) ?? 1) - 1 : 0
                guard n.count == 4, let page = pdf.page(at: pageIndex) else { fail("bad area \(spec) (x,y,w,h[@page])") }
                page.addAnnotation(RedactOverlay(bounds: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), color: white ? .white : .black))
                marks += 1
            }
            save(pdf, a[1])
            print("redactions: \(marks)")
        case "--add-field" where a.count >= 2:
            let pdf = open(a[0])
            guard let page = pdf.page(at: 0) else { fail("no pages") }
            let box = page.bounds(for: .cropBox)
            let top = box.maxY - 120
            page.addAnnotation(PDFTools.makeField(.text, name: "Name", bounds: CGRect(x: 72, y: top, width: 220, height: 22)))
            page.addAnnotation(PDFTools.makeField(.checkBox, name: "Agree", bounds: CGRect(x: 72, y: top - 40, width: 14, height: 14)))
            page.addAnnotation(PDFTools.makeField(.choice, name: "Colour", bounds: CGRect(x: 72, y: top - 80, width: 160, height: 22),
                                                  options: ["Red", "Green", "Blue"]))
            save(pdf, a[1])
            print("fields: \(PDFTools.fields(pdf).count)")
        case "--fill" where a.count >= 3:
            let pdf = open(a[0])
            for pair in a.dropFirst(2) {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                for (_, f) in PDFTools.fields(pdf) where f.fieldName == kv[0] { PDFTools.setValue(kv[1], of: f) }
            }
            save(pdf, a[1])
            print("filled")
        case "--fields":
            for (i, f) in PDFTools.fields(open(a[0])) {
                print("p\(i + 1) \(f.fieldName ?? "?") type=\(f.widgetFieldType.rawValue) value=\(PDFTools.value(of: f)) choices=\(f.choices ?? [])")
            }
        default:
            return nil
        }
        return 0
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
