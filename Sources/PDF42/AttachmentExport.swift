import Foundation

/// Attachment names come from the PDF and may contain paths from another platform.
enum AttachmentExport {
    static func fileName(_ name: String) -> String {
        let component = name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let safe = component.components(separatedBy: .controlCharacters).joined(separator: "_")
            .replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "Attachment" : safe
    }

    /// Keep every attachment, including duplicate names, without replacing existing files or symlinks.
    static func write(_ data: Data, name: String, to directory: URL) throws -> URL {
        let name = fileName(name)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let candidate = number == 1 ? name : "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
            let url = directory.appendingPathComponent(candidate)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                number += 1
            }
        }
    }
}
