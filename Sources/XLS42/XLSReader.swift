import AppKit
import Kit42

/// Reader for legacy Excel 97–2003 workbooks (.xls, BIFF8 in an OLE2 compound file).
/// Values, formatting, widths/heights, merges, freeze panes, comments, names and formulas
/// (decompiled from Excel's parsed tokens; if a formula can't be decoded, its cached value is kept).
enum XLSReader {
    enum XLSError: LocalizedError {
        case notCompound, noWorkbook, biff5, corrupt
        var errorDescription: String? {
            switch self {
            case .notCompound: return L("The file is not an Excel 97–2003 workbook")
            case .noWorkbook: return L("The file contains no workbook")
            case .biff5: return L("Excel 5.0/95 workbooks are not supported; save as .xls 97–2003 or .xlsx")
            case .corrupt: return L("The file is damaged")
            }
        }
    }

    // MARK: - Compound file (OLE2)

    struct CompoundFile {
        let b: [UInt8]
        let sectorSize: Int
        let miniSectorSize: Int
        let miniCutoff: Int
        var fat: [UInt32] = []
        var miniFat: [UInt32] = []
        var entries: [(name: String, type: UInt8, start: UInt32, size: Int)] = []
        var miniStream: [UInt8] = []

        static func le32(_ a: [UInt8], _ i: Int) -> UInt32 {
            guard i + 3 < a.count else { return 0 }
            let b0 = UInt32(a[i]), b1 = UInt32(a[i + 1]) << 8, b2 = UInt32(a[i + 2]) << 16, b3 = UInt32(a[i + 3]) << 24
            return b0 | b1 | b2 | b3
        }

        func u32(_ i: Int) -> UInt32 { Self.le32(b, i) }

        init(_ data: Data) throws {
            let b = [UInt8](data)
            guard b.count >= 512, Array(b[0..<8]) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] else { throw XLSError.notCompound }
            let shift = Int(b[30]) | Int(b[31]) << 8
            let miniShift = Int(b[32]) | Int(b[33]) << 8
            let cutoff = Int(Self.le32(b, 56))
            guard (7...16).contains(shift), (2...12).contains(miniShift) else { throw XLSError.corrupt }
            try self.init(bytes: b, sector: 1 << shift, mini: 1 << miniShift, cutoff: cutoff)
        }

        private init(bytes: [UInt8], sector: Int, mini: Int, cutoff: Int) throws {
            b = bytes
            sectorSize = sector
            miniSectorSize = mini
            miniCutoff = cutoff
            let numFat = Int(u32(44)), dirStart = u32(48), miniFatStart = u32(60), difatStart = u32(68), numDifat = Int(u32(72))
            var difat: [UInt32] = (0..<109).map { u32(76 + $0 * 4) }
            var next = difatStart
            var guardCount = 0
            while guardCount < numDifat, next < 0xFFFFFFFA {
                let off = (Int(next) + 1) * sectorSize
                let per = sectorSize / 4 - 1
                difat += (0..<per).map { u32(off + $0 * 4) }
                next = u32(off + per * 4)
                guardCount += 1
            }
            for id in difat.prefix(numFat) where id < 0xFFFFFFFA {
                let off = (Int(id) + 1) * sectorSize
                fat += (0..<(sectorSize / 4)).map { u32(off + $0 * 4) }
            }
            let dir = readChain(dirStart, size: nil)
            var i = 0
            while i + 128 <= dir.count {
                let nameLen = max(0, (Int(dir[i + 64]) | Int(dir[i + 65]) << 8) - 2)
                let name = String(bytes: dir[i..<(i + min(64, nameLen))], encoding: .utf16LittleEndian) ?? ""
                let start = Self.le32(dir, i + 116)
                let size = Int(Self.le32(dir, i + 120))
                entries.append((name, dir[i + 66], start, size))
                i += 128
            }
            guard let root = entries.first else { throw XLSError.corrupt }
            miniStream = readChain(root.start, size: root.size)
            let mf = readChain(miniFatStart, size: nil)
            miniFat = stride(from: 0, to: mf.count - 3, by: 4).map { Self.le32(mf, $0) }
        }

        func readChain(_ start: UInt32, size: Int?) -> [UInt8] {
            var out: [UInt8] = []
            var s = start
            var seen = 0
            while s < 0xFFFFFFFA, Int(s) < fat.count || fat.isEmpty, seen < 1_000_000 {
                let off = (Int(s) + 1) * sectorSize
                guard off + sectorSize <= b.count else { break }
                out += b[off..<(off + sectorSize)]
                if let size, out.count >= size { break }
                guard Int(s) < fat.count else { break }
                s = fat[Int(s)]
                seen += 1
            }
            if let size, out.count > size { out.removeLast(out.count - size) }
            return out
        }

