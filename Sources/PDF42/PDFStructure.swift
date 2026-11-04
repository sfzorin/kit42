import Kit42
import Foundation

/// Minimal PDF object model, just enough to append an incremental update (digital signatures)
/// to files with a classic cross-reference table — which is what PDFKit writes.
indirect enum PDFObject {
    case raw(String)                    // numbers, booleans, null, strings — kept verbatim
    case name(String)                   // without the leading slash
    case array([PDFObject])
    case dict([(String, PDFObject)])
    case ref(Int, Int)

    var serialized: String {
        switch self {
        case .raw(let s): return s
        case .name(let n): return "/" + n
        case .ref(let n, let g): return "\(n) \(g) R"
        case .array(let items): return "[" + items.map(\.serialized).joined(separator: " ") + "]"
        case .dict(let pairs): return "<< " + pairs.map { "/\($0.0) \($0.1.serialized)" }.joined(separator: " ") + " >>"
        }
    }

    subscript(key: String) -> PDFObject? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    func setting(_ key: String, _ value: PDFObject) -> PDFObject {
        guard case .dict(var pairs) = self else { return self }
        if let i = pairs.firstIndex(where: { $0.0 == key }) { pairs[i].1 = value } else { pairs.append((key, value)) }
        return .dict(pairs)
    }

    func removing(_ key: String) -> PDFObject {
        guard case .dict(let pairs) = self else { return self }
        return .dict(pairs.filter { $0.0 != key })
    }

    var int: Int? {
        if case .raw(let s) = self { return Int(s) }
        return nil
    }

    var nameValue: String? {
        if case .name(let n) = self { return n }
        return nil
    }

    var items: [PDFObject]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

enum PDFStructureError: LocalizedError {
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return L("This PDF cannot be signed: %@", s)
        case .malformed(let s): return L("Damaged PDF: %@", s)
        }
    }
}

struct PDFLexer {
    let bytes: [UInt8]
    var pos: Int

    static func isWhite(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
    static func isDelimiter(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

    mutating func skipWhitespace() {
        while pos < bytes.count {
            if Self.isWhite(bytes[pos]) { pos += 1 }
            else if bytes[pos] == UInt8(ascii: "%") {
                while pos < bytes.count, bytes[pos] != 0x0A, bytes[pos] != 0x0D { pos += 1 }
            } else { break }
        }
    }

    /// Next regular token (keyword or number) without consuming delimiters.
    mutating func word() -> String {
        skipWhitespace()
        let start = pos
        while pos < bytes.count, !Self.isWhite(bytes[pos]), !Self.isDelimiter(bytes[pos]) { pos += 1 }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    mutating func expect(_ keyword: String) throws {
        let w = word()
        guard w == keyword else { throw PDFStructureError.malformed("expected \(keyword), found \(w)") }
    }

    func peek(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return pos + u.count <= bytes.count && Array(bytes[pos..<pos + u.count]) == u
    }

    mutating func parse() throws -> PDFObject {
        skipWhitespace()
        guard pos < bytes.count else { throw PDFStructureError.malformed("unexpected end") }
        let c = bytes[pos]
        if peek("<<") {
            pos += 2
            var pairs: [(String, PDFObject)] = []
            while true {
                skipWhitespace()
                if peek(">>") { pos += 2; break }
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "/") else { throw PDFStructureError.malformed("dictionary key") }
                guard case .name(let key) = try parse() else { throw PDFStructureError.malformed("key") }
                pairs.append((key, try parse()))
            }
            return .dict(pairs)
        }
        switch c {
        case UInt8(ascii: "["):
            pos += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; break }
                items.append(try parse())
            }
            return .array(items)
        case UInt8(ascii: "("):
            let start = pos
            var depth = 0
            while pos < bytes.count {
                let b = bytes[pos]
                if b == UInt8(ascii: "\\") { pos += 2; continue }
                if b == UInt8(ascii: "(") { depth += 1 }
                if b == UInt8(ascii: ")") { depth -= 1; if depth == 0 { pos += 1; break } }
                pos += 1
            }
            return .raw(String(decoding: bytes[start..<pos], as: UTF8.self))
        case UInt8(ascii: "<"):
            let start = pos
            while pos < bytes.count, bytes[pos] != UInt8(ascii: ">") { pos += 1 }
            pos += 1
            return .raw(String(decoding: bytes[start..<pos], as: UTF8.self))
        case UInt8(ascii: "/"):
            pos += 1
            let start = pos
            while pos < bytes.count, !Self.isWhite(bytes[pos]), !Self.isDelimiter(bytes[pos]) { pos += 1 }
            return .name(String(decoding: bytes[start..<pos], as: UTF8.self))
        default:
            let w = word()
            guard !w.isEmpty else { throw PDFStructureError.malformed("unknown character") }
            // "n g R" reference?
            if let n = Int(w) {
                let save = pos
                let g = word()
                if let gen = Int(g) {
                    let r = word()
                    if r == "R" { return .ref(n, gen) }
                }
                pos = save
            }
            return .raw(w)
        }
    }
}

