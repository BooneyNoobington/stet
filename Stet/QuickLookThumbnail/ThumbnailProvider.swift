import AppKit
import ImageIO
import QuickLookThumbnailing
import StetCore

/// Finder icons for .stet books: the book's cover if it has one, otherwise a title page.
final class ThumbnailProvider: QLThumbnailProvider {
    /// Page proportions (A-series) for the title page.
    private static let pageAspect: CGFloat = 1 / 1.414

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let summary = try BookSummary.read(request.fileURL)
            if let coverURL = summary.coverURL,
               let cover = Self.loadImage(coverURL, maxPixels: max(request.maximumSize.width, request.maximumSize.height) * request.scale)
            {
                let size = Self.fit(CGSize(width: cover.width, height: cover.height), into: request.maximumSize)
                handler(QLThumbnailReply(contextSize: size) { context -> Bool in
                    context.interpolationQuality = .high
                    context.draw(cover, in: CGRect(origin: .zero, size: size))
                    return true
                }, nil)
            } else {
                let size = Self.fit(CGSize(width: Self.pageAspect, height: 1), into: request.maximumSize)
                handler(QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
                    StetArtwork.drawTitlePage(title: summary.title, author: summary.authors.first, in: CGRect(origin: .zero, size: size))
                    return true
                }), nil)
            }
        } catch {
            handler(nil, error)
        }
    }

    /// Downsampled image, so a large cover (several MB) never gets fully decoded.
    static func loadImage(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func fit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
