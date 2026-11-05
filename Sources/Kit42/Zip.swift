import Compression
import Foundation

/// Minimal ZIP reader/writer for Office Open XML packages (.xlsx, .docx). Store and deflate only.
public struct ZipArchive {
    public private(set) var entries: [String: Data] = [:]
    public private(set) var order: [String] = []
    /// Entries written without compression (e.g. ODF "mimetype").
    public var storedUncompressed: Set<String> = []

    public init() {}

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        var eocd = b.count - 22
        let firstEOCD = max(0, b.count - 22 - 65535)
        // A signature may also occur inside the comment. Only accept a record whose comment ends at EOF.
        while eocd >= firstEOCD {
            if u32(eocd) == 0x06054B50, eocd + 22 + u16(eocd + 20) == b.count { break }
            eocd -= 1
        }
        guard eocd >= firstEOCD else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        let centralStart = p, centralEnd = p + u32(eocd + 12)
        guard u16(eocd + 4) == 0, u16(eocd + 6) == 0, u16(eocd + 8) == count,
              centralEnd <= eocd else { throw ZipError.corrupt }
        for _ in 0..<count {
            guard p + 46 <= centralEnd, u32(p) == 0x02014B50 else { throw ZipError.corrupt }
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let crc = UInt32(u32(p + 16))
            let compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nameLen + extraLen + commentLen <= centralEnd,
                  flags & 0x0041 == 0, u16(p + 34) == 0 else { throw ZipError.corrupt }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard local + 30 <= centralStart, u32(local) == 0x04034B50,
                  u16(local + 8) == method, u16(local + 6) & 0x0041 == 0 else { throw ZipError.corrupt }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= centralStart else { throw ZipError.corrupt }
            let raw = Data(b[start..<(start + compressed)])
            let content: Data
            switch method {
            case 0:
                guard compressed == size else { throw ZipError.corrupt }
                content = raw
            case 8: content = try Self.inflate(raw, size: size)
            default: throw ZipError.unsupported(method)
            }
            guard CRC32.checksum(content) == crc else { throw ZipError.corrupt }
            self[name] = content
            if method == 0 { storedUncompressed.insert(name) }
        }
    }

    public subscript(name: String) -> Data? {
        get { entries[name] }
        set {
            if entries[name] == nil, newValue != nil { order.append(name) }
            entries[name] = newValue
            if newValue == nil { order.removeAll { $0 == name } }
        }
    }

    public func string(_ name: String) -> String? { entries[name].map { String(decoding: $0, as: UTF8.self) } }

    public func data() -> Data {
        var out = Data()
        var central = Data()
        let (time, date) = Self.dosTime(Date())
        for name in order {
            guard let content = entries[name] else { continue }
            let crc = CRC32.checksum(content)
            let deflated = storedUncompressed.contains(name) ? nil : Self.deflate(content)
            let useDeflate = deflated != nil && deflated!.count < content.count
            let payload = useDeflate ? deflated! : content
            let nameData = Data(name.utf8)
            let offset = out.count

            var local = Data()
            local.u32(0x04034B50); local.u16(20); local.u16(0x0800); local.u16(useDeflate ? 8 : 0)
            local.u16(time); local.u16(date); local.u32(crc)
            local.u32(UInt32(payload.count)); local.u32(UInt32(content.count))
            local.u16(UInt16(nameData.count)); local.u16(0)
            out += local + nameData + payload

            var c = Data()
            c.u32(0x02014B50); c.u16(20); c.u16(20); c.u16(0x0800); c.u16(useDeflate ? 8 : 0)
            c.u16(time); c.u16(date); c.u32(crc)
            c.u32(UInt32(payload.count)); c.u32(UInt32(content.count))
            c.u16(UInt16(nameData.count)); c.u16(0); c.u16(0); c.u16(0); c.u16(0); c.u32(0)
            c.u32(UInt32(offset))
            central += c + nameData
        }
        let cdOffset = out.count
        out += central
        var end = Data()
        let n = UInt16(order.filter { entries[$0] != nil }.count)
        end.u32(0x06054B50); end.u16(0); end.u16(0); end.u16(n); end.u16(n)
        end.u32(UInt32(central.count)); end.u32(UInt32(cdOffset)); end.u16(0)
        return out + end
    }

    static func inflate(_ data: Data, size: Int) throws -> Data {
        guard !data.isEmpty else { throw ZipError.corrupt }
        var out = Data()
        // The size in an untrusted header must not dictate a potentially multi-gigabyte allocation.
        var buffer = [UInt8](repeating: 0, count: 65536)
        try data.withUnsafeBytes { source in
            try buffer.withUnsafeMutableBufferPointer { destination in
                var stream = compression_stream(dst_ptr: destination.baseAddress!, dst_size: destination.count,
                                                src_ptr: source.bindMemory(to: UInt8.self).baseAddress!, src_size: data.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError.corrupt }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = data.count
                while true {
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    let before = stream.src_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let written = destination.count - stream.dst_size
                    guard status != COMPRESSION_STATUS_ERROR, written <= size - out.count else { throw ZipError.corrupt }
                    out.append(destination.baseAddress!, count: written)
                    if status == COMPRESSION_STATUS_END {
                        guard out.count == size, stream.src_size == 0 else { throw ZipError.corrupt }
                        break
                    }
                    guard written > 0 || stream.src_size < before else { throw ZipError.corrupt }
                }
            }
        }
        return out
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

public enum ZipError: LocalizedError {
    case notZip, corrupt, unsupported(Int)
    public var errorDescription: String? {
        switch self {
        case .notZip: return L("The file is not an Office Open XML (ZIP) document")
        case .corrupt: return L("The file is damaged")
        case .unsupported(let m): return L("Unsupported compression in archive (%d)", m)
        }
    }
}

/// zlib stream (RFC 1950): header + raw deflate + Adler-32, as PDF /FlateDecode expects.
public func zlibCompress(_ data: Data) -> Data {
    var out = Data([0x78, 0x9C])
    out += ZipArchive.deflate(data) ?? Data()
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    let adler = b << 16 | a
    out += Data([UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
    return out
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for byte in buf { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
}

public extension XMLElement {
    /// Child elements by local name (ignores namespaces).
    func children(_ name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    func child(_ name: String) -> XMLElement? { children(name).first }

    func attr(_ name: String) -> String? {
        if let a = attribute(forName: name) { return a.stringValue }
        return attributes?.first { $0.localName == name }?.stringValue
    }

    /// All descendant text of <t> elements (shared strings with rich runs).
    var allText: String {
        if localName == "t" { return stringValue ?? "" }
        return (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName != "rPh" }.map(\.allText).joined()
    }
}

/// Escapes text for XML content/attributes.
public func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default:
            if ch.value < 0x20, ch != "\n", ch != "\r", ch != "\t" { continue }
            out.unicodeScalars.append(ch)
        }
    }
    return out
}
