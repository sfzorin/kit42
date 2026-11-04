import AppKit

/// UI language shared by all Suite42 apps. English is the source language: every string in code
/// is English and looked up in the per-language tables registered by Kit42 and each app.
public enum Language: String, CaseIterable {
    case en, ru, tr

    public var nativeName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .tr: return "Türkçe"
        }
    }

    static let defaults = UserDefaults(suiteName: "com.sfzorin.suite42") ?? .standard

    /// Chosen once at launch; changing it relaunches the app (see `switchLanguage`).
    public static let current: Language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .en

    /// Saves the choice for every Suite42 app and relaunches this one.
    public static func switchLanguage(to language: Language) {
        guard language != current else { return }
        defaults.set(language.rawValue, forKey: "language")
        defaults.synchronize()
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

public enum Localization {
    /// English key → [language: translation]
    private static var tables: [String: [Language: String]] = Dictionary(
        kit42Strings.map { ($0[0], [Language.ru: $0[1], .tr: $0[2]]) }, uniquingKeysWith: { _, b in b })

    /// Registers translations: `["Open…": [.ru: "Открыть…", .tr: "Aç…"]]`.
    public static func register(_ table: [String: [Language: String]]) {
        tables.merge(table) { _, new in new }
    }

    /// System panels (Print, Save, Colors, toolbar items) follow the app's AppleLanguages, not our tables:
    /// make it the chosen language. Runs at the first registration, before AppKit loads its strings.
    private static let systemLanguageApplied: Void = {
        let wanted = [Language.current.rawValue]
        if UserDefaults.standard.stringArray(forKey: "AppleLanguages") != wanted {
            UserDefaults.standard.set(wanted, forKey: "AppleLanguages")
        }
    }()

    /// Compact registration: each row is [en, ru, tr].
    public static func register(rows: [[String]]) {
        _ = systemLanguageApplied
        _ = DebugSnapshot.appearanceHook
        for row in rows where row.count == 3 {
            tables[row[0]] = [.ru: row[1], .tr: row[2]]
        }
    }

    public static func lookup(_ key: String) -> String {
        guard Language.current != .en else { return key }
        return tables[key]?[Language.current] ?? key
    }
}

/// Localized UI string. The key is the English text.
public func L(_ key: String) -> String { Localization.lookup(key) }

/// Localized format string: `L("Page %d of %d", 3, 12)`.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localization.lookup(key), arguments: args)
}

/// Popup for choosing the UI language (used on welcome screens).
public final class LanguagePicker: NSPopUpButton {
    public init() {
        super.init(frame: .zero, pullsDown: false)
        for language in Language.allCases {
            addItem(withTitle: language.nativeName)
            lastItem?.representedObject = language.rawValue
        }
        selectItem(at: Language.allCases.firstIndex(of: .current) ?? 0)
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        action = #selector(changed)
        toolTip = L("Interface language")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func changed() {
        guard let raw = selectedItem?.representedObject as? String, let language = Language(rawValue: raw) else { return }
        if NSDocumentController.shared.documents.contains(where: \.isDocumentEdited) {
            let alert = NSAlert()
            alert.messageText = L("Restart to change the language?")
            alert.informativeText = L("Unsaved documents will ask to be saved.")
            alert.addButton(withTitle: L("Restart"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                selectItem(at: Language.allCases.firstIndex(of: .current) ?? 0)
                return
            }
        }
        Language.switchLanguage(to: language)
    }
}
