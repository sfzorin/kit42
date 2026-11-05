import AppKit
import Kit42
import PDFKit

/// `PDF42 --mark-overlay DIR`: shows how a stamp and a signature sit on a page of text. Writes `overlay-ink.pdf`
/// (saved with multiply, then reopened) and PNG renders of the reopened page for multiply and normal blending,
/// and with the signature placed under the stamp, to show that ink order hardly matters.
enum MarkOverlayDemo {
    static func write(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let template = SealTemplate.named("ru.ooo") else { return }
        let stamp = SealGenerator.render(SealSpec(template: template, values: [:], ink: InkColor.violet.stampPad, designSeed: 1),
                                         impression: 2024)!
        let signature = SignatureGenerator.render("Иван Иванов", design: SignatureGenerator.design(form: .fullName, variant: 1, seed: 77), impression: 11,
                                                  ink: InkColor.blue.pen)!
        for (name, blend, signatureFirst) in [("overlay-ink", CGBlendMode.multiply, false), ("overlay-normal", .normal, false),
                                               ("overlay-ink-signature-under", .multiply, true)] {
            let doc = PDFDocument(data: textPage())!
            let page = doc.page(at: 0)!
            let s = ImageStampAnnotation(image: stamp, bounds: CGRect(x: 300, y: 190, width: 150, height: 150 * CGFloat(stamp.height) / CGFloat(stamp.width)))
            let g = ImageStampAnnotation(image: signature, bounds: CGRect(x: 250, y: 238, width: 170, height: 170 * CGFloat(signature.height) / CGFloat(signature.width)))
            s.blendMode = blend
            g.blendMode = blend
            for a in signatureFirst ? [g, s] : [s, g] { page.addAnnotation(a) }
            // Save and reopen: the result is what other viewers get from the appearance streams.
            let url = folder.appendingPathComponent(name + ".pdf")
            guard let data = doc.dataRepresentation() else { continue }
            try data.write(to: url)
            guard let reopenedDoc = PDFDocument(url: url), let reopened = reopenedDoc.page(at: 0) else { continue }
            let box = reopened.bounds(for: .mediaBox)
            let scale: CGFloat = 3
            let image = NSImage(size: NSSize(width: box.width * scale, height: 300 * scale), flipped: false) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: 300 * scale))
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: 0, y: -100)
                reopened.draw(with: .mediaBox, to: ctx)
                _ = reopenedDoc
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        print("Mark overlay demo written")
    }

    /// One A4 page with the end of a letter: text lines and the signature block.
    private static func textPage() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let body = NSFont(name: "Helvetica Neue", size: 12)!
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont = body) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        text("Настоящим подтверждаем получение оплаты по договору № 15/2026 от 1 октября 2026 г.", 60, 330)
        text("Претензий по срокам и качеству оказанных услуг стороны друг к другу не имеют.", 60, 312)
        text("Генеральный директор", 60, 270)
        text("ООО «РОМАШКА»", 60, 254)
        text("_______________________  И. И. Иванов", 260, 262)
        text("М. П.", 300, 226)
        text("5 ноября 2026 г.", 60, 200)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
