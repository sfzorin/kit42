import AppKit

/// Renders a view to a paginated PDF through the print system (honours knowsPageRange/rectForPage
/// and automatic pagination), without showing any panel.
public enum PaginatedPDF {
    public static func render(_ view: NSView, info: NSPrintInfo) -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let job = info.copy() as! NSPrintInfo
        job.jobDisposition = .save
        job.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = NSPrintOperation(view: view, printInfo: job)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
        return (try? Data(contentsOf: url)) ?? Data()
    }
}
