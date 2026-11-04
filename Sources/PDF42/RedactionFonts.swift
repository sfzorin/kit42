import CoreGraphics
import CoreText
import Foundation

/// What the redactor needs to know about a font to place every glyph of a text-showing operator:
/// how strings split into character codes, the advance of each code, the vertical extent, and
/// (only for reporting what was removed) the Unicode text.
final class RedactionFont {
    enum Kind { case simple, type0, type3 }
    let kind: Kind
    /// Why text in this font cannot be processed (vertical writing, unknown CMap…); nil when it can.
    private(set) var unsupported: String?
    /// Advances in thousandths of text space at size 1 (Type3 widths already scaled by the font matrix).
    private var widths: [UInt32: Double] = [:]
    private var defaultWidth: Double = 0
    /// Ascent and descent, same units.
    private(set) var ascent: Double = 800
    private(set) var descent: Double = -200
    private var toUnicode: [UInt32: String] = [:]
    /// Code space ranges (Type0 with an embedded CMap): byte length, low and high bytes.
    private var codeSpace: [(len: Int, lo: [UInt8], hi: [UInt8])] = []
    /// Code → CID (Type0 with an embedded CMap; identity when empty).
    private var cidRanges: [(lo: UInt32, hi: UInt32, cid: UInt32)] = []
    private var cidSingles: [UInt32: UInt32] = [:]
    private var simpleNames: [UInt32: String] = [:]
    private var baseEncoding: String.Encoding = .windowsCP1252
    /// Standard-14 fonts without /Widths: advances measured with the installed font.
    private var metricsFont: CTFont?
    private var measured: [UInt32: Double] = [:]

    init(_ font: CGPDFDictionaryRef) {
        let subtype = CGPDF.name(font, "Subtype") ?? "Type1"
        switch subtype {
        case "Type0": kind = .type0
        case "Type3": kind = .type3
        default: kind = .simple
        }
        if let tu = CGPDF.data(CGPDF.stream(font, "ToUnicode")) { parseToUnicode(tu.bytes) }
        switch kind {
        case .type0: setUpType0(font)
        case .type3: setUpType3(font)
        case .simple: setUpSimple(font)
        }
    }

    // MARK: Codes and widths

    /// Character codes of a string with their byte lengths.
    func codes(_ s: [UInt8]) -> [(code: UInt32, len: Int)] {
        guard kind == .type0 else { return s.map { (UInt32($0), 1) } }
        var out: [(UInt32, Int)] = []
        var i = 0
        while i < s.count {
            var len = codeSpace.isEmpty ? 2 : 0
            if !codeSpace.isEmpty {
                outer: for n in 1...4 where i + n <= s.count {
                    for r in codeSpace where r.len == n {
                        var inside = true
                        for k in 0..<n where s[i + k] < r.lo[k] || s[i + k] > r.hi[k] { inside = false; break }
                        if inside { len = n; break outer }
                    }
                }
                if len == 0 { len = 1 }
            }
            len = min(len, s.count - i)
            var code: UInt32 = 0
            for k in 0..<len { code = code << 8 | UInt32(s[i + k]) }
            out.append((code, len))
            i += len
        }
        return out
    }

    private func cid(_ code: UInt32) -> UInt32 {
        if cidRanges.isEmpty, cidSingles.isEmpty { return code }
        if let c = cidSingles[code] { return c }
        for r in cidRanges where code >= r.lo && code <= r.hi { return r.cid + (code - r.lo) }
        return 0
    }

    /// Advance of a code in thousandths of text space units.
    func width(_ code: UInt32) -> Double {
        if kind == .type0 { return widths[cid(code)] ?? defaultWidth }
        if let w = widths[code] { return w }
        if let font = metricsFont {
            if let w = measured[code] { return w }
            let w = measure(code, font)
            measured[code] = w
            return w
        }
        return defaultWidth
    }

    /// Text of a code (ToUnicode, else the simple font's encoding) for the report.
    func text(_ code: UInt32) -> String {
        if let s = toUnicode[code] { return s }
        guard kind != .type0 else { return "\u{FFFD}" }
        if let name = simpleNames[code], let s = Self.unicode(forGlyphName: name) { return s }
        return String(bytes: [UInt8(code & 0xFF)], encoding: baseEncoding) ?? "?"
    }

    // MARK: Set-up

    private func readFontDescriptor(_ fd: CGPDFDictionaryRef?, scale: Double = 1) {
        guard let fd else { return }
        var a = CGPDF.number(fd, "Ascent") ?? 0, d = CGPDF.number(fd, "Descent") ?? 0
        let bbox = CGPDF.numbers(CGPDF.array(fd, "FontBBox"))
        if a <= 0, bbox.count == 4 { a = bbox[3] }
        if d >= 0, bbox.count == 4 { d = bbox[1] }
        if a > 0 { ascent = min(1500, a * scale) }
        if d < 0 { descent = max(-800, d * scale) }
        if let mw = CGPDF.number(fd, "MissingWidth") { defaultWidth = mw * scale }
    }

