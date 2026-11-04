import AppKit

/// Writes an attributed string as .docx. Replaces the system writer, which drops tables.
/// Covers paragraphs, runs (font, size, bold/italic/underline/strike, colour, highlight),
/// alignment, spacing, indents, tabs, page breaks, tables (NSTextTable) and images.
public enum DocxWriter {
    public static func data(_ text: NSAttributedString, pageSize: NSSize = NSSize(width: 595, height: 842)) -> Data {
        var media: [(name: String, data: Data)] = []
        var body = ""
        let ns = text.string as NSString

        // Paragraph ranges
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            paragraphs.append(r)
        }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: 0, length: 0)] }

        func style(at r: NSRange) -> NSParagraphStyle? {
            guard text.length > 0 else { return nil }
            return text.attribute(.paragraphStyle, at: min(r.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle
        }

        var i = 0
        while i < paragraphs.count {
            let r = paragraphs[i]
            if let block = style(at: r)?.textBlocks.last as? NSTextTableBlock {
                // Collect the whole table
                let table = block.table
                var cells: [[Int: [NSRange]]] = []   // row → col → paragraphs
                var columns = table.numberOfColumns
                while i < paragraphs.count, let b = style(at: paragraphs[i])?.textBlocks.last as? NSTextTableBlock, b.table === table {
                    while cells.count <= b.startingRow { cells.append([:]) }
                    cells[b.startingRow][b.startingColumn, default: []].append(paragraphs[i])
                    columns = max(columns, b.startingColumn + b.columnSpan)
                    i += 1
                }
                body += tableXML(cells, columns: columns, text: text, media: &media, border: block)
                continue
            }
            body += paragraphXML(r, text: text, media: &media)
            i += 1
        }

        let twip = { (pt: CGFloat) in Int((pt * 20).rounded()) }
        body += """
        <w:sectPr><w:pgSz w:w="\(twip(pageSize.width))" w:h="\(twip(pageSize.height))"/>\
        <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="709" w:footer="709" w:gutter="0"/></w:sectPr>
        """

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """

        var zip = ZipArchive()
        zip["[Content_Types].xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """.utf8)
        zip["_rels/.rels"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """.utf8)
        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for (n, m) in media.enumerated() {
            rels += "<Relationship Id=\"rIdImg\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(m.name)\"/>"
            zip["word/media/\(m.name)"] = m.data
        }
        rels += "</Relationships>"
        zip["word/_rels/document.xml.rels"] = Data(rels.utf8)
        zip["word/styles.xml"] = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:cs="Helvetica Neue" w:eastAsia="Helvetica Neue"/>\
        <w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblCellMar>\
        <w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
        </w:styles>
        """.utf8)
        zip["word/document.xml"] = Data(document.utf8)
        return zip.data()
    }

    // MARK: - Paragraphs

    private static func paragraphXML(_ r: NSRange, text: NSAttributedString, media: inout [(name: String, data: Data)]) -> String {
        var x = "<w:p>"
        if text.length > 0 {
            let p = text.attribute(.paragraphStyle, at: min(r.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle
            x += paragraphProperties(p)
        }
        guard r.length > 0 else { return x + "</w:p>" }
        text.enumerateAttributes(in: r) { attrs, run, _ in
            let s = (text.string as NSString).substring(with: run)
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                x += imageXML(attachment, media: &media)
                return
            }
            x += runXML(s, attrs)
        }
        return x + "</w:p>"
    }

    private static func paragraphProperties(_ p: NSParagraphStyle?) -> String {
        guard let p else { return "" }
        var x = "<w:pPr>"
        let twip = { (pt: CGFloat) in Int((pt * 20).rounded()) }
        let line = p.lineHeightMultiple > 0 ? Int((p.lineHeightMultiple * 240).rounded()) : 240
        x += "<w:spacing w:before=\"\(twip(p.paragraphSpacingBefore))\" w:after=\"\(twip(p.paragraphSpacing))\" w:line=\"\(line)\" w:lineRule=\"auto\"/>"
        if p.headIndent > 0 || p.firstLineHeadIndent > 0 {
            let left = twip(p.headIndent)
            let first = twip(p.firstLineHeadIndent) - left
            x += "<w:ind w:left=\"\(left)\"" + (first < 0 ? " w:hanging=\"\(-first)\"" : first > 0 ? " w:firstLine=\"\(first)\"" : "") + "/>"
        }
        switch p.alignment {
        case .center: x += "<w:jc w:val=\"center\"/>"
        case .right: x += "<w:jc w:val=\"right\"/>"
        case .justified: x += "<w:jc w:val=\"both\"/>"
        default: break
        }
        return x + "</w:pPr>"
    }

    private static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private static func runXML(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> String {
        var pr = ""
        if let font = attrs[.font] as? NSFont {
            let family = xmlEscape(font.familyName ?? font.fontName)
            pr += "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:cs=\"\(family)\" w:eastAsia=\"\(family)\"/>"
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { pr += "<w:b/><w:bCs/>" }
            if traits.contains(.italicFontMask) { pr += "<w:i/><w:iCs/>" }
        }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { pr += "<w:strike/>" }
        if let c = attrs[.foregroundColor] as? NSColor { pr += "<w:color w:val=\"\(hex(c))\"/>" }
        if let font = attrs[.font] as? NSFont {
            let half = Int((font.pointSize * 2).rounded())
            pr += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        }
        if (attrs[.underlineStyle] as? Int ?? 0) != 0 { pr += "<w:u w:val=\"single\"/>" }
        if let bg = attrs[.backgroundColor] as? NSColor { pr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(hex(bg))\"/>" }
        if let sup = attrs[.superscript] as? Int, sup != 0 { pr += "<w:vertAlign w:val=\"\(sup > 0 ? "superscript" : "subscript")\"/>" }

        var x = ""
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            x += "<w:r>\(pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>")<w:t xml:space=\"preserve\">\(xmlEscape(chunk))</w:t></w:r>"
            chunk = ""
        }
        func special(_ xml: String) {
            flush()
            x += "<w:r>\(pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>")\(xml)</w:r>"
        }
        for ch in s {
            switch ch {
            case "\t": special("<w:tab/>")
            case "\u{2028}": special("<w:br/>")
            case "\u{000C}": special("<w:br w:type=\"page\"/>")
            case "\n", "\r", "\u{2029}": break
            default: chunk.append(ch)
            }
        }
        flush()
        return x
    }

    // MARK: - Images

    private static func imageXML(_ attachment: NSTextAttachment, media: inout [(name: String, data: Data)]) -> String {
        var image = attachment.image
        if image == nil, let data = attachment.fileWrapper?.regularFileContents { image = NSImage(data: data) }
        guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return "" }
        media.append((name: "image\(media.count + 1).png", data: png))
        let n = media.count
        var size = attachment.bounds.size
        if size.width <= 0 || size.height <= 0 { size = image.size }
        let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(n)" name="Image \(n)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(n)" name="image\(n).png"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdImg\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    // MARK: - Tables

    private static func tableXML(_ rows: [[Int: [NSRange]]], columns: Int, text: NSAttributedString,
                                 media: inout [(name: String, data: Data)], border: NSTextTableBlock) -> String {
        let color = hex(border.borderColor(for: .minX) ?? .gray)
        let width = border.width(for: .border, edge: .minX)
        let sz = max(2, Int((width * 8).rounded()))
        let edges = ["top", "left", "bottom", "right", "insideH", "insideV"]
            .map { "<w:\($0) w:val=\"\(width > 0 ? "single" : "nil")\" w:sz=\"\(sz)\" w:space=\"0\" w:color=\"\(color)\"/>" }.joined()
        var x = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>\(edges)</w:tblBorders>"
        x += "<w:tblLayout w:type=\"autofit\"/></w:tblPr><w:tblGrid>"
        for _ in 0..<columns { x += "<w:gridCol w:w=\"\(9000 / max(1, columns))\"/>" }
        x += "</w:tblGrid>"
        for row in rows {
            x += "<w:tr>"
            var c = 0
            while c < columns {
                let paragraphs = row[c] ?? []
                var span = 1
                if let first = paragraphs.first,
                   let b = (text.attribute(.paragraphStyle, at: first.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock {
                    span = max(1, b.columnSpan)
                }
                x += "<w:tc><w:tcPr><w:tcW w:w=\"\(5000 * span / max(1, columns))\" w:type=\"pct\"/>\(span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")</w:tcPr>"
                if paragraphs.isEmpty { x += "<w:p/>" }
                for p in paragraphs { x += paragraphXML(p, text: text, media: &media) }
                x += "</w:tc>"
                c += span
            }
            x += "</w:tr>"
        }
        return x + "</w:tbl>"
    }
}
