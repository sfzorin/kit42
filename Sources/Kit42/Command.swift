import AppKit

/// Keyboard shortcut for a command. See DESIGN.md for the shortcuts reserved across Suite42.
public struct Shortcut {
    public let key: String
    public let modifiers: NSEvent.ModifierFlags

    public init(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let backspace = "\u{8}"
    public static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    public static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    public static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    public static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
}

/// One user-facing action. The same Command builds its menu item, toolbar item and tool-strip button,
/// so title, icon, shortcut and validation stay identical everywhere.
///
/// Actions are sent to the first responder (target nil): implement them on the window controller
/// and validate with `validateUserInterfaceItem` / `validateMenuItem`.
public struct Command {
    public let title: String
    public let action: Selector
    public var symbol: String?
    public var shortcut: Shortcut?
    public var tag: Int
    public var toolTip: String?
    /// Short label for toolbars; defaults to `title` without the trailing ellipsis.
    public var label: String?

    public init(_ title: String, _ action: Selector, symbol: String? = nil, shortcut: Shortcut? = nil,
                tag: Int = 0, toolTip: String? = nil, label: String? = nil) {
        self.title = title
        self.action = action
        self.symbol = symbol
        self.shortcut = shortcut
        self.tag = tag
        self.toolTip = toolTip
        self.label = label
    }

    public var id: String { NSStringFromSelector(action) + (tag == 0 ? "" : "#\(tag)") }

    public var shortLabel: String { label ?? title.replacingOccurrences(of: "…", with: "") }

    public var image: NSImage? {
        symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
    }

    /// Tooltip with the shortcut appended, e.g. "Повернуть влево (⌘L)".
    public var fullToolTip: String {
        let base = toolTip ?? shortLabel
        guard let shortcut else { return base }
        return "\(base) (\(shortcut.display))"
    }

    public func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.key ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        item.tag = tag
        item.toolTip = toolTip
        // Menus in current macOS show SF Symbols next to items.
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            item.image = image.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        return item
    }
}

extension Shortcut {
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case Shortcut.backspace: s += "⌫"
        case Shortcut.upArrow: s += "↑"
        case Shortcut.downArrow: s += "↓"
        case Shortcut.leftArrow: s += "←"
        case Shortcut.rightArrow: s += "→"
        default: s += key.uppercased()
        }
        return s
    }
}

/// Reads the command tag from whatever sent an action (menu item, button, toolbar item).
public func commandTag(of sender: Any?) -> Int {
    switch sender {
    case let item as NSMenuItem: return item.tag
    case let item as NSToolbarItem: return item.tag
    case let control as NSControl: return control.tag
    default: return 0
    }
}