    private func setUpType0(_ font: CGPDFDictionaryRef) {
        if let enc = CGPDF.name(font, "Encoding") {
            switch enc {
            case "Identity-H": break
            case "Identity-V": unsupported = "vertical text (Identity-V)"
            default: unsupported = "predefined CMap \(enc)"
            }
        } else if let s = CGPDF.stream(font, "Encoding") {
            if let wmode = CGPDF.number(CGPDFStreamGetDictionary(s), "WMode"), wmode == 1 { unsupported = "vertical text" }
            if let cmap = CGPDF.data(s) { parseCMap(cmap.bytes) }
            if codeSpace.isEmpty { unsupported = unsupported ?? "CMap without code space" }
        } else {
            unsupported = "Type0 font without encoding"
        }
        var arr: CGPDFArrayRef?
        var desc: CGPDFDictionaryRef?
        if CGPDFDictionaryGetArray(font, "DescendantFonts", &arr), let arr { CGPDFArrayGetDictionary(arr, 0, &desc) }
        guard let desc else { unsupported = unsupported ?? "Type0 font without descendant"; return }
        defaultWidth = CGPDF.number(desc, "DW") ?? 1000
        readFontDescriptor(CGPDF.dict(desc, "FontDescriptor"))
        if let w = CGPDF.array(desc, "W") {
            let n = CGPDFArrayGetCount(w)
            var i = 0
            while i < n {
                var first: CGPDFReal = 0
                guard CGPDFArrayGetNumber(w, i, &first) else { break }
                var list: CGPDFArrayRef?
                if CGPDFArrayGetArray(w, i + 1, &list), let list {
                    for (k, v) in CGPDF.numbers(list).enumerated() { widths[UInt32(first) + UInt32(k)] = v }
                    i += 2
                } else {
                    var last: CGPDFReal = 0, v: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(w, i + 1, &last), CGPDFArrayGetNumber(w, i + 2, &v), last >= first, last - first < 70000 else { break }
                    for c in UInt32(first)...UInt32(last) { widths[c] = Double(v) }
                    i += 3
                }
            }
        }
    }

    private func setUpType3(_ font: CGPDFDictionaryRef) {
        let m = CGPDF.numbers(CGPDF.array(font, "FontMatrix"))
        guard m.count == 6, abs(m[1]) < 1e-9, abs(m[2]) < 1e-9, m[0] != 0, m[3] != 0 else {
            unsupported = "Type3 font with a rotated or skewed matrix"
            return
        }
        let sx = m[0] * 1000, sy = m[3] * 1000
        let first = UInt32(max(0, CGPDF.number(font, "FirstChar") ?? 0))
        for (k, v) in CGPDF.numbers(CGPDF.array(font, "Widths")).enumerated() { widths[first + UInt32(k)] = v * sx }
        let bbox = CGPDF.numbers(CGPDF.array(font, "FontBBox"))
        if bbox.count == 4 {
            let a = max(bbox[1], bbox[3]) * sy, d = min(bbox[1], bbox[3]) * sy
            ascent = max(a, d); descent = min(a, d)
            if ascent - descent < 1 { ascent = 800; descent = -200 }
        }
        readEncoding(font)
    }

