import CoreGraphics
import Foundation

// Tokenizer for page content streams (and CMaps), keeping the byte range of every operation so
// unchanged operations can be copied verbatim when a stream is rewritten.

indirect enum CToken {
    case number(Double)
    case name(String)                   // as written, without the slash (#xx escapes kept)
    case string([UInt8])                // decoded bytes of a literal or hex string
    case array([CToken])
    case dict([(String, CToken)])
    case keyword(String)                // true, false, null inside operands

    var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    var nameValue: String? { if case .name(let n) = self { return n } else { return nil } }
    var bytes: [UInt8]? { if case .string(let b) = self { return b } else { return nil } }
    var items: [CToken]? { if case .array(let a) = self { return a } else { return nil } }

    subscript(key: String) -> CToken? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    var serialized: String {
        switch self {
        case .number(let n): return formatPDFNumber(n)
        case .name(let n): return "/" + n
        case .string(let b): return "<" + b.map { String(format: "%02X", $0) }.joined() + ">"
        case .array(let a): return "[" + a.map(\.serialized).joined(separator: " ") + "]"
        case .dict(let pairs): return "<<" + pairs.map { "/\($0.0) \($0.1.serialized)" }.joined(separator: " ") + ">>"
        case .keyword(let k): return k
        }
    }
}