        func stream(_ names: [String]) -> [UInt8]? {
            guard let e = entries.first(where: { e in names.contains { $0.caseInsensitiveCompare(e.name) == .orderedSame } && e.type == 2 }) else { return nil }
            if e.size >= miniCutoff { return readChain(e.start, size: e.size) }
            var out: [UInt8] = []
            var s = e.start
            var seen = 0
            while s < 0xFFFFFFFA, Int(s) < miniFat.count, seen < 1_000_000 {
                let off = Int(s) * miniSectorSize
                guard off + miniSectorSize <= miniStream.count else { break }
                out += miniStream[off..<(off + miniSectorSize)]
                if out.count >= e.size { break }
                s = miniFat[Int(s)]
                seen += 1
            }
            return Array(out.prefix(e.size))
        }
    }

    // MARK: - BIFF records

    struct Record { let type: Int; let data: [UInt8]; let offset: Int }

    static func records(_ s: [UInt8], from start: Int) -> [Record] {
        var out: [Record] = []
        var p = start
        var depth = 0
        while p + 4 <= s.count {
            let type = Int(s[p]) | Int(s[p + 1]) << 8
            let len = Int(s[p + 2]) | Int(s[p + 3]) << 8
            guard p + 4 + len <= s.count else { break }
            p += 4 + len
            // Embedded substreams (charts) have their own BOF…EOF: skip their records.
            if type == 0x0809 { depth += 1; if depth > 1 { continue } }
            if type == 0x000A { depth -= 1; if depth > 0 { continue }; out.append(Record(type: type, data: [], offset: p)); break }
            if depth > 1 { continue }
            out.append(Record(type: type, data: Array(s[(p - len)..<p]), offset: p - len - 4))
        }
        return out
    }

    /// Reads across a record and its CONTINUE records; strings resume with a new flags byte.
    struct Reader {
        var segments: [[UInt8]]
        var seg = 0
        var pos = 0

        init(_ segments: [[UInt8]]) { self.segments = segments }

        var atEnd: Bool { seg >= segments.count || (seg == segments.count - 1 && pos >= segments[seg].count) }

        mutating func advanceIfNeeded() {
            while seg < segments.count, pos >= segments[seg].count { seg += 1; pos = 0 }
        }

        mutating func u8() -> Int {
            advanceIfNeeded()
            guard seg < segments.count else { return 0 }
            defer { pos += 1 }
            return Int(segments[seg][pos])
        }

        mutating func u16() -> Int { u8() | u8() << 8 }
        mutating func u32() -> Int { u16() | u16() << 16 }
        mutating func skip(_ n: Int) { for _ in 0..<max(0, n) { _ = u8() } }

        /// XLUnicodeRichExtendedString (SST) or XLUnicodeString. Character data continued in the
        /// next CONTINUE record starts with a fresh flags byte (8- or 16-bit characters).
        mutating func string(cch: Int? = nil) -> String {
            let count = cch ?? u16()
            var flags = u8()
            let rich = flags & 0x08 != 0, ext = flags & 0x04 != 0
            let runs = rich ? u16() : 0
            let extLen = ext ? u32() : 0
            var units: [UInt16] = []
            units.reserveCapacity(count)
            while units.count < count, seg < segments.count {
                if pos >= segments[seg].count {
                    seg += 1
                    pos = 0
                    guard seg < segments.count, !segments[seg].isEmpty else { break }
                    flags = Int(segments[seg][0])
                    pos = 1
                    continue
                }
                if flags & 0x01 != 0 {
                    guard pos + 1 < segments[seg].count else { pos = segments[seg].count; continue }
                    units.append(UInt16(segments[seg][pos]) | UInt16(segments[seg][pos + 1]) << 8)
                    pos += 2
                } else {
                    units.append(UInt16(segments[seg][pos]))
                    pos += 1
                }
            }
            skip(runs * 4)
            skip(extLen)
            return String(utf16CodeUnits: units, count: units.count)
        }
    }

    static func u16(_ d: [UInt8], _ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) | Int(d[i + 1]) << 8 : 0 }
    static func i16(_ d: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(d, i)))) }
    static func u32(_ d: [UInt8], _ i: Int) -> Int { u16(d, i) | u16(d, i + 2) << 16 }
    static func double(_ d: [UInt8], _ i: Int) -> Double {
        guard i + 8 <= d.count else { return 0 }
        var bits: UInt64 = 0
        for k in 0..<8 { bits |= UInt64(d[i + k]) << (8 * k) }
        return Double(bitPattern: bits)
    }

    static func rk(_ v: Int) -> Double {
        let x = UInt32(truncatingIfNeeded: v)
        var d: Double
        if x & 0x02 != 0 { d = Double(Int32(bitPattern: x) >> 2) }
        else { d = Double(bitPattern: UInt64(x & 0xFFFF_FFFC) << 32) }
        if x & 0x01 != 0 { d /= 100 }
        return d
    }

    /// Short string inside a record (cch already read or 8-bit count).
    static func shortString(_ d: [UInt8], at i: Int, cch: Int) -> (String, Int) {
        guard i < d.count else { return ("", i) }
        let high = d[i] & 0x01 != 0
        var p = i + 1
        var units: [UInt16] = []
        for _ in 0..<cch {
            if high { guard p + 1 < d.count else { break }; units.append(UInt16(d[p]) | UInt16(d[p + 1]) << 8); p += 2 }
            else { guard p < d.count else { break }; units.append(UInt16(d[p])); p += 1 }
        }
        return (String(utf16CodeUnits: units, count: units.count), p)
    }

    // MARK: - Workbook

    struct Font { var name = "Arial"; var size: CGFloat = 10; var bold = false; var italic = false; var underline = false; var strike = false; var color: Int = 0x7FFF }

    struct Globals {
        var fonts: [Font] = []
        var formats: [Int: String] = [:]
        var xfs: [[UInt8]] = []
        var palette: [NSColor] = []
        var sst: [String] = []
        var sheets: [(name: String, offset: Int)] = []
        var date1904 = false
        var externSheets: [(book: Int, first: Int, last: Int)] = []
        var externNames: [String] = []
        var names: [String] = []
        var styles: [CellStyle] = []
    }

    static func read(_ data: Data) throws -> Workbook {
        let cf = try CompoundFile(data)
        guard let stream = cf.stream(["Workbook", "Book"]) else { throw XLSError.noWorkbook }
        let globalRecords = records(stream, from: 0)
        guard let bof = globalRecords.first, bof.type == 0x0809, u16(bof.data, 0) == 0x0600 else {
            if globalRecords.first?.type == 0x0809 { throw XLSError.biff5 }
            throw XLSError.corrupt
        }
        var g = Globals()
        g.palette = XLSX.indexedColors.compactMap { XLSX.hexColor($0) }
        var nameRecords: [[UInt8]] = []
        var i = 0
        while i < globalRecords.count {
            let r = globalRecords[i]
            let d = r.data
            switch r.type {
            case 0x0031:   // FONT
                var f = Font()
                f.size = CGFloat(u16(d, 0)) / 20
                let grbit = u16(d, 2)
                f.italic = grbit & 0x02 != 0
                f.strike = grbit & 0x08 != 0
                f.color = u16(d, 4)
                f.bold = u16(d, 6) >= 700
                f.underline = d.count > 10 && d[10] != 0
                if d.count > 14 { f.name = shortString(d, at: 15, cch: Int(d[14])).0 }
                g.fonts.append(f)
                if g.fonts.count == 4 { g.fonts.append(f) }   // index 4 does not exist in BIFF
            case 0x041E:   // FORMAT
                let idx = u16(d, 0)
                g.formats[idx] = shortString(d, at: 4, cch: u16(d, 2)).0
            case 0x00E0: g.xfs.append(d)   // XF
            case 0x0092:   // PALETTE
                let n = u16(d, 0)
                for k in 0..<n where 2 + k * 4 + 2 < d.count {
                    let c = NSColor(srgbRed: CGFloat(d[2 + k * 4]) / 255, green: CGFloat(d[3 + k * 4]) / 255, blue: CGFloat(d[4 + k * 4]) / 255, alpha: 1)
                    if 8 + k < g.palette.count { g.palette[8 + k] = c }
                }
            case 0x00FC:   // SST + CONTINUE
                var segs = [Array(d.dropFirst(8))]
                var j = i + 1
                while j < globalRecords.count, globalRecords[j].type == 0x003C { segs.append(globalRecords[j].data); j += 1 }
                var rd = Reader(segs)
                let unique = u32(d, 4)
                g.sst.reserveCapacity(unique)
                for _ in 0..<unique where !rd.atEnd { g.sst.append(rd.string()) }
            case 0x0085:   // BOUNDSHEET
                if d.count > 7, d[5] == 0 {   // worksheets only
                    g.sheets.append((shortString(d, at: 7, cch: Int(d[6])).0, u32(d, 0)))
                }
            case 0x0022: g.date1904 = u16(d, 0) == 1
            case 0x0017:   // EXTERNSHEET
                let n = u16(d, 0)
                for k in 0..<n { g.externSheets.append((u16(d, 2 + k * 6), u16(d, 4 + k * 6), u16(d, 6 + k * 6))) }
            case 0x0023:   // EXTERNNAME
                if d.count > 7 { g.externNames.append(shortString(d, at: 7, cch: Int(d[6])).0) }
            case 0x0018: nameRecords.append(d)
            default: break
            }
            i += 1
        }
        g.styles = g.xfs.map { style($0, g) }

        var wb = Workbook()
        wb.sheets = []
        wb.date1904 = g.date1904
        // Names: plain text first (used by formulas), definitions decoded after sheets are known.
        for d in nameRecords {
            let builtin = u16(d, 0) & 0x20 != 0
            let cch = d.count > 3 ? Int(d[3]) : 0
            let (raw, _) = shortString(d, at: 14, cch: cch)
            g.names.append(builtin ? "_xlnm." + builtinName(raw) : raw)
        }
        for (name, offset) in g.sheets {
            var sheet = Sheet(name: name)
            readSheet(stream, offset: offset, globals: g, into: &sheet)
            wb.sheets.append(sheet)
        }
        // Defined names and print areas
        for (k, d) in nameRecords.enumerated() {
            let cce = u16(d, 4), itab = u16(d, 8), cch = d.count > 3 ? Int(d[3]) : 0
            let (_, end) = shortString(d, at: 14, cch: cch)
            guard end + cce <= d.count else { continue }
            let rgce = Array(d[end..<(end + cce)])
            guard let text = Formula42.decode(rgce, at: CellRef(row: 0, col: 0), globals: g, sheetNames: g.sheets.map(\.name)) else { continue }
            let name = g.names[k]
            if name == "_xlnm.Print_Area", itab > 0, itab <= wb.sheets.count {
                let part = text.split(separator: ",").first.map(String.init) ?? text
                wb.sheets[itab - 1].printArea = CellRange((part.split(separator: "!").last.map(String.init) ?? part).replacingOccurrences(of: "$", with: ""))
            } else if !name.hasPrefix("_xlnm.") {
                wb.names[name] = text
            }
        }
        if wb.sheets.isEmpty { wb.sheets = [Sheet(name: "Sheet1")] }
        return wb
    }

    static func builtinName(_ raw: String) -> String {
        let names = ["Consolidate_Area", "Auto_Open", "Auto_Close", "Extract", "Database", "Criteria", "Print_Area", "Print_Titles",
                     "Recorder", "Data_Form", "Auto_Activate", "Auto_Deactivate", "Sheet_Title", "_FilterDatabase"]
        guard let c = raw.unicodeScalars.first, Int(c.value) < names.count else { return raw }
        return names[Int(c.value)]
    }

    static func color(_ index: Int, _ g: Globals) -> NSColor? {
        if index == 0x7FFF || index == 64 || index == 65 || index < 0 { return nil }
        return index < g.palette.count ? g.palette[index] : nil
    }

    static func style(_ d: [UInt8], _ g: Globals) -> CellStyle {
        var s = CellStyle()
        let fontIndex = u16(d, 0)
        if fontIndex < g.fonts.count {
            let f = g.fonts[fontIndex]
            s.fontName = f.name
            s.fontSize = f.size
            s.bold = f.bold
            s.italic = f.italic
            s.underline = f.underline
            s.strike = f.strike
            if let c = color(f.color, g), c != g.palette.first { s.textColor = c }
        }
        let fmt = u16(d, 2)
        s.numberFormat = g.formats[fmt] ?? NumberFormat.builtin[fmt] ?? "General"
        guard d.count >= 20 else { return s }
        let align = Int(d[6])
        s.hAlign = [nil, "left", "center", "right", "fill", "justify", "centerContinuous", "distributed"][align & 0x07]
        s.wrap = align & 0x08 != 0
        s.vAlign = ["top", "center", "bottom", "justify"][min(3, (align >> 4) & 0x07)]
        s.indent = Int(d[8]) & 0x0F
        let border = u32(d, 10), border2 = u32(d, 14), fill = u16(d, 18)
        let styles = [nil, "thin", "medium", "dashed", "dotted", "thick", "double", "hair", "mediumDashed", "dashDot", "mediumDashDot", "dashDotDot", "mediumDashDotDot", "slantDashDot"]
        func side(_ style: Int, _ colorIndex: Int) -> BorderSide? {
            guard style > 0, style < styles.count, let name = styles[style] else { return nil }
            return BorderSide(style: name, color: color(colorIndex, g) ?? .black)
        }
        s.left = side(border & 0x0F, (border >> 16) & 0x7F)
        s.right = side((border >> 4) & 0x0F, (border >> 23) & 0x7F)
        s.top = side((border >> 8) & 0x0F, border2 & 0x7F)
        s.bottom = side((border >> 12) & 0x0F, (border2 >> 7) & 0x7F)
        let pattern = (border2 >> 26) & 0x3F
        if pattern == 1 { s.fill = color(fill & 0x7F, g) }
        else if pattern > 1 { s.fill = color(fill & 0x7F, g)?.withAlphaComponent(0.5) }
        return s
    }

    // MARK: - Worksheet

    static func readSheet(_ stream: [UInt8], offset: Int, globals g: Globals, into sheet: inout Sheet) {
        let recs = records(stream, from: offset)
        var shared: [(range: CellRange, rgce: [UInt8])] = []
        var pendingFormulas: [(CellRef, [UInt8], Int)] = []   // cell, rgce, xf
        var lastFormula: CellRef?
        var objTexts: [Int: String] = [:]
        var lastObjId: Int?
        var notes: [(CellRef, Int)] = []

        func put(_ ref: CellRef, _ value: Value, xf: Int) {
            var cell = Cell()
            if xf < g.styles.count { cell.style = g.styles[xf] }
            cell.value = value
            cell.input = XLSX.inputText(for: value, style: cell.style)
            if case .string(let str) = value, XLSX.constant(str) != .string(str) || str.hasPrefix("=") { cell.input = "'" + str }
            sheet[ref] = cell
        }

        var i = 0
        while i < recs.count {
            let r = recs[i]
            let d = r.data
            let row = u16(d, 0), col = u16(d, 2), xf = u16(d, 4)
            let ref = CellRef(row: row, col: col)
            switch r.type {
            case 0x00FD: put(ref, .string(u32(d, 6) < g.sst.count ? g.sst[u32(d, 6)] : ""), xf: xf)                           // LABELSST
            case 0x0204: put(ref, .string(shortString(d, at: 8, cch: u16(d, 6)).0), xf: xf)                                     // LABEL
            case 0x0203: put(ref, .number(double(d, 6)), xf: xf)                                                                // NUMBER
            case 0x027E: put(ref, .number(rk(u32(d, 6))), xf: xf)                                                               // RK
            case 0x00BD:                                                                                                         // MULRK
                let last = u16(d, d.count - 2)
                if last >= col {
                    for (k, c) in (col...last).enumerated() { put(CellRef(row: row, col: c), .number(rk(u32(d, 6 + k * 6))), xf: u16(d, 4 + k * 6)) }
                }
            case 0x0201:                                                                                                         // BLANK
                if xf < g.styles.count, g.styles[xf] != .default { var c = Cell(); c.style = g.styles[xf]; sheet[ref] = c }
            case 0x00BE:                                                                                                         // MULBLANK
                let last = u16(d, d.count - 2)
                if last >= col {
                    for (k, c) in (col...last).enumerated() {
                        let x = u16(d, 4 + k * 2)
                        if x < g.styles.count, g.styles[x] != .default { var cell = Cell(); cell.style = g.styles[x]; sheet[CellRef(row: row, col: c)] = cell }
                    }
                }
            case 0x0205:                                                                                                         // BOOLERR
                put(ref, d.count > 7 && d[7] == 1 ? .error(errorName(Int(d[6]))) : .bool(d.count > 6 && d[6] != 0), xf: xf)
            case 0x0006:                                                                                                         // FORMULA
                var value: Value = .number(double(d, 6))
                if d.count > 13, d[12] == 0xFF, d[13] == 0xFF {
                    switch d[6] {
                    case 0:   // string in the following STRING record
                        var str = ""
                        if i + 1 < recs.count, recs[i + 1].type == 0x0207 { str = shortString(recs[i + 1].data, at: 2, cch: u16(recs[i + 1].data, 0)).0 }
                        value = .string(str)
                    case 1: value = .bool(d[8] != 0)
                    case 2: value = .error(errorName(Int(d[8])))
                    default: value = .string("")
                    }
                }
                put(ref, value, xf: xf)
                let cce = u16(d, 20)
                if 22 + cce <= d.count { pendingFormulas.append((ref, Array(d[22..<(22 + cce)]), xf)) }
                lastFormula = ref
            case 0x04BC:                                                                                                         // SHRFMLA
                let range = CellRange(CellRef(row: u16(d, 0), col: Int(d[4])), CellRef(row: u16(d, 2), col: Int(d[5])))
                let cce = u16(d, 8)
                if 10 + cce <= d.count { shared.append((range, Array(d[10..<(10 + cce)]))) }
            case 0x0221:                                                                                                         // ARRAY
                let range = CellRange(CellRef(row: u16(d, 0), col: Int(d[4])), CellRef(row: u16(d, 2), col: Int(d[5])))
                let cce = u16(d, 12)
                if 14 + cce <= d.count { shared.append((range, Array(d[14..<(14 + cce)]))) }
                _ = lastFormula
            case 0x007D:                                                                                                         // COLINFO
                let first = u16(d, 0), last = min(u16(d, 2), first + 300), width = u16(d, 4), hidden = u16(d, 8) & 0x01 != 0
                let level = min(Sheet.maxOutlineLevel, (u16(d, 8) >> 8) & 0x07)
                if last >= first {
                    for c in first...last {
                        sheet.columnWidths[c] = hidden && level == 0 ? 0 : XLSX.columnPoints(Double(width) / 256)
                        if level > 0 { sheet.colLevels[c] = level; if hidden { sheet.outlineHiddenCols.insert(c) } }
                    }
                }
            case 0x0055: sheet.defaultColumnWidth = XLSX.columnPoints(Double(u16(d, 0)) + 0.71)                                // DEFCOLWIDTH
            case 0x0225: if u16(d, 2) > 0 { sheet.defaultRowHeight = CGFloat(u16(d, 2)) / 20 }                                   // DEFAULTROWHEIGHT
            case 0x0208:                                                                                                         // ROW
                let height = u16(d, 6) & 0x7FFF, grbit = u16(d, 12), level = grbit & 0x07
                if level > 0 { sheet.rowLevels[row] = level }
                if grbit & 0x20 != 0, level > 0 { sheet.outlineHiddenRows.insert(row) }
                else if grbit & 0x20 != 0 { sheet.rowHeights[row] = 0 }
                else if grbit & 0x40 != 0 || CGFloat(height) / 20 != sheet.defaultRowHeight { sheet.rowHeights[row] = CGFloat(height) / 20 }
            case 0x00E5:                                                                                                         // MERGEDCELLS
                let n = u16(d, 0)
                for k in 0..<n {
                    let p = 2 + k * 8
                    sheet.merges.append(CellRange(CellRef(row: u16(d, p), col: u16(d, p + 4)), CellRef(row: u16(d, p + 2), col: u16(d, p + 6))))
                }
            case 0x023E: sheet.showGridlines = u16(d, 0) & 0x02 != 0                                                             // WINDOW2
            case 0x0041:                                                                                                         // PANE
                if let w2 = recs.first(where: { $0.type == 0x023E }), u16(w2.data, 0) & 0x08 != 0 {
                    sheet.frozenCols = u16(d, 0)
                    sheet.frozenRows = u16(d, 2)
                }
            case 0x005D:                                                                                                         // OBJ (id for notes)
                lastObjId = u16(d, 0) == 0x15 ? u16(d, 6) : nil
            case 0x01B6:                                                                                                         // TXO + CONTINUE text
                if let id = lastObjId, i + 1 < recs.count, recs[i + 1].type == 0x003C {
                    let cch = u16(d, 10)
                    var rd = Reader([recs[i + 1].data])
                    objTexts[id] = rd.string(cch: cch)
                }
            case 0x001C:                                                                                                         // NOTE
                notes.append((ref, u16(d, 6)))
            default: break
            }
            i += 1
        }
        for (ref, id) in notes { if let text = objTexts[id] { sheet.comments[ref] = text } }

        // Formulas: decode tokens (shared/array formulas resolved via their master record).
        let names = g.sheets.map(\.name)
        for (ref, rgce, _) in pendingFormulas {
            var tokens = rgce
            var base = ref
            if tokens.first == 0x01, tokens.count >= 5 {
                let master = CellRef(row: u16(tokens, 1), col: u16(tokens, 3))
                guard let s = shared.first(where: { $0.range.contains(ref) && $0.range.start == master }) ?? shared.first(where: { $0.range.contains(ref) })
                else { continue }
                tokens = s.rgce
                base = ref
            }
            guard let text = Formula42.decode(tokens, at: base, globals: g, sheetNames: names),
                  (try? Formula.parse("=" + text)) != nil else { continue }
            sheet.cells[ref]?.input = "=" + text
        }
    }

    static func errorName(_ code: Int) -> String {
        [0x00: "#NULL!", 0x07: "#DIV/0!", 0x0F: "#VALUE!", 0x17: "#REF!", 0x1D: "#NAME?", 0x24: "#NUM!", 0x2A: "#N/A"][code] ?? "#VALUE!"
    }
}

