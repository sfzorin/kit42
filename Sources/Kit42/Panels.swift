import AppKit

/// Showing and hiding the window's bars, shared by all apps: toolbar labels, "Hide All Panels"
/// (toolbar, titlebar strips, sidebars and any app panels), and a full screen where the bars
/// slide in only when the pointer reaches the top edge.
public enum Panels {
    /// Full-screen options for `window(_:willUseFullScreenPresentationOptions:)`.
    public static let fullScreenOptions: NSApplication.PresentationOptions = [.fullScreen, .autoHideToolbar, .autoHideMenuBar, .autoHideDock]

    private struct Saved {
        var toolbar: Bool
        var accessories: [ObjectIdentifier: Bool]
        var sidebars: [ObjectIdentifier: Bool]
    }
    private static var saved: [ObjectIdentifier: Saved] = [:]

    /// True while "Hide All Panels" is on for this window.
    public static func allHidden(in window: NSWindow?) -> Bool {
        window.map { saved[ObjectIdentifier($0)] != nil } ?? false
    }

    /// Hides every bar of the window, or brings back exactly what was shown before.
    /// `extra(hidden)` hides/shows the app's own panels (ruler, comments, filmstrip…).
    public static func toggleAll(in window: NSWindow?, extra: (Bool) -> Void = { _ in }) {
        guard let window else { return }
        let key = ObjectIdentifier(window)
        let splits = splitItems(window)
        if let s = saved.removeValue(forKey: key) {
            window.toolbar?.isVisible = s.toolbar
            for vc in window.titlebarAccessoryViewControllers { vc.isHidden = s.accessories[ObjectIdentifier(vc)] ?? vc.isHidden }
            for item in splits { item.animator().isCollapsed = s.sidebars[ObjectIdentifier(item)] ?? item.isCollapsed }
            extra(false)
            return
        }
        saved[key] = Saved(toolbar: window.toolbar?.isVisible ?? false,
                           accessories: Dictionary(uniqueKeysWithValues: window.titlebarAccessoryViewControllers.map { (ObjectIdentifier($0), $0.isHidden) }),
                           sidebars: Dictionary(uniqueKeysWithValues: splits.map { (ObjectIdentifier($0), $0.isCollapsed) }))
        window.toolbar?.isVisible = false
        window.titlebarAccessoryViewControllers.forEach { $0.isHidden = true }
        splits.forEach { $0.animator().isCollapsed = true }
        extra(true)
    }

    /// Sidebar and inspector items of split views in the window.
    private static func splitItems(_ window: NSWindow) -> [NSSplitViewItem] {
        var out: [NSSplitViewItem] = []
        func visit(_ vc: NSViewController) {
            if let split = vc as? NSSplitViewController {
                out += split.splitViewItems.filter { $0.behavior == .sidebar || $0.behavior == .inspector || $0.canCollapse }
                split.splitViewItems.forEach { visit($0.viewController) }
            }
            vc.children.forEach(visit)
        }
        if let root = window.contentViewController { visit(root) }
        return out
    }
}

/// Menu target for "Show Toolbar Labels" (acts on the key window).
public final class ToolbarLabelsToggle: NSObject, NSMenuItemValidation {
    public static let shared = ToolbarLabelsToggle()

    @objc public func toggleToolbarLabels(_ sender: Any?) {
        guard let toolbar = NSApp.keyWindow?.toolbar else { return }
        toolbar.displayMode = toolbar.displayMode == .iconOnly ? .iconAndLabel : .iconOnly
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let toolbar = NSApp.keyWindow?.toolbar else { return false }
        item.state = toolbar.displayMode == .iconOnly ? .off : .on
        return toolbar.isVisible
    }
}

/// Window controllers that can hide all their panels answer this (sent along the responder chain).
@objc public protocol PanelHiding {
    @objc func toggleAllPanelsAction(_ sender: Any?)
}
