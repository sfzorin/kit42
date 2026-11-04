import AppKit

/// Shared look of Suite42 apps. Each app has its own accent colour; everything else is common.
public enum Theme42 {
    public static let stripHeight: CGFloat = 42
    public static let bannerHeight: CGFloat = 36
    public static let spacing: CGFloat = 8
    public static let cornerRadius: CGFloat = 8
    public static let sidebarWidth: CGFloat = 180

    public enum App {
        case pdf, doc, xls

        public var name: String {
            switch self {
            case .pdf: return "PDF42"
            case .doc: return "DOC42"
            case .xls: return "XLS42"
            }
        }

        /// Gradient for the app icon and accent details (top, bottom).
        public var colors: (NSColor, NSColor) {
            switch self {
            case .pdf: return (NSColor(red: 0.95, green: 0.30, blue: 0.25, alpha: 1), NSColor(red: 0.70, green: 0.08, blue: 0.20, alpha: 1))
            case .doc: return (NSColor(red: 0.25, green: 0.55, blue: 0.98, alpha: 1), NSColor(red: 0.10, green: 0.28, blue: 0.75, alpha: 1))
            case .xls: return (NSColor(red: 0.20, green: 0.75, blue: 0.45, alpha: 1), NSColor(red: 0.05, green: 0.48, blue: 0.28, alpha: 1))
            }
        }

        public var accent: NSColor { colors.1 }
    }

    public static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

public extension NSAlert {
    /// Alert with a vertical stack of labelled fields as accessory.
    static func form(_ title: String, info: String? = nil, ok: String, rows: [(String, NSView)]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        if let info { alert.informativeText = info }
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: L("Cancel"))
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for (_, view) in rows where view is NSTextField || view is NSPopUpButton {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        grid.frame.size = grid.fittingSize
        alert.accessoryView = grid
        return alert
    }
}
