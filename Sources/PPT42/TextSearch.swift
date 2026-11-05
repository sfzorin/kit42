import AppKit

/// Searches model text across formatting runs while leaving dynamic fields untouched.
enum TextSearch {
    static func ranges(in text: String, query: String, options: String.CompareOptions) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = [], start = 0
        while start < source.length {
            let found = source.range(of: query, options: options, range: NSRange(location: start, length: source.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found); start = NSMaxRange(found)
        }
        return result
    }

    private static func storage(_ body: TextBody) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, paragraph) in body.paragraphs.enumerated() {
            let para = ParaBox(level: paragraph.level, props: paragraph.props, endProps: paragraph.endProps)
            for run in paragraph.runs {
                result.append(NSAttributedString(string: run.text, attributes: [.pptPara: para, .pptRun: RunBox(run.props, field: run.field, link: run.link)]))
            }
            if index + 1 < body.paragraphs.count {
                result.append(NSAttributedString(string: "\n", attributes: [.pptPara: para, .pptRun: RunBox(paragraph.endProps)]))
            }
        }
        return result
    }

    static func ranges(in body: TextBody, query: String, options: String.CompareOptions) -> [NSRange] {
        let text = storage(body)
        return ranges(in: text.string, query: query, options: options).filter { range in
            var field = false
            text.enumerateAttribute(.pptRun, in: range) { value, _, _ in if (value as? RunBox)?.field != nil { field = true } }
            return !field
        }
    }

    /// Replacement inherits the first matched character; surrounding run/paragraph formatting is retained.
    static func replace(in body: inout TextBody, query: String, replacement: String, options: String.CompareOptions) -> Int {
        let matches = ranges(in: body, query: query, options: options)
        guard !matches.isEmpty else { return 0 }
        let text = storage(body)
        for range in matches.reversed() {
            var attributes = text.attributes(at: range.location, effectiveRange: nil)
            if let run = attributes[.pptRun] as? RunBox { attributes[.pptRun] = RunBox(run.props, link: run.link) }
            text.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: attributes))
        }
        let original = body.paragraphs
        body.paragraphs = TextRender.paragraphs(from: text)
        // Empty final paragraphs have no character on which to retain their own properties.
        if let last = original.last, last.text.isEmpty, text.string.hasSuffix("\n"), !body.paragraphs.isEmpty {
            body.paragraphs[body.paragraphs.count - 1] = last
        }
        return matches.count
    }
}

extension SlideObject {
    /// Apply text commands to all visible text containers, including nested groups and table cells.
    mutating func editTextBodies(_ edit: (inout TextBody) -> Void) {
        if var text { edit(&text); self.text = text }
        if var table {
            for row in table.cells.indices {
                for column in table.cells[row].indices where !table.cells[row][column].merged { edit(&table.cells[row][column].text) }
            }
            self.table = table
        }
        for i in children.indices { children[i].editTextBodies(edit) }
    }

    var firstTextContainer: (object: SlideObject, body: TextBody, row: Int?)? {
        if let text { return (self, text, nil) }
        if let table {
            for row in table.cells.indices {
                if let cell = table.cells[row].first(where: { !$0.merged }) { return (self, cell.text, row) }
            }
        }
        return children.lazy.compactMap(\.firstTextContainer).first
    }
}
