import AppKit
import Kit42
import PDFKit

/// File › Export As › PDF/A-2b: an archival copy. Fonts get embedded (pages with fonts that are not
/// are redrawn by Quartz, which embeds the fonts it draws with; failing that their annotations are
/// flattened, and as a last resort the page becomes an image with recognised text), an sRGB output
/// intent and XMP identification are added, and what PDF/A forbids goes: encryption, JavaScript and
/// other actions, attachments, hidden or unprintable annotations, image interpolation.
enum PDFAExport {
    struct Report {
        var redrawn: [Int] = []
        var flattened: [Int] = []
        var rasterized: [Int] = []
        var removedAttachments = 0
        var removedAnnotations = 0
        var removedActions = 0
        var fixedImages = 0
        var unembedded: [String] = []

        var lines: [String] {
            var out: [String] = []
            if !redrawn.isEmpty { out.append("redrawn to embed fonts: pages \(PDFTools.describeRanges(redrawn))") }
            if !flattened.isEmpty { out.append("annotations flattened: pages \(PDFTools.describeRanges(flattened))") }
            if !rasterized.isEmpty { out.append("rasterized with OCR text: pages \(PDFTools.describeRanges(rasterized))") }
            if removedAttachments > 0 { out.append("attachments removed: \(removedAttachments)") }
            if removedAnnotations > 0 { out.append("annotations removed: \(removedAnnotations)") }
            if removedActions > 0 { out.append("actions removed: \(removedActions)") }
            if fixedImages > 0 { out.append("image interpolation turned off: \(fixedImages)") }
            if !unembedded.isEmpty { out.append("fonts still not embedded: \(unembedded.joined(separator: ", "))") }
            return out
        }
    }

    static func make(_ pdf: PDFDocument, extras: DocumentExtras) -> (data: Data, report: Report)? {
        guard let baked = PageOverlay.bake(pdf) else { return nil }
        var data = AcroFormFixer.ensureFields(baked.data)
        guard let work = PDFDocument(data: data) else { return nil }
        var report = Report()
        report.removedAttachments = extras.files.count

        func badPages(_ data: Data) -> [Int: [String]] {
            var out: [Int: [String]] = [:]
            for (i, fonts) in FontScanner.scan(data) {
                let bad = fonts.filter { !$0.embedded }.map(\.name)
                if !bad.isEmpty { out[i] = bad }
            }
            return out
        }
        // 1. Redraw pages whose fonts are not embedded.
        var bad = badPages(data)
        if !bad.isEmpty {
            var replacements: [(Int, PDFPage)] = []
            for i in bad.keys.sorted() {
                guard let page = work.page(at: i), let new = PageOverlay.redraw(page, overlay: { _ in }) else { continue }
                replacements.append((i, new))
                report.redrawn.append(i)
            }
            PageOverlay.replace(replacements, in: work)
            if let d = work.dataRepresentation() { data = AcroFormFixer.ensureFields(d) }
            bad = badPages(data)
        }
        // 2. Still: the annotations (form fields, text boxes) use such fonts — draw them into the page.
        if !bad.isEmpty {
            var replacements: [(Int, PDFPage)] = []
            for i in bad.keys.sorted() {
                guard let page = work.page(at: i), let new = flattened(page) else { continue }
                replacements.append((i, new))
                report.flattened.append(i)
            }
            PageOverlay.replace(replacements, in: work)
            if let d = work.dataRepresentation() { data = AcroFormFixer.ensureFields(d) }
            bad = badPages(data)
        }
        // 3. Last resort: an image of the page with an invisible OCR text layer.
        if !bad.isEmpty {
            var replacements: [(Int, PDFPage)] = []
            for i in bad.keys.sorted() {
                guard let page = work.page(at: i), let new = RedactionRaster.page(page, areas: [], overlay: { _ in }) else { continue }
                new.annotations.filter { !$0.isKind(.link) }.forEach { new.removeAnnotation($0) }
                replacements.append((i, new))
                report.rasterized.append(i)
            }
            PageOverlay.replace(replacements, in: work)
            if let d = work.dataRepresentation() { data = d }
            bad = badPages(data)
        }
        report.unembedded = Array(Set(bad.values.flatMap { $0 })).sorted()

        // Everything document-level is written from the model: the redrawn pages came through PDFKit again.
        var x = extras
        x.dirty.formUnion([.outline, .labels, .view, .info, .files])
        guard let w = Writer(data) else { return nil }
        // The live document is the model for outline and links: same pages, same order.
        w.write(extras: x, pdf: pdf, pdfa: true)
        w.applyPDFA(&report)
        let out = w.finish(data)
        guard let compact = PDFCompactor.compact(out) else { return nil }
        return (compact, report)
    }

