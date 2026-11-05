import AppKit

public enum ToolbarElement {
    /// Bordered icon button.
    case command(Command)
    /// Several icon buttons drawn as one control (zoom −/+, rotate ←/→).
    case group(id: String, label: String, [Command])
    case search(id: String, placeholder: String, action: Selector)
    case view(id: String, label: String, NSView)
    case toggleSidebar, sidebarSeparator, flexibleSpace, space

    var identifier: NSToolbarItem.Identifier {
        switch self {
        case .command(let c): return .init(c.id)
        case .group(let id, _, _), .search(let id, _, _), .view(let id, _, _): return .init(id)
        case .toggleSidebar: return .toggleSidebar
        case .sidebarSeparator: return .sidebarTrackingSeparator
        case .flexibleSpace: return .flexibleSpace
        case .space: return .space
        }
    }
}

/// Builds an NSToolbar from Commands. Items send their actions to the first responder,
/// so they are validated like menu items.
public final class ToolbarController: NSObject, NSToolbarDelegate {
    public let toolbar: NSToolbar
    public private(set) var searchItem: NSSearchToolbarItem?
    private let elements: [ToolbarElement]
    /// Items offered in Customize Toolbar but not placed by default.
    private let optional: [ToolbarElement]
    private var built: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

    public init(identifier: String, elements: [ToolbarElement], optional: [ToolbarElement] = []) {
        self.elements = elements
        self.optional = optional
        // ".4": saved layouts start over once (the default sets were trimmed; rarely used items moved to `optional`).
        toolbar = NSToolbar(identifier: identifier + ".4")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
    }

    public func item(for command: Command) -> NSToolbarItem? { built[.init(command.id)] }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        elements.map(\.identifier)
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (elements + optional).map(\.identifier) + [.space, .flexibleSpace]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let element = (elements + optional).first(where: { $0.identifier == id }) else { return nil }
        let item: NSToolbarItem
        switch element {
        case .command(let command):
            item = Self.button(command)

        case .group(_, let label, let commands):
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = commands.map(Self.button)
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
            group.label = label
            group.paletteLabel = label
            item = group

        case .search(_, let placeholder, let action):
            let search = NSSearchToolbarItem(itemIdentifier: id)
            search.searchField.placeholderString = placeholder
            search.searchField.action = action
            search.searchField.target = nil
            searchItem = search
            item = search

        case .view(_, let label, let view):
            item = NSToolbarItem(itemIdentifier: id)
            item.view = view
            item.label = label
            item.paletteLabel = label

        default:
            return nil
        }
        built[id] = item
        return item
    }

    static func button(_ command: Command) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .init(command.id))
        item.label = command.shortLabel
        item.paletteLabel = command.shortLabel
        item.toolTip = command.fullToolTip
        item.image = command.image
        item.action = command.action
        item.tag = command.tag
        item.isBordered = true
        item.autovalidates = true
        return item
    }
}
