import AppKit
import Kit42

/// Markdown → document: the system parser gives semantic runs (headings, lists, tables, code),
/// which get the document look here.
enum MarkdownReader {
    static func read(_ md: String, baseURL: URL?) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .full), baseURL: baseURL)) ?? AttributedString(md)
        return style(NSAttributedString(parsed), baseURL: baseURL)
    }

    private static let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]

    static func style(_ source: NSAttributedString, baseURL: URL? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var lastBlock: Int?
        var lastListItem: Int?
        var tables: [Int: NSTextTable] = [:]
        var tableRow: (table: Int, row: Int, rowId: Int)?
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            let components = (attrs[NSAttributedString.Key("NSPresentationIntent")] as? PresentationIntent)?.components ?? []
            let inline = (attrs[NSAttributedString.Key("NSInlinePresentationIntent")] as? NSNumber)?.uintValue ?? 0
            var style = Styles.normal
            var styleName: String?
            var isCode = false
            var listDepth = 0
            var listItem: (id: Int, ordinal: Int, ordered: Bool)?
            var cell: (table: Int, columns: Int, row: Int, rowId: Int, header: Bool, column: Int)?
            var isRule = false
            for (k, c) in components.enumerated() {
                switch c.kind {
                case .header(let level):
                    let l = min(3, max(1, level))
                    style = Styles.all[l]
                    styleName = Styles.wordIds[l]
                case .blockQuote:
                    style = Styles.all[5]
                    styleName = "Quote"
                case .codeBlock: isCode = true
                case .thematicBreak: isRule = true
                case .orderedList, .unorderedList: listDepth += 1
                case .listItem(let ordinal):
                    if listItem == nil {
                        let ordered = components.dropFirst(k + 1).first { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
                            .map { if case .orderedList = $0.kind { return true }; return false } ?? false
                        listItem = (c.identity, ordinal, ordered)
                    }
                case .tableCell(let column):
                    cell = (0, 1, 0, 0, false, column)
                case .tableHeaderRow:
                    cell?.header = true
                    cell?.rowId = c.identity
                case .tableRow(let row):
                    cell?.row = row
                    cell?.rowId = c.identity
                case .table(let columns):
                    cell?.table = c.identity
                    cell?.columns = columns.count
                default: break
                }
            }
            // A new block starts a new paragraph.
            let block = components.first?.identity
            if let block, block != lastBlock, out.length > 0, !out.string.hasSuffix("\n") {
                out.append(NSAttributedString(string: "\n", attributes: style.attributes))
            }
            let newBlock = block != lastBlock
            lastBlock = block

            var a = style.attributes
            if let styleName { a[Styles.styleKey] = styleName }
            var font = a[.font] as! NSFont
            if inline & 2 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }   // stronglyEmphasized
            if inline & 1 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) } // emphasized
            if inline & 32 != 0 { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if isCode || inline & 4 != 0 {
                font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                a[.backgroundColor] = NSColor(white: 0.95, alpha: 1)
            }
            a[.font] = font
            if let link = attrs[.link] {
                a[.link] = link
                a[.foregroundColor] = NSColor.linkColor
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let paragraph = (a[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            var text = source.attributedSubstring(from: range).string

            if listDepth > 0 {
                paragraph.headIndent = 36 + CGFloat(listDepth - 1) * 24
                paragraph.firstLineHeadIndent = paragraph.headIndent - 36
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.firstLineHeadIndent + 12),
                                      NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                paragraph.paragraphSpacing = 2
                if let item = listItem, item.id != lastListItem, newBlock {
                    let marker = item.ordered ? "\(item.ordinal)." : bullets[(listDepth - 1) % bullets.count]
                    text = "\t\(marker)\t" + text
                }
                lastListItem = listItem?.id
            }
            if let c = cell {
                if tableRow?.table != c.table { tableRow = (c.table, 0, c.rowId) } else if tableRow?.rowId != c.rowId {
                    tableRow = (c.table, tableRow!.row + 1, c.rowId)
                }
                let table = tables[c.table] ?? {
                    let t = NSTextTable()
                    t.numberOfColumns = max(1, c.columns)
                    t.collapsesBorders = true
                    return t
                }()
                tables[c.table] = table
                let b = NSTextTableBlock(table: table, startingRow: tableRow!.row, rowSpan: 1, startingColumn: c.column, columnSpan: 1)
                b.setWidth(0.5, type: .absoluteValueType, for: .border)
                b.setBorderColor(NSColor(white: 0.6, alpha: 1))
                b.setWidth(4, type: .absoluteValueType, for: .padding)
                b.setValue(100 / CGFloat(table.numberOfColumns), type: .percentageValueType, for: .width)
                if c.header { a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask); b.backgroundColor = NSColor(white: 0.95, alpha: 1) }
                paragraph.textBlocks = [b]
                paragraph.paragraphSpacing = 0
            }
            if isCode, inline & 4 == 0 {
                paragraph.paragraphSpacing = 0
                paragraph.paragraphSpacingBefore = 0
                paragraph.lineHeightMultiple = 1.05
            }
            if isRule {
                paragraph.alignment = .center
                a[.foregroundColor] = NSColor(white: 0.6, alpha: 1)
                text = "\u{2E3B}"
            }
            a[.paragraphStyle] = paragraph
            if let url = attrs[NSAttributedString.Key("NSImageURL")] as? URL, let image = loadImage(url, baseURL: baseURL) {
                let s = NSMutableAttributedString(attributedString: image)
                s.addAttribute(MarkdownWriter.sourceKey, value: url.scheme == "data" ? "" : url.relativeString, range: NSRange(location: 0, length: s.length))
                out.append(s)
                return
            }
            out.append(NSAttributedString(string: text, attributes: a))
        }
        return out
    }

    private static func loadImage(_ url: URL, baseURL: URL?) -> NSAttributedString? {
        var data: Data?
        if url.scheme == "data", let comma = url.absoluteString.firstIndex(of: ",") {
            data = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...]).removingPercentEncoding ?? "")
        } else if url.isFileURL || url.scheme == nil {
            let file = url.scheme == nil ? URL(fileURLWithPath: url.relativePath, relativeTo: baseURL) : url
            data = try? Data(contentsOf: file)
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        let attachment = NSTextAttachment()
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = url.lastPathComponent.isEmpty ? "image.png" : url.lastPathComponent
        attachment.fileWrapper = wrapper
        attachment.image = image
        var size = image.size
        if size.width > 450 { size = NSSize(width: 450, height: size.height * 450 / size.width) }
        attachment.bounds = NSRect(origin: .zero, size: size)
        return NSAttributedString(attachment: attachment)
    }
}

