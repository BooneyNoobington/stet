import Cocoa
import QuickLookUI
import ZadurCore
import UniformTypeIdentifiers

/// Space bar on a .crea book in Finder: title, author, contents with word counts, and the
/// opening of the book.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let summary = try BookSummary.read(request.fileURL)
        let cover = summary.coverURL.flatMap(Self.coverAttachment)

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 880, height: 720)) { reply in
            reply.stringEncoding = .utf8
            reply.title = summary.title
            if let cover { reply.attachments = ["cover": cover] }
            let html = BookPreviewHTML.render(summary, coverSource: cover == nil ? nil : "cid:cover")
            return Data(html.utf8)
        }
    }

    /// The cover, scaled down to a size that suits the preview.
    static func coverAttachment(_ url: URL) -> QLPreviewReplyAttachment? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 600,
              ] as CFDictionary)
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return QLPreviewReplyAttachment(data: data, contentType: .jpeg)
    }
}
