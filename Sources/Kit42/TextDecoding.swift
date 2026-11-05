import Foundation

/// Plain text of unknown origin: BOM, UTF-16 without BOM, UTF-8, then Windows-1251, then Latin-1.
public enum TextDecoding {
    public static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8) }
        if b.starts(with: [0xFF, 0xFE]) { return (String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "", .utf16LittleEndian) }
        if b.starts(with: [0xFE, 0xFF]) { return (String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "", .utf16BigEndian) }
        // ASCII UTF-16 is also valid UTF-8 containing NULs, so inspect alternating zero bytes first.
        let sample = [UInt8](data.prefix(400))
        if sample.count >= 4, data.count % 2 == 0 {
            let oddZeros = sample.enumerated().filter { $0.offset % 2 == 1 && $0.element == 0 }.count
            let evenZeros = sample.enumerated().filter { $0.offset % 2 == 0 && $0.element == 0 }.count
            if oddZeros > sample.count / 4, oddZeros > evenZeros,
               let s = String(data: data, encoding: .utf16LittleEndian) { return (s, .utf16LittleEndian) }
            if evenZeros > sample.count / 4, evenZeros > oddZeros,
               let s = String(data: data, encoding: .utf16BigEndian) { return (s, .utf16BigEndian) }
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        if let s = String(data: data, encoding: .windowsCP1251) { return (s, .windowsCP1251) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
}
