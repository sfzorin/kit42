import Foundation

/// HTML scaffolding for Quick Look previews: light and dark colour schemes follow the system.
enum HTMLPage {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }

    static func wrap(title: String, css: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(baseCSS)\(css)</style>
        </head><body>
        \(body)
        </body></html>
        """
    }

    static let baseCSS = """
    :root { --fg:#1d1d1f; --muted:#6e6e73; --bg:#ffffff; --line:#d2d2d7; --soft:#f5f5f7; --code:#f2f2f4; --link:#0a66d8; --head:#ececef; --accent:#1f7a4d; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#e8e8ed; --muted:#98989d; --bg:#1e1e1e; --line:#3a3a3c; --soft:#2a2a2c; --code:#2c2c2e; --link:#4aa3ff; --head:#2c2c2e; --accent:#4cc38a; }
    }
    html { background:var(--bg); color:var(--fg); }
    body { margin:0; font:14px/1.55 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing:antialiased; }
    a { color:var(--link); text-decoration:none; }
    """

    static let documentCSS = """
    article { max-width:860px; margin:0 auto; padding:32px 40px 56px; }
    h1,h2,h3,h4,h5,h6 { line-height:1.25; margin:1.4em 0 .5em; font-weight:650; }
    h1 { font-size:2em; padding-bottom:.25em; border-bottom:1px solid var(--line); }
    h2 { font-size:1.5em; padding-bottom:.2em; border-bottom:1px solid var(--line); }
    h3 { font-size:1.25em; } h4 { font-size:1.05em; } h5,h6 { font-size:.95em; color:var(--muted); }
    article > :first-child { margin-top:0; }
    p, ul, ol, pre, table, blockquote { margin:0 0 1em; }
    ul, ol { padding-left:1.8em; } li + li { margin-top:.2em; } li > ul, li > ol { margin:.2em 0 0; }
    ul.tasks { list-style:none; padding-left:1.2em; } ul.tasks input { margin:0 .4em 0 -1.2em; vertical-align:-1px; }
    code { font:12.5px/1.45 ui-monospace, "SF Mono", Menlo, monospace; background:var(--code); padding:.15em .35em; border-radius:4px; }
    pre { background:var(--code); padding:12px 14px; border-radius:8px; overflow:auto; }
    pre code { background:none; padding:0; }
    blockquote { margin-left:0; padding:0 1em; color:var(--muted); border-left:4px solid var(--line); }
    hr { border:0; border-top:1px solid var(--line); margin:1.6em 0; }
    table { border-collapse:collapse; display:block; overflow:auto; }
    th, td { border:1px solid var(--line); padding:5px 12px; }
    th { background:var(--soft); font-weight:600; }
    tr:nth-child(2n) td { background:var(--soft); }
    img { max-width:100%; }
    .missing { color:var(--muted); border:1px dashed var(--line); padding:0 .4em; border-radius:4px; }
    """

    static let sheetCSS = """
    body { font-size:12px; }
    nav { position:sticky; top:0; z-index:3; background:var(--bg); border-bottom:1px solid var(--line); padding:6px 10px; font-weight:600; }
    nav a { margin-right:14px; }
    section { padding:12px 10px 20px; }
    h2 { font-size:13px; margin:0 0 8px; color:var(--muted); font-weight:600; }
    table.sheet { border-collapse:collapse; font-variant-numeric:tabular-nums; }
    .sheet td, .sheet th { border:1px solid var(--line); padding:2px 6px; white-space:pre; min-width:3em; max-width:40em; overflow:hidden; text-overflow:ellipsis; vertical-align:bottom; }
    .sheet th { background:var(--head); color:var(--muted); font-weight:500; text-align:center; position:sticky; top:0; }
    .sheet th.r { position:sticky; left:0; text-align:right; min-width:2.5em; }
    .sheet td.n { text-align:right; }
    .sheet td.b { font-weight:650; }
    .sheet td.i { font-style:italic; }
    .note { color:var(--muted); margin-top:8px; }
    """
}
