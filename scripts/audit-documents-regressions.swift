// Run from the repository root:
// swiftc -module-cache-path /tmp/suite42-audit-cache Sources/Kit42/Zip.swift Sources/Kit42/TextDecoding.swift \
//   scripts/audit-documents-regressions.swift -o /tmp/suite42-document-regressions && /tmp/suite42-document-regressions
import Foundation

// Only localization is stubbed; these checks compile the production archive/text readers directly.
func L(_ key: String) -> String { key }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: key, arguments: args) }

@main
enum DocumentRegressions {
    static func u32(_ data: Data, _ i: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(data[i + $1]) << (8 * $1) }
    }
    static func put(_ data: inout Data, _ i: Int, _ value: Int, bytes: Int = 2) {
        for j in 0..<bytes { data[i + j] = UInt8((value >> (8 * j)) & 255) }
    }
    static func archive(_ payload: Data = Data("hello world".utf8), stored: Bool = true) -> Data {
        var zip = ZipArchive()
        zip["test.txt"] = payload
        if stored { zip.storedUncompressed.insert("test.txt") }
        return zip.data()
    }
    static func rejects(_ data: Data) -> Bool {
        do { _ = try ZipArchive(data: data); return false } catch { return true }
    }

    static let cases = ["roundtrip", "empty-entry", "deflate", "truncated-name", "truncated-extra", "crc",
                        "stored-size", "encrypted", "deflate-size", "empty-deflate", "comment-signature",
                        "utf16-le", "utf16-be", "utf16-short", "utf8", "utf16-bom", "cp1251"]
    static func check(_ name: String) throws -> Bool {
        var data = archive()
        let eocd = data.count - 22, central = u32(data, eocd + 16)
        switch name {
        case "roundtrip": return try ZipArchive(data: data)["test.txt"] == Data("hello world".utf8)
        case "empty-entry": return try ZipArchive(data: archive(Data()))["test.txt"] == Data()
        case "deflate":
            let payload = Data(repeating: 65, count: 200_000)
            return try ZipArchive(data: archive(payload, stored: false))["test.txt"] == payload
        case "truncated-name": put(&data, central + 28, 65535); return rejects(data)
        case "truncated-extra": put(&data, central + 30, 65535); return rejects(data)
        case "crc": data[38] ^= 1; return rejects(data)
        case "stored-size": put(&data, central + 24, 12, bytes: 4); return rejects(data)
        case "encrypted": put(&data, central + 8, 1); put(&data, 6, 1); return rejects(data)
        case "deflate-size":
            data = archive(Data(repeating: 65, count: 200_000), stored: false)
            put(&data, u32(data, data.count - 6) + 24, 20, bytes: 4)
            return rejects(data)
        case "empty-deflate":
            put(&data, central + 10, 8); put(&data, 8, 8); put(&data, central + 20, 0, bytes: 4)
            return rejects(data)
        case "comment-signature":
            var comment = Data(repeating: 0, count: 24)
            comment.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x05, 0x06])
            put(&data, eocd + 20, comment.count)
            data += comment
            return try ZipArchive(data: data)["test.txt"] == Data("hello world".utf8)
        case "utf16-le", "utf16-be", "utf16-short", "utf16-bom":
            let expected = name == "utf16-short" ? "Hi" : "Hello world\nSecond line"
            let encoding: String.Encoding = name == "utf16-be" ? .utf16BigEndian : .utf16LittleEndian
            var source = expected.data(using: encoding)!
            if name == "utf16-bom" { source = Data([0xff, 0xfe]) + source }
            let result = TextDecoding.decode(source)
            return result.text == expected && result.encoding == encoding
        case "utf8":
            let expected = "Текст — Ελληνικά — 日本語"
            let result = TextDecoding.decode(Data(expected.utf8))
            return result.text == expected && result.encoding == .utf8
        case "cp1251":
            let expected = "Привет, мир!"
            let result = TextDecoding.decode(expected.data(using: .windowsCP1251)!)
            return result.text == expected && result.encoding == .windowsCP1251
        default: return false
        }
    }
    static func main() throws {
        if CommandLine.arguments.count == 2 { exit(try check(CommandLine.arguments[1]) ? 0 : 1) }
        var failures = 0
        // Isolate malformed inputs so a parser crash is reported as a failed check.
        for name in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [name]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            let ok = process.terminationReason == .exit && process.terminationStatus == 0
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        print("\(cases.count - failures)/\(cases.count) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
