import AppKit

/// Development aid: `K42_SNAPSHOT=/path/out.png` renders the front window (with toolbar) to a PNG
/// after `K42_SNAPSHOT_DELAY` seconds (default 2), then quits.
public enum DebugSnapshot {
    public static func scheduleIfRequested(prepare: (() -> Void)? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["K42_SNAPSHOT"] else { return }
        let delay = Double(env["K42_SNAPSHOT_DELAY"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // K42_SIZE=900x700 resizes the front window first (layout checks).
            if let size = env["K42_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = NSApp.orderedWindows.first(where: { $0.isVisible }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            prepare?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // K42_SNAPSHOT_POPOVER=1 captures an open popover instead of the window.
                let popover = env["K42_SNAPSHOT_POPOVER"] != nil
                    ? NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") } : nil
                var window = popover ?? NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil }
                // K42_SNAPSHOT_SHEET=1 captures the sheet attached to the window (dialogs).
                if env["K42_SNAPSHOT_SHEET"] != nil, let sheet = NSApp.windows.compactMap(\.attachedSheet).first { window = sheet }
                if let frame = window?.contentView?.superview,
                   let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                if env["K42_SNAPSHOT_KEEP"] == nil {
                    // An open sheet would block terminate: quit hard, it is a debug run.
                    if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { exit(0) }
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
