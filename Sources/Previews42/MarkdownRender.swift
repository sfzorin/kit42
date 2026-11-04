import AppKit

/// Markdown blocks → HTML page (Quick Look preview) or attributed text (thumbnail page).
public struct MarkdownRenderer {
    public let baseURL: URL?
    /// Image data for relative/file references (nil if unreadable, e.g. outside the sandbox).
    public var loadImage: (URL) -> Data? = { url in
        guard url.isFileURL, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 20_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }

    public init(baseURL: URL?) { self.baseURL = baseURL }

    static let inlineOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)

    func parseInline(_ md: String) -> AttributedString {
        (try? AttributedString(markdown: md, options: Self.inlineOptions, baseURL: baseURL)) ?? AttributedString(md)
    }

    func resolve(_ url: URL) -> URL {
        if url.scheme == nil, let baseURL { return URL(fileURLWithPath: url.relativePath, relativeTo: baseURL).absoluteURL }
        return url
    }

    // MARK: - HTML

    public func html(_ blocks: [MDBlock], title: String) -> String {
        HTMLPage.wrap(title: title, css: HTMLPage.documentCSS, body: "<article>\n" + blocks.map(html).joined(separator: "\n") + "\n</article>")
    }

    func html(_ block: MDBlock) -> String {
        switch block {
        case .heading(let level, let text): return "<h\(level)>\(inlineHTML(text))</h\(level)>"
        case .paragraph(let text): return "<p>\(inlineHTML(text))</p>"
        case .code(let code, let language):
            let cls = language.map { " class=\"language-\(HTMLPage.escape($0))\"" } ?? ""
            return "<pre><code\(cls)>\(HTMLPage.escape(code))</code></pre>"
        case .quote(let inner): return "<blockquote>\n" + inner.map(html).joined(separator: "\n") + "\n</blockquote>"
        case .list(let ordered, let start, let items):
            let tight = items.allSatisfy { $0.blocks.count <= 1 || $0.blocks.dropFirst().allSatisfy { if case .list = $0 { return true }; return false } }
            let tag = ordered ? "ol" : "ul"
            let open = ordered && start != 1 ? "<ol start=\"\(start)\">" : "<\(tag)\(items.contains { $0.checked != nil } ? " class=\"tasks\"" : "")>"
            let lis = items.map { item -> String in
                let box = item.checked.map { "<input type=\"checkbox\" disabled\($0 ? " checked" : "")> " } ?? ""
                let body = item.blocks.enumerated().map { k, b -> String in
                    if tight, case .paragraph(let t) = b { return (k == 0 ? box : "") + inlineHTML(t) }
                    return (k == 0 ? box : "") + html(b)
                }.joined(separator: "\n")
                return "<li>\(item.blocks.isEmpty ? box : body)</li>"
            }
            return open + "\n" + lis.joined(separator: "\n") + "\n</\(tag)>"
        case .table(let header, let alignments, let rows):
            func cell(_ tag: String, _ text: String, _ k: Int) -> String {
                let a = k < alignments.count ? alignments[k] : .none
                let style = a == .none ? "" : " style=\"text-align:\(a == .left ? "left" : a == .center ? "center" : "right")\""
                return "<\(tag)\(style)>\(inlineHTML(text))</\(tag)>"
            }
            let head = "<tr>" + header.enumerated().map { cell("th", $1, $0) }.joined() + "</tr>"
            let body = rows.map { "<tr>" + $0.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>" }.joined(separator: "\n")
            return "<table>\n<thead>\(head)</thead>\n<tbody>\n\(body)\n</tbody>\n</table>"
        case .rule: return "<hr>"
        case .html(let raw): return sanitizedHTML(raw)
        }
    }

    /// Raw HTML blocks pass through (JavaScript never runs in Quick Look); local images are inlined.
    func sanitizedHTML(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let pattern = try! NSRegularExpression(pattern: #"(<img\b[^>]*\bsrc\s*=\s*")([^"]+)(")"#, options: .caseInsensitive)
        for m in pattern.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let r = Range(m.range(at: 2), in: out), let url = URL(string: String(out[r])) else { continue }
            if let src = imageSource(url) { out.replaceSubrange(r, with: src) }
        }
        return out
    }

    func imageSource(_ url: URL) -> String? {
        if let scheme = url.scheme, scheme != "file" { return url.absoluteString }
        let file = resolve(url)
        guard let data = loadImage(file) else { return nil }
        return "data:\(HTMLPage.mimeType(file.pathExtension));base64," + data.base64EncodedString()
    }

    func inlineHTML(_ md: String) -> String {
        let a = parseInline(md)
        var out = ""
        var lastImage: URL?
        for run in a.runs {
            let text = String(a[run.range].characters)
            if let img = run.imageURL {
                if img != lastImage {
                    if let src = imageSource(img) {
                        out += "<img src=\"\(HTMLPage.escape(src))\" alt=\"\(HTMLPage.escape(text))\">"
                    } else {
                        out += "<span class=\"missing\" title=\"\(HTMLPage.escape(img.relativeString))\">\(HTMLPage.escape(text.isEmpty ? img.lastPathComponent : text))</span>"
                    }
                }
                lastImage = img
                continue
            }
            lastImage = nil
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.inlineHTML) { out += text; continue }
            var s = HTMLPage.escape(text).replacingOccurrences(of: "\u{2028}", with: "<br>")
            if intent.contains(.code) { s = "<code>\(s)</code>" }
            if intent.contains(.strikethrough) { s = "<del>\(s)</del>" }
            if intent.contains(.emphasized) { s = "<em>\(s)</em>" }
            if intent.contains(.stronglyEmphasized) { s = "<strong>\(s)</strong>" }
            if let link = run.link { s = "<a href=\"\(HTMLPage.escape(link.absoluteString))\">\(s)</a>" }
            out += s
        }
        return out
    }

    // MARK: - Attributed text (thumbnails)

    public func attributed(_ blocks: [MDBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for b in blocks { append(b, to: out, depth: 0, quote: false) }
        return out
    }

    static let bodySize: CGFloat = 13
    static let ink = NSColor(white: 0.12, alpha: 1)

    func paragraphStyle(depth: Int, quote: Bool, spacing: CGFloat = 8) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.headIndent = CGFloat(depth) * 20 + (quote ? 14 : 0)
        p.firstLineHeadIndent = p.headIndent
        p.lineHeightMultiple = 1.1
        return p
    }

    func append(_ block: MDBlock, to out: NSMutableAttributedString, depth: Int, quote: Bool, prefix: String = "") {
        let color = quote ? NSColor(white: 0.42, alpha: 1) : Self.ink
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [26, 20, 16.5, 14.5, 13, 12]
            let p = paragraphStyle(depth: depth, quote: quote, spacing: level <= 2 ? 10 : 6)
            p.paragraphSpacingBefore = out.length > 0 ? 6 : 0
            out.append(inlineAttributed(text, size: sizes[level - 1], bold: true, color: color, paragraph: p))
        case .paragraph(let text):
            let p = paragraphStyle(depth: depth, quote: quote)
            if !prefix.isEmpty { p.firstLineHeadIndent = max(0, p.headIndent - 16) }
            let s = NSMutableAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: Self.bodySize), .foregroundColor: color, .paragraphStyle: p])
            s.append(inlineAttributed(text, size: Self.bodySize, bold: false, color: color, paragraph: p))
            out.append(s)
        case .code(let code, _):
            let p = paragraphStyle(depth: depth, quote: quote, spacing: 8)
            p.lineHeightMultiple = 1.0
            out.append(NSAttributedString(string: code + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: color,
                .backgroundColor: NSColor(white: 0.94, alpha: 1), .paragraphStyle: p]))
        case .quote(let inner):
            for b in inner { append(b, to: out, depth: depth, quote: true) }
        case .list(let ordered, let start, let items):
            for (k, item) in items.enumerated() {
                let marker = item.checked.map { $0 ? "\u{2611}\u{2002}" : "\u{2610}\u{2002}" } ?? (ordered ? "\(start + k).\u{2002}" : "\u{2022}\u{2002}")
                for (j, b) in item.blocks.enumerated() {
                    append(b, to: out, depth: depth + 1, quote: quote, prefix: j == 0 ? marker : "")
                }
                if item.blocks.isEmpty { append(.paragraph(""), to: out, depth: depth + 1, quote: quote, prefix: marker) }
            }
        case .table(let header, _, let rows):
            let table = NSTextTable()
            table.numberOfColumns = max(1, header.count)
            table.collapsesBorders = true
            for (r, row) in ([header] + rows).enumerated() {
                for (c, text) in row.enumerated() {
                    let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(NSColor(white: 0.7, alpha: 1))
                    cell.setWidth(4, type: .absoluteValueType, for: .padding)
                    if r == 0 { cell.backgroundColor = NSColor(white: 0.94, alpha: 1) }
                    let p = paragraphStyle(depth: 0, quote: false, spacing: 0)
                    p.textBlocks = [cell]
                    out.append(inlineAttributed(text, size: 12, bold: r == 0, color: color, paragraph: p))
                }
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        case .rule:
            let p = paragraphStyle(depth: depth, quote: quote)
            p.alignment = .center
            out.append(NSAttributedString(string: "\u{2014}\u{2014}\u{2014}\n", attributes: [
                .font: NSFont.systemFont(ofSize: Self.bodySize), .foregroundColor: NSColor(white: 0.65, alpha: 1), .paragraphStyle: p]))
        case .html(let raw):
            let text = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { append(.paragraph(text), to: out, depth: depth, quote: quote) }
        }
    }

    func inlineAttributed(_ md: String, size: CGFloat, bold: Bool, color: NSColor, paragraph: NSParagraphStyle) -> NSAttributedString {
        let a = parseInline(md)
        let out = NSMutableAttributedString()
        var lastImage: URL?
        for run in a.runs {
            let text = String(a[run.range].characters).replacingOccurrences(of: "\n", with: " ")
            if let img = run.imageURL {
                if img != lastImage, let data = loadImage(resolve(img)), let image = NSImage(data: data) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    var s = image.size
                    if s.width > 480 { s = NSSize(width: 480, height: s.height * 480 / s.width) }
                    attachment.bounds = NSRect(origin: .zero, size: s)
                    out.append(NSAttributedString(attachment: attachment))
                }
                lastImage = img
                continue
            }
            lastImage = nil
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: size, weight: bold || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if intent.contains(.code) {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
                attrs[.backgroundColor] = NSColor(white: 0.93, alpha: 1)
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.link != nil { attrs[.foregroundColor] = NSColor(srgbRed: 0.04, green: 0.4, blue: 0.85, alpha: 1) }
            out.append(NSAttributedString(string: text.replacingOccurrences(of: "\u{2028}", with: "\u{2028}"), attributes: attrs))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]))
        return out
    }
}
