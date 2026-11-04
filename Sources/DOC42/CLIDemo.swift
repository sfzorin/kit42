import AppKit
import Kit42

/// The Writer-like features in the --demo document and in --dump.
extension CLI {
    /// A picture for tests: a gradient with a label.
    static func demoImage(_ label: String, size: NSSize = NSSize(width: 160, height: 100), hue: CGFloat = 0.58) -> NSAttributedString {
        let image = NSImage(size: size, flipped: false) { r in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1), ending: NSColor(hue: hue, saturation: 0.9, brightness: 0.6, alpha: 1))?.draw(in: r, angle: 90)
            let s = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.white])
            s.draw(at: NSPoint(x: (r.width - s.size().width) / 2, y: (r.height - s.size().height) / 2))
            return true
        }
        let a = NSTextAttachment()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let w = FileWrapper(regularFileWithContents: png)
            w.preferredFilename = "image.png"
            a.fileWrapper = w
            a.attachmentCell = ImageCell(imageCell: NSImage(data: png))
        }
        a.bounds = NSRect(origin: .zero, size: size)
        return NSAttributedString(attachment: a)
    }

    /// Styles, lists, outline numbering, fields, headers, tables, pictures, captions, borders, drop cap, effects.
    static func addWriterFeatures(_ doc: TextDocument) {
        let s = doc.storage
        let sheet = doc.styles
        let demoTitle = "Feature Test", demoAuthor = "Test Author"
        doc.docInfo = DocInfo(title: demoTitle, author: demoAuthor)
        doc.watermark = "DRAFT"
        doc.hyphenate = true
        // A custom paragraph style and a modified built-in one.
        var box = DocStyle(id: "NoteBox", name: "Note Box", kind: .paragraph, basedOn: "Normal", next: "Normal")
        box.color = NSColor(srgbRed: 0.1, green: 0.25, blue: 0.6, alpha: 1)
        box.italic = true
        box.spaceBefore = 6
        box.spaceAfter = 10
        sheet.replace(box)
        var quote = sheet["Quote"]!
        quote.size = 13
        sheet.replace(quote)
        func para(_ text: String, _ style: String = "Normal", _ extra: [NSAttributedString.Key: Any] = [:]) {
            let start = s.length
            s.append(NSAttributedString(string: text + "\n", attributes: sheet.attributes(style).merging(extra) { $1 }))
            sheet.apply(paragraphStyle: style, to: s, range: NSRange(location: start, length: s.length - start))
        }
        para("Writer Features", "Heading1")
        para("Styles", "Heading2")
        para("A paragraph in the custom Note Box style, with borders and a background.", "NoteBox")
        let boxed = NSTextBlock()
        for e in [NSRectEdge.minX, .minY, .maxX, .maxY] { boxed.setWidth(1, type: .absoluteValueType, for: .border, edge: e); boxed.setBorderColor(.systemBlue, for: e) }
        boxed.setWidth(5, type: .absoluteValueType, for: .padding)
        boxed.setValue(100, type: .percentageValueType, for: .width)
        boxed.backgroundColor = NSColor(srgbRed: 0.92, green: 0.95, blue: 1, alpha: 1)
        let ns0 = s.string as NSString
        let boxRange = ns0.paragraphRange(for: NSRange(location: s.length - 2, length: 0))
        s.enumerateAttribute(.paragraphStyle, in: boxRange) { v, r, _ in
            let p = (v as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            p.textBlocks = [boxed]
            s.addAttribute(.paragraphStyle, value: p, range: r)
        }
        para("A quotation in the modified Quote style.", "Quote")
        let mixed = NSMutableAttributedString(string: "Character styles: ", attributes: sheet.attributes("Normal"))
        for (id, text) in [("Emphasis", "emphasis"), ("Strong", "strong"), ("Code", "code()")] {
            let r = NSRange(location: mixed.length, length: (text as NSString).length)
            mixed.append(NSAttributedString(string: text, attributes: sheet.attributes("Normal")))
            sheet.apply(characterStyle: id, to: mixed, range: r)
            mixed.append(NSAttributedString(string: ", ", attributes: sheet.attributes("Normal")))
        }
        mixed.append(NSAttributedString(string: "and effects: ", attributes: sheet.attributes("Normal")))
        let base = sheet.attributes("Normal")
        func effect(_ t: String, _ a: [NSAttributedString.Key: Any]) { mixed.append(NSAttributedString(string: t, attributes: base.merging(a) { $1 })); mixed.append(NSAttributedString(string: " ", attributes: base)) }
        effect("All Caps", [.docAllCaps: true])
        effect("Small Caps", [.docSmallCaps: true])
        effect("double strike", [.strikethroughStyle: NSUnderlineStyle.double.rawValue])
        effect("double underline", [.underlineStyle: NSUnderlineStyle.double.rawValue])
        effect("dotted", [.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
        effect("x²", [.superscript: 1])
        effect("spaced", [.kern: 3])
        mixed.append(NSAttributedString(string: ".\n", attributes: base))
        s.append(mixed)
        let dropStart = s.length
        para("Drop caps make the first letter of a paragraph large: this paragraph starts with one that spans three lines, as in Writer and Word. " +
             "The text flows around the letter, and the letter is saved to .docx as Word's framed drop-cap paragraph.")
        s.addAttribute(.docDropCap, value: 3, range: NSRange(location: dropStart, length: 1))

        para("Lists", "Heading2")
        let bullets = NSTextList(markerFormat: .disc, options: 0), sub = NSTextList(markerFormat: .circle, options: 0)
        let numbers = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: "({lower-alpha})"), options: 0)
        let outline1 = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: "{decimal}."), options: 0)
        let outline2 = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: "{decimal}."), options: Int(NSTextList.Options.prependEnclosingMarker.rawValue))
        for (lists, text) in [([bullets], "First bullet"), ([bullets, sub], "Nested bullet"), ([bullets], "Second bullet"),
                              ([numbers], "Lettered item"), ([numbers], "Another lettered item"),
                              ([outline1], "Multi-level"), ([outline1, outline2], "Sub item"), ([outline1, outline2], "Sub item"), ([outline1], "Back to level one")] {
            let p = NSMutableParagraphStyle()
            p.textLists = lists
            ListNumbering.indent(p, level: lists.count - 1)
            p.paragraphSpacing = 2
            var a = sheet.attributes("ListParagraph")
            a[.paragraphStyle] = p
            s.append(NSAttributedString(string: text + "\n", attributes: a))
        }

        para("Fields", "Heading2")
        let f = NSMutableAttributedString(string: "Page ", attributes: base)
        f.append(Fields.reference(DocField(.page), attributes: base))
        f.append(NSAttributedString(string: " of ", attributes: base))
        f.append(Fields.reference(DocField(.pageCount), attributes: base))
        f.append(NSAttributedString(string: "; fixed date ", attributes: base))
        f.append(Fields.reference(DocField(.date, format: "dd.MM.yyyy", fixed: true, result: "01.02.2026"), attributes: base))
        f.append(NSAttributedString(string: "; title ", attributes: base))
        f.append(Fields.reference(DocField(.title), attributes: base))
        f.append(NSAttributedString(string: "; author ", attributes: base))
        f.append(Fields.reference(DocField(.author), attributes: base))
        f.append(NSAttributedString(string: "; chapter ", attributes: base))
        f.append(Fields.reference(DocField(.chapter, format: "1"), attributes: base))
        f.append(NSAttributedString(string: ".\n", attributes: base))
        s.append(f)

        para("Tables", "Heading2")
        var cellAttrs = base
        cellAttrs[.paragraphStyle] = NSMutableParagraphStyle()
        func cell(_ t: String, bold: Bool = false) -> TableModel.Cell {
            var a = cellAttrs
            if bold { a[.font] = NSFontManager.shared.convert(Styles.normal.font, toHaveTrait: .boldFontMask) }
            return TableModel.Cell(content: NSAttributedString(string: t + "\n", attributes: a), props: CellProps())
        }
        var m = TableModel(rows: [
            [cell("Item", bold: true), cell("Count", bold: true), cell("Price", bold: true)],
            [cell("Apples"), cell("3"), cell("1.50")],
            [cell("Pears"), cell("5"), cell("2.25")],
            [cell("Total", bold: true), cell(""), cell("")],
        ], widths: [50, 25, 25], headerRows: 1)
        m.rows[0][1]?.colSpan = 2
        m.rows[0][2] = nil
        m.rows[0][1]?.content = NSAttributedString(string: "Count and price\n", attributes: cellAttrs)
        for c in 0..<3 { m.rows[0][c]?.props.background = NSColor(srgbRed: 0.85, green: 0.9, blue: 1, alpha: 1) }
        m.rows[1][0]?.rowSpan = 2
        m.rows[2][0] = nil
        m.rows[1][0]?.content = NSAttributedString(string: "Fruit\n", attributes: cellAttrs)
        let table = NSMutableAttributedString(attributedString: m.render())
        // Sums under the numbers.
        let sumAt = (table.string as NSString).range(of: "\n", options: .backwards, range: NSRange(location: 0, length: table.length - 1)).location + 1
        table.insert(Fields.reference(DocField(.formula, argument: "SUM(ABOVE)"), attributes: table.attributes(at: sumAt, effectiveRange: nil)), at: sumAt)
        s.append(table)
        para("Pictures", "Heading2")
        let pic = NSMutableAttributedString(attributedString: demoImage("inline"))
        let border = DocImage()
        border.borderWidth = 2
        border.borderColor = .systemOrange
        pic.addAttribute(.docImage, value: border, range: NSRange(location: 0, length: 1))
        pic.addAttributes([.paragraphStyle: NSParagraphStyle.default], range: NSRange(location: 0, length: 1))
        s.append(pic)
        s.append(NSAttributedString(string: "\n", attributes: base))
        var cap = sheet.attributes("Caption")
        cap[Styles.styleKey] = "Caption"
        s.append(NSAttributedString(string: "Figure ", attributes: cap))
        s.append(Fields.reference(DocField(.sequence, argument: "Figure"), attributes: cap))
        s.append(NSAttributedString(string: ": an inline picture with a border\n", attributes: cap))
        let floatStart = s.length
        let floating = NSMutableAttributedString(attributedString: demoImage("float", size: NSSize(width: 120, height: 90), hue: 0.33))
        let square = DocImage()
        square.wrap = .square
        square.offset = CGPoint(x: 300, y: 250)
        floating.addAttribute(.docImage, value: square, range: NSRange(location: 0, length: 1))
        floating.addAttributes(base, range: NSRange(location: 0, length: 1))
        s.append(floating)
        para("A floating picture with square wrapping: the text flows around it on the page. " + String(repeating: "Text around the picture. ", count: 22))
        s.addAttributes([.paragraphStyle: s.attribute(.paragraphStyle, at: floatStart + 1, effectiveRange: nil)!], range: NSRange(location: floatStart, length: 1))

        // Outline numbering of the headings, rich header and footer, different first page.
        let hf = DocHeaderFooter()
        let width = doc.setup.textSize.width
        let left = HeaderFooter.attributes(width: width, alignment: .left)
        let h = NSMutableAttributedString(string: "Feature Test\t", attributes: left)
        h.append(Fields.reference(DocField(.chapter, format: "1"), attributes: left))
        h.append(NSAttributedString(string: "\tDOC42", attributes: left))
        hf.header = h
        let center = HeaderFooter.attributes(width: width)
        let ft = NSMutableAttributedString(string: "Page ", attributes: center)
        ft.append(Fields.reference(DocField(.page), attributes: center))
        ft.append(NSAttributedString(string: " of ", attributes: center))
        ft.append(Fields.reference(DocField(.pageCount), attributes: center))
        hf.footer = ft
        hf.differentFirst = true
        hf.firstFooter = NSAttributedString(string: "First page footer", attributes: center)
        doc.setup.hf = hf
        doc.setup.pageNumbers = false
        ListMarkers.insert(into: s)
    }

    /// Outline numbering of the demo's headings (after the table of contents is built).
    static func numberDemoHeadings(_ doc: TextDocument) {
        let s = doc.storage
        let ns = s.string as NSString
        let l1 = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: "{decimal}."), options: 0)
        let l2 = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: "{decimal}."), options: Int(NSTextList.Options.prependEnclosingMarker.rawValue))
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, _, r, _ in
            guard r.location < s.length, let id = s.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String, id == "Heading1" || id == "Heading2" else { return }
            s.enumerateAttribute(.paragraphStyle, in: r) { v, sub, _ in
                let p = ((v as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
                p.textLists = id == "Heading1" ? [l1] : [l1, l2]
                s.addAttribute(.paragraphStyle, value: p, range: sub)
            }
        }
        ListMarkers.insert(into: s)
    }

    static func dumpWriterFeatures(_ doc: TextDocument, _ pages: PagedView) {
        let s = doc.storage
        let ns = s.string as NSString
        let full = NSRange(location: 0, length: s.length)
        if !doc.docInfo.title.isEmpty || !doc.docInfo.author.isEmpty { print("info title=\"\(doc.docInfo.title)\" author=\"\(doc.docInfo.author)\"") }
        if let b = doc.background { print("background \(hex(b))") }
        if !doc.watermark.isEmpty { print("watermark \(doc.watermark)") }
        if doc.hyphenate { print("hyphenation on") }
        // Styles: custom ones and changed built-ins, with what they set.
        let builtinSheet = StyleSheet()
        func signature(_ r: DocStyle) -> String {
            "\(r.family ?? "-") \(r.size.map { "\(Int($0))" } ?? "-") \(r.isBold ?? false) \(r.italic ?? false) \(r.color.map(hex) ?? "-") \(r.spaceBefore.map { "\(Int($0))" } ?? "-") \(r.spaceAfter.map { "\(Int($0))" } ?? "-")"
        }
        for st in doc.styles.styles where builtinSheet[st.id] == nil || signature(builtinSheet.resolved(st.id)) != signature(doc.styles.resolved(st.id)) {
            let r = doc.styles.resolved(st.id)
            print("style \(st.id) \"\(st.name)\" \(st.kind.rawValue) basedOn=\(st.basedOn ?? "-") font=\(r.family ?? "-") \(r.size.map { "\(Int($0))" } ?? "-") bold=\(r.isBold ?? false) italic=\(r.italic ?? false) color=\(r.color.map(hex) ?? "-") before=\(r.spaceBefore.map { "\(Int($0))" } ?? "-") after=\(r.spaceAfter.map { "\(Int($0))" } ?? "-")")
        }
        var used: [String: Int] = [:]
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            let id = r.length > 0 ? (s.attribute(Styles.styleKey, at: r.location, effectiveRange: nil) as? String ?? "Normal") : "Normal"
            used[id, default: 0] += 1
        }
        print("paragraph styles " + used.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        s.enumerateAttribute(.docCharStyle, in: full) { v, r, _ in if let id = v as? String { print("char style \(id): \"\(ns.substring(with: r))\"") } }
        for m in ListNumbering.markers(s) {
            let text = ns.substring(with: m.range).replacingOccurrences(of: "\t", with: "→").trimmingCharacters(in: .newlines)
            print("list level \(m.level) \(m.marker): \(text.prefix(40))")
        }
        s.enumerateAttribute(.docField, in: full) { v, r, _ in
            if let f = v as? DocField { print("field\(f.instruction)= \"\(pages.fieldValue(f, at: r.location))\" page \(pages.pageNumber(at: r.location))\(f.fixed ? " fixed" : "")") }
        }
        var tableIndex = 0
        var i = 0
        while i < s.length {
            if let g = TableGrid(s, at: i), TableGrid.block(s, at: i) != nil {
                tableIndex += 1
                print("table \(tableIndex): \(g.rows)×\(g.columns) heading rows \((g.table as? DocTextTable)?.headerRows ?? 0)")
                for c in g.cells {
                    let b = c.block
                    let bg = b.backgroundColor.map { " bg " + hex($0) } ?? ""
                    let borders = CellProps.edges.map { Int((b.width(for: .border, edge: $0) * 4).rounded()) }.map(String.init).joined(separator: ",")
                    var text = c.text(in: s)
                    if let f = s.attribute(.docField, at: c.range.location, effectiveRange: nil) as? DocField { text = "=" + pages.fieldValue(f, at: c.range.location) }
                    print("  cell \(c.row),\(c.col) span \(c.rowSpan)x\(c.colSpan) width \(Int(b.value(for: .width).rounded()))%\(bg) borders \(borders): \(text)")
                }
                i = NSMaxRange(g.range)
                continue
            }
            i = NSMaxRange(ns.paragraphRange(for: NSRange(location: i, length: 0)))
        }
        s.enumerateAttribute(.attachment, in: full) { v, r, _ in
            guard let a = v as? NSTextAttachment, s.attribute(.docNote, at: r.location, effectiveRange: nil) == nil, s.attribute(.docField, at: r.location, effectiveRange: nil) == nil else { return }
            let p = s.attribute(.docImage, at: r.location, effectiveRange: nil) as? DocImage
            var line = "image at \(r.location) page \(pages.pageNumber(at: r.location)) \(Int(a.bounds.width))x\(Int(a.bounds.height)) wrap \(p?.wrap.rawValue ?? "inline")"
            if ProcessInfo.processInfo.environment["K42_DEBUG"] != nil { line += " cell \(a.attachmentCell.map { String(describing: type(of: $0)) } ?? "nil")" }
            if let p, p.isFloating { line += " offset \(Int(p.offset.x)),\(Int(p.offset.y))" }
            if let p, p.borderWidth > 0 { line += " border \(p.borderWidth) \(hex(p.borderColor))" }
            if let p, p.isCropped { line += " crop \(p.crop.left),\(p.crop.top),\(p.crop.right),\(p.crop.bottom)" }
            print(line)
        }
        var lastBlock: NSTextBlock?
        s.enumerateAttribute(.paragraphStyle, in: full) { v, r, _ in
            guard let b = (v as? NSParagraphStyle)?.textBlocks.last, !(b is NSTextTableBlock) else { lastBlock = nil; return }
            if b !== lastBlock {
                let w = CellProps.edges.map { String(format: "%.1f", b.width(for: .border, edge: $0)) }.joined(separator: ",")
                print("box borders \(w) bg \(b.backgroundColor.map(hex) ?? "-"): \(ns.substring(with: r).prefix(30))")
            }
            lastBlock = b
        }
        s.enumerateAttribute(.docDropCap, in: full) { v, r, _ in if let n = v as? Int { print("drop cap \(n) lines: \(ns.substring(with: r))") } }
        for key in [NSAttributedString.Key.docAllCaps, .docSmallCaps] {
            s.enumerateAttribute(key, in: full) { v, r, _ in if v != nil { print("\(key == .docAllCaps ? "caps" : "small caps"): \(ns.substring(with: r))") } }
        }
        s.enumerateAttribute(.strikethroughStyle, in: full) { v, r, _ in if let n = v as? Int, n & 0xF == 9 { print("double strike: \(ns.substring(with: r))") } }
        s.enumerateAttribute(.underlineStyle, in: full) { v, r, _ in if let n = v as? Int, n != 0, n != 1 { print("underline \(DocxWriterProbe.underline(n)): \(ns.substring(with: r))") } }
        // Headers and footers per page.
        for (k, card) in pages.cards.enumerated() {
            let hf = card.setup.effectiveHeaderFooter
            var c = pages.fieldContext(page: k + 1)
            if let tv = card.textViews.first, let tc = tv.textContainer { c.pageStart = pages.layoutManager.characterRange(forGlyphRange: pages.layoutManager.glyphRange(for: tc), actualGlyphRange: nil).location }
            let head = hf.part(header: true, page: k + 1, first: card.firstOfSection).map { Fields.resolve($0, c).string } ?? ""
            let foot = hf.part(header: false, page: k + 1, first: card.firstOfSection).map { Fields.resolve($0, c).string } ?? ""
            if !head.isEmpty || !foot.isEmpty { print("page \(k + 1) header \"\(head.replacingOccurrences(of: "\t", with: "→"))\" footer \"\(foot.replacingOccurrences(of: "\t", with: "→"))\"") }
        }
    }

    static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        return String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}

enum DocxWriterProbe {
    static func underline(_ v: Int) -> String {
        switch v {
        case NSUnderlineStyle.double.rawValue: return "double"
        case NSUnderlineStyle.thick.rawValue: return "thick"
        case NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue: return "dotted"
        case NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue: return "dashed"
        default: return "\(v)"
        }
    }
}
