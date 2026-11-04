import Foundation

/// Markdown block structure for Quick Look: CommonMark blocks plus GitHub tables and task lists.
/// Inline text stays Markdown source; the renderers parse it with the system inline parser.
public indirect enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case code(String, language: String?)
    case quote([MDBlock])
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case table(header: [String], alignments: [MDAlignment], rows: [[String]])
    case rule
    case html(String)
}

public struct MDListItem {
    public var checked: Bool?
    public var blocks: [MDBlock]
}

public enum MDAlignment { case none, left, center, right }

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
        var blocks: [MDBlock] = []
        var i = 0
        // YAML front matter → code block.
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            blocks.append(.code(lines[1..<end].joined(separator: "\n"), language: "yaml"))
            i = end + 1
        }
        blocks += parseBlocks(Array(lines[i...]))
        return blocks
    }

    static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " } }

    static func isRule(_ s: String) -> Bool {
        let t = s.filter { $0 != " " }
        guard t.count >= 3, indent(s) < 4, let c = t.first, "-*_".contains(c) else { return false }
        return t.allSatisfy { $0 == c }
    }

    static func heading(_ s: String) -> (Int, String)? {
        guard indent(s) < 4 else { return nil }
        let t = s.drop { $0 == " " }
        let level = t.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var body = rest.trimmingCharacters(in: .whitespaces)
        // Closing #s
        if let r = body.range(of: #"\s+#+$"#, options: .regularExpression) { body.removeSubrange(r) } else if body.allSatisfy({ $0 == "#" }) { body = "" }
        return (level, body)
    }

    static func fence(_ s: String) -> (String, String)? {
        guard indent(s) < 4 else { return nil }
        let t = s.drop { $0 == " " }
        for mark in ["```", "~~~"] where t.hasPrefix(mark) {
            let n = t.prefix { $0 == mark.first! }.count
            return (String(repeating: mark.first!, count: n), t.dropFirst(n).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// List marker: (ordered, number, content column, rest of line).
    static func listMarker(_ s: String) -> (ordered: Bool, start: Int, marker: Character, contentIndent: Int, rest: String)? {
        let ind = indent(s)
        let t = Array(s.dropFirst(ind))
        guard !t.isEmpty else { return nil }
        if "-*+".contains(t[0]) {
            guard t.count == 1 || t[1] == " " else { return nil }
            if isRule(s) { return nil }
            let pad = t.dropFirst().prefix { $0 == " " }.count
            let ci = ind + 1 + (pad == 0 || pad > 4 ? 1 : pad)
            return (false, 1, t[0], ci, String(t.dropFirst(1 + min(pad, 4))))
        }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), t.count > digits.count, ".)".contains(t[digits.count]) else { return nil }
        let after = t.dropFirst(digits.count + 1)
        guard after.isEmpty || after.first == " " else { return nil }
        let pad = after.prefix { $0 == " " }.count
        let ci = ind + digits.count + 1 + (pad == 0 || pad > 4 ? 1 : pad)
        return (true, Int(String(digits)) ?? 1, t[digits.count], ci, String(after.dropFirst(min(pad, 4))))
    }

    static func tableCells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], cur = "", escaped = false, inCode = false
        for ch in t {
            if escaped { cur.append(ch == "|" ? "|" : "\\"); if ch != "|" { cur.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func tableAlignments(_ s: String) -> [MDAlignment]? {
        guard s.contains("-"), s.contains("|") || s.contains(":") else { return nil }
        let cells = tableCells(s)
        var out: [MDAlignment] = []
        for c in cells {
            guard !c.isEmpty, c.allSatisfy({ "-: ".contains($0) }), c.contains("-") else { return nil }
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            out.append(l && r ? .center : r ? .right : l ? .left : .none)
        }
        return out
    }

    static func startsBlock(_ s: String) -> Bool {
        heading(s) != nil || fence(s) != nil || isRule(s) || s.drop(while: { $0 == " " }).hasPrefix(">") || listMarker(s) != nil
            || (indent(s) < 4 && s.drop(while: { $0 == " " }).hasPrefix("<"))
    }

    static func parseBlocks(_ lines: [String]) -> [MDBlock] {
        var out: [MDBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            if let f = fence(line) {
                let ind = indent(line)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if indent(l) < 4, l.drop(while: { $0 == " " }).hasPrefix(f.0), l.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == f.0.first! }) { i += 1; break }
                    body.append(String(l.dropFirst(min(ind, indent(l)))))
                    i += 1
                }
                out.append(.code(body.joined(separator: "\n"), language: f.1.split(separator: " ").first.map(String.init)))
                continue
            }
            if let h = heading(line) { out.append(.heading(h.0, h.1)); i += 1; continue }
            if isRule(line) { out.append(.rule); i += 1; continue }
            if indent(line) >= 4 {
                var body: [String] = []
                while i < lines.count, indent(lines[i]) >= 4 || isBlank(lines[i]) { body.append(String(lines[i].dropFirst(4))); i += 1 }
                while body.last.map(isBlank) == true { body.removeLast() }
                out.append(.code(body.joined(separator: "\n"), language: nil))
                continue
            }
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].drop { $0 == " " }
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !isBlank(lines[i]) && !startsBlock(lines[i]) && !(inner.last.map(isBlank) ?? true) {
                        inner.append(lines[i])  // lazy continuation
                    } else { break }
                    i += 1
                }
                out.append(.quote(parseBlocks(inner)))
                continue
            }
            if let m = listMarker(line) {
                var items: [MDListItem] = []
                let baseIndent = indent(line)
                while i < lines.count, let mk = listMarker(lines[i]), mk.ordered == m.ordered, mk.marker == m.marker,
                      indent(lines[i]) <= baseIndent + 3, indent(lines[i]) < m.contentIndent {
                    var itemLines = [mk.rest]
                    let ci = mk.contentIndent
                    i += 1
                    var sawBlank = false
                    while i < lines.count {
                        let l = lines[i]
                        if isBlank(l) { sawBlank = true; itemLines.append(""); i += 1; continue }
                        if indent(l) >= ci { itemLines.append(String(l.dropFirst(ci))); sawBlank = false; i += 1; continue }
                        if !sawBlank, !startsBlock(l) { itemLines.append(l.trimmingCharacters(in: .whitespaces)); i += 1; continue }
                        break
                    }
                    while itemLines.last.map(isBlank) == true { itemLines.removeLast() }
                    var checked: Bool?
                    if let first = itemLines.first {
                        for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where first.hasPrefix(box) {
                            checked = value
                            itemLines[0] = String(first.dropFirst(4))
                        }
                    }
                    items.append(MDListItem(checked: checked, blocks: parseBlocks(itemLines)))
                    // A blank line followed by a non-item ends the list.
                    if i < lines.count, listMarker(lines[i]) == nil { break }
                }
                out.append(.list(ordered: m.ordered, start: m.start, items: items))
                continue
            }
            if indent(line) < 4, trimmed.hasPrefix("<") {
                var body: [String] = []
                while i < lines.count, !isBlank(lines[i]) { body.append(lines[i]); i += 1 }
                out.append(.html(body.joined(separator: "\n")))
                continue
            }
            // Table: header row followed by a delimiter row.
            if line.contains("|"), i + 1 < lines.count, let aligns = tableAlignments(lines[i + 1]) {
                let header = tableCells(line)
                if header.count == aligns.count {
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") || !startsBlock(lines[i]) {
                        var cells = tableCells(lines[i])
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        i += 1
                    }
                    out.append(.table(header: header, alignments: aligns, rows: rows))
                    continue
                }
            }
            // Paragraph (with setext headings).
            var para: [String] = [String(trimmed)]
            i += 1
            var setext: Int?
            while i < lines.count, !isBlank(lines[i]) {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if indent(l) < 4, !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; i += 1; break }
                if indent(l) < 4, !t.isEmpty, t.allSatisfy({ $0 == "-" }) { setext = 2; i += 1; break }
                if startsBlock(l) && listMarker(l).map({ !$0.ordered || $0.start == 1 }) ?? true { break }
                para.append(String(l.drop { $0 == " " }))
                i += 1
            }
            // Hard line break: two trailing spaces or a backslash → U+2028 (rendered as <br>).
            var text = ""
            for (k, p) in para.enumerated() {
                let last = k == para.count - 1
                if !last, p.hasSuffix("  ") { text += p.trimmingCharacters(in: .whitespaces) + "\u{2028}" }
                else if !last, p.hasSuffix("\\") { text += String(p.dropLast()) + "\u{2028}" }
                else { text += p.trimmingCharacters(in: .whitespaces) + (last ? "" : "\n") }
            }
            out.append(setext.map { .heading($0, text) } ?? .paragraph(text))
        }
        return out
    }
}
