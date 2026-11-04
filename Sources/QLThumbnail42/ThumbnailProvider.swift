import Previews42
import QuickLookThumbnailing

/// Finder thumbnails: first page of a Markdown document, top-left grid of a spreadsheet.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let thumbnail = try Previews42.thumbnail(for: request.fileURL, maximumSize: request.maximumSize)
            handler(QLThumbnailReply(contextSize: thumbnail.size, drawing: thumbnail.draw), nil)
        } catch {
            handler(nil, error)
        }
    }
}