/// Document → Markdown (CommonMark + GitHub tables and strikethrough).
enum MarkdownWriter {
    /// Where a picture read from Markdown came from: written back as the same link.
    static let sourceKey = NSAttributedString.Key("DOC42.imageSource")

    /// Footnote numbers of the text being written (GitHub "[^n]" footnotes).
    private static var noteNumbers: [ObjectIdentifier: Int] = [:]

    static func write(_ text: NSAttributedString) -> String {
        let notes = Notes.all(in: text)
        noteNumbers = Dictionary(notes.enumerated().map { (ObjectIdentifier($0.element.1), $0.offset + 1) }) { a, _ in a }
        defer { noteNumbers = [:] }
        var body = writeBody(text)
        if !notes.isEmpty {
            body += "\n" + notes.enumerated().map { "[^\($0.offset + 1)]: " + escape($0.element.1.text) }.joined(separator: "\n") + "\n"
        }
        return body
    }

    private static func writeBody(_ text: NSAttributedString) -> String {
        let ns = text.string as NSString
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            paragraphs.append(r)
        }
        var blocks: [(kind: String, text: String)] = []   // kind: p, li, code, table
        var i = 0
        while i < paragraphs.count {
            let r = paragraphs[i]
            let style = r.length > 0 || r.location < text.length ? text.attribute(.paragraphStyle, at: min(r.location, max(0, text.length - 1)), effectiveRange: nil) as? NSParagraphStyle : nil
            if let block = style?.textBlocks.last as? NSTextTableBlock {
                // Collect the whole table.
                var cells: [Int: [Int: String]] = [:]
                while i < paragraphs.count {
                    let pr = paragraphs[i]
                    guard pr.location < text.length,
                          let b = (text.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                          b.table === block.table else { break }
                    let content = inline(text, pr, plainBold: b.startingRow == 0).replacingOccurrences(of: "|", with: "\\|")
                    let old = cells[b.startingRow]?[b.startingColumn]
                    cells[b.startingRow, default: [:]][b.startingColumn] = old.map { $0 + "<br>" + content } ?? content
                    i += 1
                }
                let columns = max(block.table.numberOfColumns, cells.values.flatMap(\.keys).max().map { $0 + 1 } ?? 1)
                var lines: [String] = []
                for (k, row) in cells.keys.sorted().enumerated() {
                    lines.append("| " + (0..<columns).map { cells[row]?[$0] ?? "" }.joined(separator: " | ") + " |")
                    if k == 0 { lines.append("|" + String(repeating: " --- |", count: columns)) }
                }
                blocks.append(("table", lines.joined(separator: "\n")))
                continue
            }
            i += 1
            let raw = ns.substring(with: r)
            if raw.isEmpty { continue }
            if raw == "\u{2E3B}" { blocks.append(("p", "---")); continue }
            if isCode(text, r) { blocks.append(("code", raw)); continue }

            let name = Styles.wordStyle(text, r)
            var prefix = ""
            switch name {
            case "Title", "Heading1": prefix = "# "
            case "Heading2": prefix = "## "
            case "Heading3": prefix = "### "
            case "Quote": prefix = "> "
            default: break
            }
            var body = r
            var kind = "p"
            if let m = try? NSRegularExpression(pattern: "^\\t?([\u{2022}\u{25E6}\u{25AA}\u{25CF}\u{25CB}\u{25A0}\u{2013}\u{2014}\\-*+]|\\d+[.)]|[a-zA-Z][.)])\\t").firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                let marker = (raw as NSString).substring(with: m.range(at: 1))
                let level = max(0, Int(((style?.headIndent ?? 36) - 36) / 24 + 0.5))
                let indent = String(repeating: "    ", count: level)
                prefix = indent + (marker.first?.isNumber == true ? marker.replacingOccurrences(of: ")", with: ".") + " " : "- ")
                body = NSRange(location: r.location + m.range.length, length: r.length - m.range.length)
                kind = "li"
            }
            let content = inline(text, body, plainBold: prefix.hasPrefix("#"), plainItalic: name == "Quote")
            blocks.append((kind, prefix + (prefix.isEmpty ? escapeLineStart(content) : content)))
        }
        // Join: list items and code lines stay together.
        var out = ""
        var previous = ""
        for b in blocks {
            if !out.isEmpty {
                if b.kind == previous, b.kind == "li" { out += "\n" } else if b.kind == previous, b.kind == "code" {
                    out.removeLast(4)   // continue the open fence
                    out += "\n\(b.text)\n```"
                    continue
                } else { out += "\n\n" }
            }
            out += b.kind == "code" ? "```\n\(b.text)\n```" : b.text
            previous = b.kind
        }
        return out + "\n"
    }

    private static func isCode(_ text: NSAttributedString, _ r: NSRange) -> Bool {
        guard r.length > 0 else { return false }
        var all = true
        text.enumerateAttribute(.font, in: r) { v, _, stop in
            if (v as? NSFont)?.isFixedPitch != true { all = false; stop.pointee = true }
        }
        return all && text.attribute(.backgroundColor, at: r.location, effectiveRange: nil) != nil
    }

    private struct Piece: Equatable {
        var text: String
        var bold = false, italic = false, strike = false, code = false
        var link: String?
        func sameLook(_ o: Piece) -> Bool { bold == o.bold && italic == o.italic && strike == o.strike && code == o.code && link == o.link }
    }

    /// Inline formatting of a range. Headings are bold by style: no ** there.
    private static func inline(_ text: NSAttributedString, _ range: NSRange, plainBold: Bool, plainItalic: Bool = false) -> String {
        var pieces: [Piece] = []
        text.enumerateAttributes(in: range) { attrs, r, _ in
            if let note = attrs[.docNote] as? DocNote {
                pieces.append(Piece(text: "[^\(noteNumbers[ObjectIdentifier(note)] ?? 1)]", code: true, link: "\u{0}img"))
                return
            }
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                if let source = attrs[sourceKey] as? String, !source.isEmpty {
                    pieces.append(Piece(text: "![](\(source))", code: true, link: "\u{0}img"))
                } else if let (data, _) = imageData(attachment) { pieces.append(Piece(text: "![](data:image/png;base64,\(data.base64EncodedString()))", code: true, link: "\u{0}img")) }
                return
            }
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            var p = Piece(text: (text.string as NSString).substring(with: r).replacingOccurrences(of: "\u{2028}", with: "\n"))
            p.code = font?.isFixedPitch == true
            p.bold = traits.contains(.boldFontMask) && !plainBold && !p.code
            p.italic = traits.contains(.italicFontMask) && !p.code && !plainItalic
            p.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            if let link = attrs[.link] { p.link = (link as? URL)?.absoluteString ?? (link as? String) }
            if let last = pieces.last, last.sameLook(p), last.link != "\u{0}img" { pieces[pieces.count - 1].text += p.text } else { pieces.append(p) }
        }
        var out = ""
        for p in pieces {
            if p.link == "\u{0}img" { out += p.text; continue }
            var core = p.code ? p.text : escape(p.text)
            if core.trimmingCharacters(in: .whitespaces).isEmpty { out += core; continue }
            // Markers hug the text: spaces go outside.
            let lead = String(core.prefix { $0 == " " }), trail = String(core.reversed().prefix { $0 == " " })
            core = String(core.dropFirst(lead.count).dropLast(trail.count))
            if p.code { core = "`\(core)`" }
            if p.italic { core = "*\(core)*" }
            if p.bold { core = "**\(core)**" }
            if p.strike { core = "~~\(core)~~" }
            if let link = p.link { core = "[\(core)](\(link))" }
            out += lead + core + trail
        }
        return out.replacingOccurrences(of: "\n", with: "  \n")
    }

    private static func imageData(_ attachment: NSTextAttachment) -> (Data, NSSize)? {
        var image = attachment.image
        if image == nil, let data = attachment.fileWrapper?.regularFileContents { image = NSImage(data: data) }
        guard let image, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return (png, attachment.bounds.size)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]<>|~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Text that would read as a heading, quote or list at the start of a line.
    private static func escapeLineStart(_ s: String) -> String {
        if s.hasPrefix("#") || s.hasPrefix(">") || s.hasPrefix("- ") || s.hasPrefix("+ ") || s.hasPrefix("---") { return "\\" + s }
        if let m = s.range(of: "^\\d+[.)] ", options: .regularExpression) {
            var t = s
            let dot = t.index(before: t.index(before: m.upperBound))
            t.insert("\\", at: dot)
            return t
        }
        return s
    }
}
