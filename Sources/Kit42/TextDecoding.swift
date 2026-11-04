import Foundation

/// Plain text of unknown origin: BOM, UTF-8, UTF-16 without BOM, then Windows-1251, then Latin-1.
public enum TextDecoding {
    public static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8) }
        if b.starts(with: [0xFF, 0xFE]) { return (String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "", .utf16LittleEndian) }
        if b.starts(with: [0xFE, 0xFF]) { return (String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "", .utf16BigEndian) }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        // UTF-16 without BOM: many zero bytes in alternating positions.
        let sample = [UInt8](data.prefix(400))
        if sample.count > 10 {
            let oddZeros = sample.enumerated().filter { $0.offset % 2 == 1 && $0.element == 0 }.count
            let evenZeros = sample.enumerated().filter { $0.offset % 2 == 0 && $0.element == 0 }.count
            if oddZeros > sample.count / 4 { return (String(data: data, encoding: .utf16LittleEndian) ?? "", .utf16LittleEndian) }
            if evenZeros > sample.count / 4 { return (String(data: data, encoding: .utf16BigEndian) ?? "", .utf16BigEndian) }
        }
        if let s = String(data: data, encoding: .windowsCP1251) { return (s, .windowsCP1251) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
}