    private func setUpSimple(_ font: CGPDFDictionaryRef) {
        readFontDescriptor(CGPDF.dict(font, "FontDescriptor"))
        let first = UInt32(max(0, CGPDF.number(font, "FirstChar") ?? 0))
        let list = CGPDF.numbers(CGPDF.array(font, "Widths"))
        for (k, v) in list.enumerated() { widths[first + UInt32(k)] = v }
        readEncoding(font)
        if list.isEmpty {
            // Standard 14 font: measure with the installed font of that name.
            var base = CGPDF.name(font, "BaseFont") ?? "Helvetica"
            if let plus = base.firstIndex(of: "+") { base = String(base[base.index(after: plus)...]) }
            let known = ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Times-Roman", "Times-Bold",
                         "Times-Italic", "Times-BoldItalic", "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Symbol"]
            let lower = base.lowercased()
            if lower.hasPrefix("courier") { defaultWidth = 600; return }
            let name = known.contains(base) ? base : lower.contains("times") ? "Times-Roman" : lower.contains("zapf") ? "ZapfDingbatsITC" : base
            metricsFont = CTFontCreateWithName(name as CFString, 1000, nil)
            if CGPDF.dict(font, "FontDescriptor") == nil { ascent = 750; descent = -250 }
        }
    }

    private func readEncoding(_ font: CGPDFDictionaryRef) {
        var baseName = CGPDF.name(font, "Encoding")
        if let enc = CGPDF.dict(font, "Encoding") {
            baseName = CGPDF.name(enc, "BaseEncoding")
            if let diffs = CGPDF.array(enc, "Differences") {
                var code: UInt32 = 0
                for i in 0..<CGPDFArrayGetCount(diffs) {
                    var r: CGPDFReal = 0
                    if CGPDFArrayGetNumber(diffs, i, &r) { code = UInt32(max(0, r)); continue }
                    if let n = CGPDF.name(diffs, i) { simpleNames[code] = n; code += 1 }
                }
            }
        }
        if baseName == "MacRomanEncoding" { baseEncoding = .macOSRoman }
    }

    private func measure(_ code: UInt32, _ font: CTFont) -> Double {
        var glyph: CGGlyph = 0
        if let name = simpleNames[code] {
            glyph = CTFontGetGlyphWithName(font, name as CFString)
        }
        if glyph == 0 {
            let s = text(code)
            var chars = Array(s.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            if !chars.isEmpty, CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) { glyph = glyphs[0] }
        }
        guard glyph != 0 else { return 500 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, [glyph], &advance, 1)
        return Double(advance.width)
    }

    static func unicode(forGlyphName name: String) -> String? {
        if name.count == 1 { return name }
        if name.hasPrefix("uni"), name.count == 7, let v = UInt32(name.dropFirst(3), radix: 16), let s = UnicodeScalar(v) { return String(s) }
        let common = ["space": " ", "period": ".", "comma": ",", "hyphen": "-", "colon": ":", "semicolon": ";", "quoteright": "’",
                      "quoteleft": "‘", "parenleft": "(", "parenright": ")", "zero": "0", "one": "1", "two": "2", "three": "3",
                      "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        return common[name]
    }

    // MARK: CMaps

    private static func code(_ b: [UInt8]) -> UInt32 { b.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    private static func utf16(_ b: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < b.count { units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
        if b.count % 2 == 1 { units.append(UInt16(b[b.count - 1])) }
        return String(decoding: units, as: UTF16.self)
    }

    private func parseToUnicode(_ bytes: [UInt8]) {
        for op in ContentParser.operations(bytes) {
            let a = op.operands
            switch op.op {
            case "endbfchar":
                var i = 0
                while i + 1 < a.count {
                    if let src = a[i].bytes, let dst = a[i + 1].bytes { toUnicode[Self.code(src)] = Self.utf16(dst) }
                    i += 2
                }
            case "endbfrange":
                var i = 0
                while i + 2 < a.count {
                    defer { i += 3 }
                    guard let lo = a[i].bytes, let hi = a[i + 1].bytes else { continue }
                    let l = Self.code(lo), h = Self.code(hi)
                    guard h >= l, h - l < 65536 else { continue }
                    if let dst = a[i + 2].bytes, !dst.isEmpty {
                        var units: [UInt16] = []
                        var k = 0
                        while k + 1 < dst.count { units.append(UInt16(dst[k]) << 8 | UInt16(dst[k + 1])); k += 2 }
                        for c in l...h {
                            var u = units
                            if !u.isEmpty { u[u.count - 1] &+= UInt16(truncatingIfNeeded: c - l) }
                            toUnicode[c] = String(decoding: u, as: UTF16.self)
                        }
                    } else if let list = a[i + 2].items {
                        for (k, item) in list.enumerated() where l + UInt32(k) <= h {
                            if let dst = item.bytes { toUnicode[l + UInt32(k)] = Self.utf16(dst) }
                        }
                    }
                }
            default: break
            }
        }
    }

    private func parseCMap(_ bytes: [UInt8]) {
        for op in ContentParser.operations(bytes) {
            let a = op.operands
            switch op.op {
            case "endcodespacerange":
                var i = 0
                while i + 1 < a.count {
                    if let lo = a[i].bytes, let hi = a[i + 1].bytes, lo.count == hi.count, (1...4).contains(lo.count) {
                        codeSpace.append((lo.count, lo, hi))
                    }
                    i += 2
                }
            case "endcidrange":
                var i = 0
                while i + 2 < a.count {
                    if let lo = a[i].bytes, let hi = a[i + 1].bytes, let c = a[i + 2].number {
                        cidRanges.append((Self.code(lo), Self.code(hi), UInt32(max(0, c))))
                    }
                    i += 3
                }
            case "endcidchar":
                var i = 0
                while i + 1 < a.count {
                    if let src = a[i].bytes, let c = a[i + 1].number { cidSingles[Self.code(src)] = UInt32(max(0, c)) }
                    i += 2
                }
            case "usecmap":
                if a.first?.nameValue == "Identity-H" { codeSpace.append((2, [0, 0], [255, 255])) }
                else { unsupported = "CMap based on another CMap" }
            case "def":
                if a.count >= 2, a[0].nameValue == "WMode", a[1].number == 1 { unsupported = "vertical text" }
            default: break
            }
        }
    }
}
