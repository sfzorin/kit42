import Previews42
import QuickLookUI
import UniformTypeIdentifiers

/// Data-based Quick Look preview (space bar in Finder): the document as an HTML page.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let html = try Previews42.html(for: request.fileURL)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 860, height: 1000)) { _ in Data(html.utf8) }
        reply.stringEncoding = .utf8
        reply.title = request.fileURL.lastPathComponent
        return reply
    }
}