func formatPDFNumber(_ v: Double) -> String {
    if v.isNaN || v.isInfinite { return "0" }
    if v == v.rounded(), abs(v) < 1e12 { return String(Int64(v)) }
    var s = String(format: "%.4f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

struct ContentOp {
    var operands: [CToken]
    var op: String
    /// Bytes of the whole operation (operands and operator) in the stream.
    var range: Range<Int>
}

struct ContentParser {
    let b: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { b = bytes }

    static func isWhite(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
    static func isDelimiter(_ c: UInt8) -> Bool {
        c == 0x28 || c == 0x29 || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2F || c == 0x25
    }

    /// All operations of the stream. Malformed bytes are skipped, never fatal.
    static func operations(_ bytes: [UInt8]) -> [ContentOp] {
        var p = ContentParser(bytes)
        return p.parseAll()
    }

    private mutating func skipWhite() {
        while i < b.count {
            if Self.isWhite(b[i]) { i += 1 }
            else if b[i] == 0x25 { while i < b.count, b[i] != 0x0A, b[i] != 0x0D { i += 1 } }
            else { break }
        }
    }

    private enum Item { case operand(CToken), op(String), end }

    private mutating func next() -> Item {
        skipWhite()
        guard i < b.count else { return .end }
        let c = b[i]
        switch c {
        case 0x28: return .operand(literalString())
        case 0x3C:
            if i + 1 < b.count, b[i + 1] == 0x3C { return .operand(dictionary()) }
            return .operand(hexString())
        case 0x5B:
            i += 1
            var items: [CToken] = []
            while true {
                skipWhite()
                guard i < b.count else { break }
                if b[i] == 0x5D { i += 1; break }
                switch next() {
                case .operand(let t): items.append(t)
                case .op(let k): items.append(.keyword(k))
                case .end: return .operand(.array(items))
                }
            }
            return .operand(.array(items))
        case 0x2F:
            i += 1
            let s = i
            while i < b.count, !Self.isWhite(b[i]), !Self.isDelimiter(b[i]) { i += 1 }
            return .operand(.name(String(decoding: b[s..<i], as: UTF8.self)))
        case 0x5D, 0x3E, 0x29, 0x7B, 0x7D:
            i += 1
            return .op(String(UnicodeScalar(c)))
        default:
            let s = i
            while i < b.count, !Self.isWhite(b[i]), !Self.isDelimiter(b[i]) { i += 1 }
            let word = String(decoding: b[s..<i], as: UTF8.self)
            if let first = word.utf8.first, first == 0x2B || first == 0x2D || first == 0x2E || (0x30...0x39).contains(first) {
                if let v = Double(word) { return .operand(.number(v)) }
                if word == "-" || word == "." { return .operand(.number(0)) }
                // "--5" and similar: be lenient like most readers
                if let v = Double(word.drop(while: { $0 == "-" || $0 == "+" })) { return .operand(.number(word.hasPrefix("-") ? -v : v)) }
            }
            if word == "true" || word == "false" || word == "null" { return .operand(.keyword(word)) }
            return .op(word)
        }
    }

    private mutating func literalString() -> CToken {
        i += 1
        var out: [UInt8] = []
        var depth = 1
        while i < b.count {
            let c = b[i]
            if c == 0x5C {
                i += 1
                guard i < b.count else { break }
                let n = b[i]
                switch n {
                case 0x6E: out.append(0x0A); i += 1
                case 0x72: out.append(0x0D); i += 1
                case 0x74: out.append(0x09); i += 1
                case 0x62: out.append(0x08); i += 1
                case 0x66: out.append(0x0C); i += 1
                case 0x0D: i += 1; if i < b.count, b[i] == 0x0A { i += 1 }
                case 0x0A: i += 1
                case 0x30...0x37:
                    var v = 0, k = 0
                    while k < 3, i < b.count, (0x30...0x37).contains(b[i]) { v = v * 8 + Int(b[i] - 0x30); i += 1; k += 1 }
                    out.append(UInt8(v & 0xFF))
                default: out.append(n); i += 1
                }
                continue
            }
            if c == 0x28 { depth += 1 }
            if c == 0x29 { depth -= 1; if depth == 0 { i += 1; break } }
            out.append(c)
            i += 1
        }
        return .string(out)
    }

    private mutating func hexString() -> CToken {
        i += 1
        var out: [UInt8] = []
        var high: UInt8?
        while i < b.count, b[i] != 0x3E {
            let c = b[i]
            i += 1
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            default: continue
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        if let h = high { out.append(h << 4) }
        i += 1
        return .string(out)
    }

    private mutating func dictionary() -> CToken {
        i += 2
        var pairs: [(String, CToken)] = []
        while true {
            skipWhite()
            guard i < b.count else { break }
            if b[i] == 0x3E {
                i += (i + 1 < b.count && b[i + 1] == 0x3E) ? 2 : 1
                break
            }
            guard case .operand(.name(let key)) = next() else { continue }
            switch next() {
            case .operand(let v): pairs.append((key, v))
            case .op(let k): pairs.append((key, .keyword(k)))
            case .end: return .dict(pairs)
            }
        }
        return .dict(pairs)
    }

    private mutating func parseAll() -> [ContentOp] {
        var ops: [ContentOp] = []
        var operands: [CToken] = []
        var start = 0
        while true {
            skipWhite()
            if operands.isEmpty { start = i }
            switch next() {
            case .end:
                return ops
            case .operand(let t):
                operands.append(t)
            case .op(let k):
                if k == "BI" {
                    ops.append(inlineImage(start: start))
                } else {
                    ops.append(ContentOp(operands: operands, op: k, range: start..<i))
                }
                operands = []
            }
        }
    }

    /// BI <dict pairs> ID <binary> EI, as one operation with the dictionary as operand.
    private mutating func inlineImage(start: Int) -> ContentOp {
        var pairs: [(String, CToken)] = []
        while true {
            let item = next()
            if case .op("ID") = item { break }
            guard case .operand(.name(let key)) = item else {
                if case .end = item { return ContentOp(operands: [.dict(pairs)], op: "BI", range: start..<i) }
                continue
            }
            if case .operand(let v) = next() { pairs.append((key, v)) }
        }
        if i < b.count, Self.isWhite(b[i]) { i += 1 }
        var j = i
        while j + 1 < b.count {
            if b[j] == 0x45, b[j + 1] == 0x49, j == i || Self.isWhite(b[j - 1]),
               j + 2 >= b.count || Self.isWhite(b[j + 2]) || Self.isDelimiter(b[j + 2]) { break }
            j += 1
        }
        i = min(b.count, j + 2)
        return ContentOp(operands: [.dict(pairs)], op: "BI", range: start..<i)
    }
}

// MARK: - CGPDF helpers

enum CGPDF {
    static func name(_ d: CGPDFDictionaryRef?, _ key: String) -> String? {
        guard let d else { return nil }
        var p: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(d, key, &p), let p else { return nil }
        return String(cString: p)
    }

    static func number(_ d: CGPDFDictionaryRef?, _ key: String) -> Double? {
        guard let d else { return nil }
        var r: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(d, key, &r) ? Double(r) : nil
    }

    static func bool(_ d: CGPDFDictionaryRef?, _ key: String) -> Bool {
        guard let d else { return false }
        var v: CGPDFBoolean = 0
        return CGPDFDictionaryGetBoolean(d, key, &v) && v != 0
    }

    static func dict(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFDictionaryRef? {
        guard let d else { return nil }
        var r: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &r) ? r : nil
    }

    static func array(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFArrayRef? {
        guard let d else { return nil }
        var r: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(d, key, &r) ? r : nil
    }

    static func stream(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFStreamRef? {
        guard let d else { return nil }
        var r: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(d, key, &r) ? r : nil
    }

    static func object(_ d: CGPDFDictionaryRef?, _ key: String) -> CGPDFObjectRef? {
        guard let d else { return nil }
        var r: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(d, key, &r) ? r : nil
    }

    static func numbers(_ a: CGPDFArrayRef?) -> [Double] {
        guard let a else { return [] }
        return (0..<CGPDFArrayGetCount(a)).map { i in
            var r: CGPDFReal = 0
            return CGPDFArrayGetNumber(a, i, &r) ? Double(r) : 0
        }
    }

    static func name(_ a: CGPDFArrayRef, _ i: Int) -> String? {
        var p: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(a, i, &p), let p else { return nil }
        return String(cString: p)
    }

    static func data(_ s: CGPDFStreamRef?) -> (bytes: [UInt8], format: CGPDFDataFormat)? {
        guard let s else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(s, &format) else { return nil }
        return ([UInt8](data as Data), format)
    }

    static func bytes(_ s: CGPDFStringRef) -> [UInt8] {
        guard let p = CGPDFStringGetBytePtr(s) else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)))
    }

    /// Dictionary looked up on a page and then its /Parent chain (inherited /Resources).
    static func inherited(_ page: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page
        var depth = 0
        while let n = node, depth < 64 {
            if let d = dict(n, key) { return d }
            node = dict(n, "Parent")
            depth += 1
        }
        return nil
    }

    static func matrix(_ a: CGPDFArrayRef?) -> CGAffineTransform? {
        let n = numbers(a)
        guard n.count == 6 else { return nil }
        return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }
}

/// zlib stream (header + raw deflate + Adler-32), i.e. what /FlateDecode expects.
func zlibCompress(_ bytes: [UInt8]) -> [UInt8]? {
    guard let raw = try? (Data(bytes) as NSData).compressed(using: .zlib) as Data else { return nil }
    var a: UInt32 = 1, b: UInt32 = 0
    var k = 0
    while k < bytes.count {
        let end = min(bytes.count, k + 5552)
        for j in k..<end { a += UInt32(bytes[j]); b += a }
        a %= 65521; b %= 65521
        k = end
    }
    let adler = b << 16 | a
    return [0x78, 0x9C] + [UInt8](raw) + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
}
