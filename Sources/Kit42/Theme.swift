import AppKit

/// Shared look of Suite42 apps. Each app has its own accent colour; everything else is common.
public enum Theme42 {
    public static let stripHeight: CGFloat = 42
    public static let bannerHeight: CGFloat = 36
    public static let spacing: CGFloat = 8
    public static let cornerRadius: CGFloat = 8
    public static let sidebarWidth: CGFloat = 180

    public enum App {
        case pdf, doc, xls, img, scn

        public var name: String {
            switch self {
            case .pdf: return "PDF42"
            case .doc: return "DOC42"
            case .xls: return "XLS42"
            case .img: return "IMG42"
            case .scn: return "SCN42"
            }
        }

        /// Gradient for the app icon and accent details (top, bottom); same palette as scripts/make_icon.swift.
        public var colors: (NSColor, NSColor) {
            switch self {
            case .pdf: return (hex(0xFF6A5C), hex(0xD81E35))
            case .doc: return (hex(0x4FA3FF), hex(0x1659D6))
            case .xls: return (hex(0x3FD486), hex(0x0E8A4A))
            case .img: return (hex(0xB57CFF), hex(0x6A2BD9))
            case .scn: return (hex(0x3FD8E0), hex(0x0B8FA6))
            }
        }

        public var accent: NSColor { colors.1 }

        private func hex(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
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
