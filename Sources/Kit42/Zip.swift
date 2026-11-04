import Compression
import Foundation

/// Minimal ZIP reader/writer for Office Open XML packages (.xlsx, .docx). Store and deflate only.
public struct ZipArchive {
    public private(set) var entries: [String: Data] = [:]
    public private(set) var order: [String] = []

    public init() {}

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }

        var eocd = b.count - 22
        while eocd >= 0, !(b[eocd] == 0x50 && b[eocd + 1] == 0x4B && b[eocd + 2] == 0x05 && b[eocd + 3] == 0x06) { eocd -= 1 }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { throw ZipError.corrupt }
            let method = u16(p + 10)
            let compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard local + 30 <= b.count, u32(local) == 0x04034B50 else { throw ZipError.corrupt }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count else { throw ZipError.corrupt }
            let raw = Data(b[start..<(start + compressed)])
            switch method {
            case 0: entries[name] = raw
            case 8: entries[name] = try Self.inflate(raw, size: size)
            default: throw ZipError.unsupported(method)
            }
            order.append(name)
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
            let deflated = Self.deflate(content)
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
        if size == 0 { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt }
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