    /// The page redrawn with its annotations (except links) drawn into the content.
    static func flattened(_ page: PDFPage) -> PDFPage? {
        let media = page.bounds(for: .mediaBox), crop = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let links = page.annotations.filter { $0.isKind(.link) }
        let popups = page.annotations.filter { $0.isKind(.popup) }
        (links + popups).forEach { page.removeAnnotation($0) }
        page.rotation = 0
        defer {
            page.rotation = rotation
            (links + popups).forEach { page.addAnnotation($0) }
        }
        let data = NSMutableData()
        var box = media
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let new = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        new.setBounds(crop, for: .cropBox)
        new.rotation = rotation
        for l in links { if let c = l.copy() as? PDFAnnotation { new.addAnnotation(c) } }
        return new
    }

    /// sRGB ICC profile for the output intent.
    static var sRGBProfile: Data? { CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? }
}

extension Writer {
    /// PDF/A-2 requirements on the catalog, pages, annotations and images.
    func applyPDFA(_ report: inout PDFAExport.Report) {
        // Output intent (sRGB).
        if let icc = PDFAExport.sRGBProfile {
            let profile = addStream(.dict([("N", .raw("3"))]), [UInt8](icc))
            let intent = PDFObject.dict([
                ("Type", .name("OutputIntent")), ("S", .name("GTS_PDFA1")),
                ("OutputConditionIdentifier", .raw("(sRGB IEC61966-2.1)")), ("RegistryName", .raw("(http://www.color.org)")),
                ("Info", .raw("(sRGB IEC61966-2.1)")), ("DestOutputProfile", .ref(profile, 0)),
            ])
            catalog = catalog.setting("OutputIntents", .array([intent]))
        }
        // No JavaScript or automatic actions.
        catalog = catalog.removing("AA").removing("Perms").removing("Requirements")
        if let open = resolve(catalog["OpenAction"]), open.items == nil, !Self.allowedAction(open) {
            catalog = catalog.removing("OpenAction")
            report.removedActions += 1
        }
        changeNames { $0.removing("JavaScript").removing("EmbeddedFiles") }
        if let formRef = catalog["AcroForm"] {
            var form = resolve(formRef) ?? .dict([])
            form = form.removing("NeedAppearances").removing("XFA")
            if case .ref(let n, _) = formRef { set(n, form) } else { catalog = catalog.setting("AcroForm", form) }
        }
        if case .dict(let pairs) = catalog, let v = pairs.first(where: { $0.0 == "Version" })?.1.nameValue, v > "1.7" { catalog = catalog.removing("Version") }

        let forbiddenAnnots: Set<String> = ["FileAttachment", "Sound", "Movie", "Screen", "3D", "RichMedia"]
        for pageNum in pages {
            guard var page = current(pageNum) else { continue }
            var pageChanged = false
            if page["AA"] != nil { page = page.removing("AA"); pageChanged = true }
            if let annotsObj = page["Annots"], let annots = resolve(annotsObj)?.items {
                var kept: [PDFObject] = []
                for entry in annots {
                    guard case .ref(let num, _) = entry, var a = current(num) else { kept.append(entry); continue }
                    let subtype = a["Subtype"]?.nameValue ?? ""
                    if forbiddenAnnots.contains(subtype) { report.removedAnnotations += 1; continue }
                    var changedAnnot = false
                    // Printable, not hidden; notes don't zoom or rotate.
                    var flags = a["F"]?.int ?? 0
                    let wanted = (flags | 4) & ~(1 | 2 | 32 | 256) | (subtype == "Text" ? 8 | 16 : 0)
                    if subtype != "Popup", wanted != flags { flags = wanted; a = a.setting("F", .raw("\(flags)")); changedAnnot = true }
                    if a["AA"] != nil { a = a.removing("AA"); changedAnnot = true }
                    if let act = resolve(a["A"]), !Self.allowedAction(act) { a = a.removing("A"); report.removedActions += 1; changedAnnot = true }
                    if let ap = resolve(a["AP"]), case .dict(let pairs) = ap, pairs.contains(where: { $0.0 != "N" }) {
                        a = a.setting("AP", .dict(pairs.filter { $0.0 == "N" }))
                        changedAnnot = true
                    }
                    // Annotations without an appearance (other than links and popups) are not allowed.
                    if a["AP"] == nil, !["Link", "Popup"].contains(subtype) { report.removedAnnotations += 1; continue }
                    if changedAnnot { set(num, a) }
                    kept.append(entry)
                }
                if kept.count != annots.count {
                    page = page.setting("Annots", .array(kept))
                    pageChanged = true
                }
            }
            if pageChanged { set(pageNum, page) }
        }
        // Images: /Interpolate true is not allowed.
        for num in file.offsets.keys.sorted() where updates[num] == nil {
            guard let o = object(num), o["Subtype"]?.nameValue == "Image", o["Interpolate"]?.rawString == "true" else { continue }
            setStreamDict(num) { $0.setting("Interpolate", .raw("false")) }
            report.fixedImages += 1
        }
        // A file identifier is required.
        if trailer["ID"] == nil {
            let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            trailer = trailer.setting("ID", .array([.raw("<\(hex)>"), .raw("<\(hex)>")]))
        }
        trailer = trailer.removing("Encrypt")
        changed = true
    }

