import AppKit
import Kit42
import UniformTypeIdentifiers

/// Entry points used by the Quick Look preview and thumbnail extensions (and the `ql42render` test tool).
public enum Previews42 {
    public enum Kind { case markdown, ods, delimited }

    public static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn": return .markdown
        case "ods", "ots": return .ods
        case "tsv", "tab", "csv": return .delimited
        default:
            guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return nil }
            if let md = UTType("net.daringfireball.markdown"), type.conforms(to: md) { return .markdown }
            if type.conforms(to: .tabSeparatedText) || type.conforms(to: .commaSeparatedText) { return .delimited }
            if let ods = UTType("org.oasis-open.opendocument.spreadsheet"), type.conforms(to: ods) { return .ods }
            return nil
        }
    }

    static func sheets(_ url: URL, kind: Kind) throws -> [PreviewSheet] {
        let data = try Data(contentsOf: url)
        if kind == .ods { return try SheetReader.ods(data) }
        let ext = url.pathExtension.lowercased()
        var sheet = SheetReader.delimited(data, separator: ext == "tsv" || ext == "tab" ? "\t" : nil)
        sheet.name = url.deletingPathExtension().lastPathComponent
        return [sheet]
    }

    static func markdown(_ url: URL) throws -> (MarkdownRenderer, [MDBlock]) {
        let text = TextDecoding.decode(try Data(contentsOf: url)).text
        return (MarkdownRenderer(baseURL: url.deletingLastPathComponent()), MarkdownParser.parse(text))
    }

    /// Full HTML page for the preview.
    public static func html(for url: URL) throws -> String {
        guard let kind = kind(of: url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let title = url.lastPathComponent
        switch kind {
        case .markdown:
            let (renderer, blocks) = try markdown(url)
            if blocks.isEmpty { return HTMLPage.wrap(title: title, css: HTMLPage.documentCSS, body: "<article><p class=\"missing\">\(HTMLPage.escape(PL("Empty document")))</p></article>") }
            return renderer.html(blocks, title: title)
        case .ods, .delimited:
            return SheetRenderer.html(try sheets(url, kind: kind), title: title)
        }
    }

    /// Thumbnail: a page (documents, portrait) or a grid (spreadsheets, landscape), fitted to `maximumSize`.
    public struct Thumbnail {
        public let size: CGSize
        public let draw: (CGContext) -> Bool
    }

    public static func thumbnail(for url: URL, maximumSize: CGSize) throws -> Thumbnail {
        guard let kind = kind(of: url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let page: CGSize = kind == .markdown ? CGSize(width: 520, height: 672) : CGSize(width: 520, height: 400)
        let scale = min(maximumSize.width / page.width, maximumSize.height / page.height)
        let size = CGSize(width: (page.width * scale).rounded(), height: (page.height * scale).rounded())
        let content: (NSRect) -> Void
        switch kind {
        case .markdown:
            let (renderer, blocks) = try markdown(url)
            let text = renderer.attributed(blocks)
            content = { rect in
                NSColor.white.setFill()
                rect.fill()
                text.draw(with: rect.insetBy(dx: 36, dy: 34), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        case .ods, .delimited:
            let sheet = try sheets(url, kind: kind).first { !$0.rows.isEmpty } ?? PreviewSheet(name: "")
            content = { rect in SheetRenderer.draw(sheet, in: rect) }
        }
        return Thumbnail(size: size) { ctx in
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: size.width / page.width, y: -size.height / page.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let rect = NSRect(origin: .zero, size: page)
            NSBezierPath(rect: rect).addClip()
            content(rect)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            return true
        }
    }
}
