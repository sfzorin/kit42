import Foundation

/// Quick Look extensions run sandboxed and cannot read the suite's language choice:
/// they follow the system language order instead. Rows are [en, ru, tr].
let previews42Strings: [[String]] = [
    ["First %d rows shown.", "Показаны первые %d строк.", "İlk %d satır gösteriliyor."],
    ["Empty document", "Пустой документ", "Boş belge"],
]

enum Strings {
    static let language: Int = {
        for l in Locale.preferredLanguages {
            if l.hasPrefix("ru") { return 1 }
            if l.hasPrefix("tr") { return 2 }
            if l.hasPrefix("en") { return 0 }
        }
        return 0
    }()

    static let table: [String: [String]] = Dictionary(previews42Strings.map { ($0[0], $0) }, uniquingKeysWith: { a, _ in a })

    static func lookup(_ key: String) -> String { table[key].map { $0[language] } ?? key }

    static var firstRows: String { PL("First %d rows shown.") }
}

/// Localized string for the Quick Look extensions.
func PL(_ key: String) -> String { Strings.lookup(key) }