    /// Actions PDF/A-2 allows.
    static func allowedAction(_ a: PDFObject) -> Bool {
        guard let s = a["S"]?.nameValue else { return true }
        guard ["GoTo", "GoToR", "GoToE", "URI", "Named", "Thread", "SubmitForm"].contains(s) else { return false }
        if s == "Named", let n = a["N"]?.nameValue { return ["NextPage", "PrevPage", "FirstPage", "LastPage"].contains(n) }
        return true
    }
}

extension EditorWindowController {
    @objc func exportPDFAAction(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = pdfDoc?.fileURL?.deletingPathExtension().lastPathComponent ?? pdfDoc?.displayName ?? L("Document")
        panel.nameFieldStringValue = L("%@ (PDF-A).pdf", base)
        panel.message = L("PDF/A-2b: fonts embedded, colours defined, no attachments or scripts")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.exportPDFA(to: url)
        }
    }

    func exportPDFA(to url: URL) {
        guard let pdf, let doc = pdfDoc else { return }
        prepareForSave()
        guard let (data, report) = PDFAExport.make(pdf, extras: doc.extras) else {
            presentError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
            return
        }
        do { try data.write(to: url) } catch { presentError(error); return }
        var notes: [String] = []
        if !report.redrawn.isEmpty || !report.flattened.isEmpty { notes.append(L("Pages redrawn to embed fonts: %@.", PDFTools.describeRanges(report.redrawn + report.flattened))) }
        if !report.rasterized.isEmpty { notes.append(L("Pages turned into images with recognised text: %@.", PDFTools.describeRanges(report.rasterized))) }
        if report.removedAttachments > 0 { notes.append(L("Attachments removed: %d.", report.removedAttachments)) }
        if report.removedAnnotations + report.removedActions > 0 { notes.append(L("Annotations or actions not allowed in PDF/A removed: %d.", report.removedAnnotations + report.removedActions)) }
        if !report.unembedded.isEmpty { notes.append(L("Fonts that could not be embedded: %@.", report.unembedded.joined(separator: ", "))) }
        banner.show(report.unembedded.isEmpty ? .success : .warning, L("Saved as PDF/A-2b") + (notes.isEmpty ? "" : " · " + notes.joined(separator: " ")),
                    action: L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