/// Parsed cross-reference information of an existing file.
struct PDFFileStructure {
    let bytes: [UInt8]
    let startxref: Int
    let trailer: PDFObject
    private(set) var offsets: [Int: (offset: Int, gen: Int)] = [:]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard let sx = Self.lastIndex(of: "startxref", in: bytes) else { throw PDFStructureError.malformed("no startxref") }
        var lx = PDFLexer(bytes: bytes, pos: sx + 9)
        guard let start = Int(lx.word()) else { throw PDFStructureError.malformed("startxref") }
        startxref = start

        var next: Int? = start
        var firstTrailer: PDFObject?
        var visited = Set<Int>()
        var freed = Set<Int>()
        while let off = next, !visited.contains(off) {
            visited.insert(off)
            var lexer = PDFLexer(bytes: bytes, pos: off)
            guard lexer.word() == "xref" else {
                throw PDFStructureError.unsupported(L("compressed cross-reference stream. Save the document in PDF42 and sign the copy."))
            }
            while true {
                let w = lexer.word()
                if w == "trailer" { break }
                guard let first = Int(w), let count = Int(lexer.word()) else { throw PDFStructureError.malformed("xref") }
                for i in 0..<count {
                    guard let o = Int(lexer.word()), let g = Int(lexer.word()) else { throw PDFStructureError.malformed("xref") }
                    let type = lexer.word()
                    let num = first + i
                    if offsets[num] != nil || freed.contains(num) { continue }
                    if type == "n" { offsets[num] = (o, g) } else { freed.insert(num) }
                }
            }
            let t = try lexer.parse()
            if firstTrailer == nil { firstTrailer = t }
            next = t["Prev"]?.int
        }
        guard let firstTrailer else { throw PDFStructureError.malformed("trailer") }
        if firstTrailer["Encrypt"] != nil { throw PDFStructureError.unsupported(L("the document is encrypted")) }
        trailer = firstTrailer
    }

    func object(_ num: Int) throws -> PDFObject {
        guard let entry = offsets[num] else { throw PDFStructureError.malformed("no object \(num)") }
        var lexer = PDFLexer(bytes: bytes, pos: entry.offset)
        _ = lexer.word(); _ = lexer.word()
        try lexer.expect("obj")
        return try lexer.parse()
    }

    func resolve(_ obj: PDFObject?) throws -> PDFObject? {
        if case .ref(let n, _)? = obj { return try object(n) }
        return obj
    }

    func gen(_ num: Int) -> Int { offsets[num]?.gen ?? 0 }

    static func lastIndex(of s: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(s.utf8)
        var i = bytes.count - needle.count
        while i >= 0 {
            if bytes[i] == needle[0], Array(bytes[i..<i + needle.count]) == needle { return i }
            i -= 1
        }
        return nil
    }
}

/// PDF text string as UTF-16BE hex with BOM (safe for any language).
func pdfTextString(_ s: String) -> String {
    var hex = "<FEFF"
    for unit in s.utf16 { hex += String(format: "%04X", unit) }
    return hex + ">"
}

/// Decodes a raw PDF string token: "(literal)" or "<hex>", PDFDocEncoding or UTF-16BE.
func decodePDFString(_ raw: String) -> String {
    var bytes: [UInt8] = []
    if raw.hasPrefix("<") {
        let hex = raw.dropFirst().dropLast().filter { !$0.isWhitespace }
        var it = hex.makeIterator()
        while let a = it.next() {
            let b = it.next() ?? "0"
            if let v = UInt8(String([a, b]), radix: 16) { bytes.append(v) }
        }
    } else if raw.hasPrefix("(") {
        let body = Array(raw.utf8.dropFirst().dropLast())
        var i = 0
        while i < body.count {
            let c = body[i]
            if c == UInt8(ascii: "\\"), i + 1 < body.count {
                let n = body[i + 1]
                switch n {
                case UInt8(ascii: "n"): bytes.append(0x0A); i += 2
                case UInt8(ascii: "r"): bytes.append(0x0D); i += 2
                case UInt8(ascii: "t"): bytes.append(0x09); i += 2
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var j = i + 1, v = 0
                    while j < body.count, j < i + 4, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(body[j]) {
                        v = v * 8 + Int(body[j] - UInt8(ascii: "0")); j += 1
                    }
                    bytes.append(UInt8(v & 0xFF)); i = j
                default: bytes.append(n); i += 2
                }
            } else { bytes.append(c); i += 1 }
        }
    } else { return raw }
    if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
        return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
    }
    return String(bytes: bytes, encoding: .isoLatin1) ?? ""
}