/// Decompiles BIFF8 parsed formula tokens (RPN) to formula text.
enum Formula42 {
    static func decode(_ t: [UInt8], at cell: CellRef, globals g: XLSReader.Globals, sheetNames: [String]) -> String? {
        var stack: [String] = []
        var p = 0
        func u16() -> Int { defer { p += 2 }; return XLSReader.u16(t, p) }
        func pop() -> String? { stack.popLast() }
        func colText(_ c: Int, abs: Bool) -> String { (abs ? "$" : "") + CellRef.columnName(max(0, min(16383, c))) }
        func rowText(_ r: Int, abs: Bool) -> String { (abs ? "$" : "") + "\(max(0, r) + 1)" }
        func ref(_ row: Int, _ colField: Int, relative: Bool) -> String {
            let colRel = colField & 0x4000 != 0, rowRel = colField & 0x8000 != 0
            var c = colField & 0x3FFF, r = row
            if relative {
                if colRel { c = cell.col + Int(Int8(bitPattern: UInt8(c & 0xFF))) }
                if rowRel { r = cell.row + Int(Int16(bitPattern: UInt16(row))) }
            }
            return colText(c, abs: !colRel) + rowText(r, abs: !rowRel)
        }
        func sheetPrefix(_ ixti: Int) -> String {
            guard ixti < g.externSheets.count else { return "" }
            let x = g.externSheets[ixti]
            guard x.first < sheetNames.count else { return "#REF!" }
            return Formula.sheetPrefix(sheetNames[x.first])
        }
        let binary: [UInt8: String] = [0x03: "+", 0x04: "-", 0x05: "*", 0x06: "/", 0x07: "^", 0x08: "&", 0x09: "<", 0x0A: "<=",
                                       0x0B: "=", 0x0C: ">=", 0x0D: ">", 0x0E: "<>", 0x0F: " ", 0x10: ",", 0x11: ":"]
        while p < t.count {
            let tag = t[p]
            p += 1
            let id = tag < 0x20 ? tag : (tag & 0x1F) | 0x20
            if let op = binary[id] {
                guard let b = pop(), let a = pop() else { return nil }
                stack.append(a + op + b)
                continue
            }
            switch id {
            case 0x01, 0x02: return nil
            case 0x12: guard let a = pop() else { return nil }; stack.append("+" + a)
            case 0x13: guard let a = pop() else { return nil }; stack.append("-" + a)
            case 0x14: guard let a = pop() else { return nil }; stack.append(a + "%")
            case 0x15: guard let a = pop() else { return nil }; stack.append("(" + a + ")")
            case 0x16: stack.append("")
            case 0x17:
                guard p < t.count else { return nil }
                let cch = Int(t[p]); p += 1
                let (s, end) = XLSReader.shortString(t, at: p, cch: cch)
                p = end
                stack.append("\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
            case 0x19:
                guard p + 2 < t.count else { return nil }
                let grbit = t[p]; p += 1
                let data = u16()
                if grbit & 0x04 != 0 { p += (data + 1) * 2 }           // attrChoose jump table
                if grbit & 0x10 != 0, let a = pop() { stack.append("SUM(" + a + ")") }
            case 0x1C: guard p < t.count else { return nil }; stack.append(XLSReader.errorName(Int(t[p]))); p += 1
            case 0x1D: guard p < t.count else { return nil }; stack.append(t[p] != 0 ? "TRUE" : "FALSE"); p += 1
            case 0x1E: stack.append("\(u16())")
            case 0x1F: stack.append(Value.formatGeneral(XLSReader.double(t, p))); p += 8
            case 0x21:
                let f = u16()
                guard let (name, argc) = functions[f], argc >= 0, stack.count >= argc else { return nil }
                let args = Array(stack.suffix(argc)); stack.removeLast(argc)
                stack.append(name + "(" + args.joined(separator: ",") + ")")
            case 0x22:
                guard p < t.count else { return nil }
                let argc = Int(t[p] & 0x7F); p += 1
                let f = u16() & 0x7FFF
                guard stack.count >= argc else { return nil }
                var args = Array(stack.suffix(argc)); stack.removeLast(argc)
                var name: String
                if f == 255, !args.isEmpty { name = args.removeFirst().replacingOccurrences(of: "_xlfn.", with: "") }
                else { guard let n = functions[f]?.0 else { return nil }; name = n }
                stack.append(name + "(" + args.joined(separator: ",") + ")")
            case 0x23:
                let n = u16(); p += 2
                guard n >= 1, n <= g.names.count else { return nil }
                stack.append(g.names[n - 1])
            case 0x24: let r = u16(), c = u16(); stack.append(ref(r, c, relative: false))
            case 0x25:
                let r1 = u16(), r2 = u16(), c1 = u16(), c2 = u16()
                stack.append(ref(r1, c1, relative: false) + ":" + ref(r2, c2, relative: false))
            case 0x26, 0x27, 0x28: p += 6
            case 0x29: p += 2
            case 0x2A: p += 4; stack.append("#REF!")
            case 0x2B: p += 8; stack.append("#REF!")
            case 0x2C: let r = u16(), c = u16(); stack.append(ref(r, c, relative: true))
            case 0x2D:
                let r1 = u16(), r2 = u16(), c1 = u16(), c2 = u16()
                stack.append(ref(r1, c1, relative: true) + ":" + ref(r2, c2, relative: true))
            case 0x39:
                _ = u16()
                let n = u16(); p += 2
                guard n >= 1, n <= g.externNames.count else { return nil }
                stack.append(g.externNames[n - 1])
            case 0x3A:
                let x = u16(), r = u16(), c = u16()
                stack.append(sheetPrefix(x) + ref(r, c, relative: false))
            case 0x3B:
                let x = u16(), r1 = u16(), r2 = u16(), c1 = u16(), c2 = u16()
                stack.append(sheetPrefix(x) + ref(r1, c1, relative: false) + ":" + ref(r2, c2, relative: false))
            case 0x3C: p += 6; stack.append("#REF!")
            case 0x3D: p += 10; stack.append("#REF!")
            default: return nil
            }
        }
        return stack.count == 1 ? stack[0] : nil
    }

    /// BIFF function table: index → (name, fixed argument count or -1 for variable).
    static let functions: [Int: (String, Int)] = {
        var f: [Int: (String, Int)] = [:]
        let variable: [Int: String] = [0: "COUNT", 1: "IF", 4: "SUM", 5: "AVERAGE", 6: "MIN", 7: "MAX", 8: "ROW", 9: "COLUMN", 11: "NPV", 12: "STDEV",
            13: "DOLLAR", 14: "FIXED", 28: "LOOKUP", 29: "INDEX", 36: "AND", 37: "OR", 46: "VAR", 49: "LINEST", 50: "TREND", 51: "LOGEST",
            52: "GROWTH", 56: "PV", 57: "FV", 58: "NPER", 59: "PMT", 60: "RATE", 62: "IRR", 64: "MATCH", 70: "WEEKDAY", 78: "OFFSET",
            82: "SEARCH", 100: "CHOOSE", 101: "HLOOKUP", 102: "VLOOKUP", 109: "LOG", 115: "LEFT", 116: "RIGHT", 120: "SUBSTITUTE", 124: "FIND",
            125: "CELL", 144: "DDB", 148: "INDIRECT", 167: "IPMT", 168: "PPMT", 169: "COUNTA", 183: "PRODUCT", 193: "STDEVP", 194: "VARP",
            197: "TRUNC", 205: "FINDB", 206: "SEARCHB", 208: "LEFTB", 209: "RIGHTB", 216: "RANK", 219: "ADDRESS", 220: "DAYS360",
            222: "VDB", 227: "MEDIAN", 228: "SUMPRODUCT", 247: "DB", 269: "AVEDEV", 270: "BETADIST", 272: "BETAINV", 318: "DEVSQ",
            319: "GEOMEAN", 320: "HARMEAN", 321: "SUMSQ", 322: "KURT", 323: "SKEW", 324: "ZTEST", 330: "MODE", 336: "CONCATENATE",
            344: "SUBTOTAL", 345: "SUMIF", 354: "ROMAN", 359: "HYPERLINK", 361: "AVERAGEA", 362: "MAXA", 363: "MINA", 364: "STDEVPA",
            365: "VARPA", 366: "STDEVA", 367: "VARA", 210: "MIDB", 211: "LENB"]
        for (k, v) in variable { f[k] = (v, -1) }
        let fixed: [(Int, String, Int)] = [(2, "ISNA", 1), (3, "ISERROR", 1), (10, "NA", 0), (15, "SIN", 1), (16, "COS", 1), (17, "TAN", 1),
            (18, "ATAN", 1), (19, "PI", 0), (20, "SQRT", 1), (21, "EXP", 1), (22, "LN", 1), (23, "LOG10", 1), (24, "ABS", 1), (25, "INT", 1),
            (26, "SIGN", 1), (27, "ROUND", 2), (30, "REPT", 2), (31, "MID", 3), (32, "LEN", 1), (33, "VALUE", 1), (34, "TRUE", 0),
            (35, "FALSE", 0), (38, "NOT", 1), (39, "MOD", 2), (48, "TEXT", 2), (61, "MIRR", 3), (63, "RAND", 0), (65, "DATE", 3), (66, "TIME", 3),
            (67, "DAY", 1), (68, "MONTH", 1), (69, "YEAR", 1), (71, "HOUR", 1), (72, "MINUTE", 1), (73, "SECOND", 1), (74, "NOW", 0),
            (75, "AREAS", 1), (76, "ROWS", 1), (77, "COLUMNS", 1), (83, "TRANSPOSE", 1), (86, "TYPE", 1), (97, "ATAN2", 2), (98, "ASIN", 1),
            (99, "ACOS", 1), (105, "ISREF", 1), (111, "CHAR", 1), (112, "LOWER", 1), (113, "UPPER", 1), (114, "PROPER", 1), (117, "EXACT", 2),
            (118, "TRIM", 1), (119, "REPLACE", 4), (121, "CODE", 1), (126, "ISERR", 1), (127, "ISTEXT", 1), (128, "ISNUMBER", 1),
            (129, "ISBLANK", 1), (130, "T", 1), (131, "N", 1), (140, "DATEVALUE", 1), (141, "TIMEVALUE", 1), (142, "SLN", 3), (143, "SYD", 4),
            (162, "CLEAN", 1), (163, "MDETERM", 1), (164, "MINVERSE", 1), (165, "MMULT", 2), (184, "FACT", 1), (190, "ISNONTEXT", 1),
            (198, "ISLOGICAL", 1), (212, "ROUNDUP", 2), (213, "ROUNDDOWN", 2), (221, "TODAY", 0), (229, "SINH", 1), (230, "COSH", 1),
            (231, "TANH", 1), (232, "ASINH", 1), (233, "ACOSH", 1), (234, "ATANH", 1), (252, "FREQUENCY", 2), (261, "ERROR.TYPE", 1),
            (276, "COMBIN", 2), (277, "CONFIDENCE", 3), (279, "EVEN", 1), (285, "FLOOR", 2), (288, "CEILING", 2), (293, "NORMDIST", 4),
            (294, "NORMSDIST", 1), (295, "NORMINV", 3), (296, "NORMSINV", 1), (297, "STANDARDIZE", 3), (298, "ODD", 1), (299, "PERMUT", 2),
            (300, "POISSON", 3), (307, "CORREL", 2), (308, "COVAR", 2), (309, "FORECAST", 3), (311, "INTERCEPT", 2), (312, "PEARSON", 2),
            (313, "RSQ", 2), (314, "STEYX", 2), (315, "SLOPE", 2), (325, "LARGE", 2), (326, "SMALL", 2), (327, "QUARTILE", 2),
            (328, "PERCENTILE", 2), (331, "TRIMMEAN", 2), (337, "POWER", 2), (342, "RADIANS", 1), (343, "DEGREES", 1), (346, "COUNTIF", 2),
            (347, "COUNTBLANK", 1), (350, "ISPMT", 4), (351, "DATEDIF", 3)]
        for (k, name, argc) in fixed { f[k] = (name, argc) }
        return f
    }()
}
