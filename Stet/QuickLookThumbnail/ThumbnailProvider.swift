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
                // Drawn in points into the current (scaled) context, like the title page: the
                // plain CGContext variant counts in pixels, so on Retina screens the cover
                // filled only a quarter of the icon.
                handler(QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
                    Self.draw(cover, in: CGRect(origin: .zero, size: size))
                    return true
                }), nil)
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

    /// Draws the picture into the current graphics context, the right way up in either orientation.
    static func draw(_ image: CGImage, in rect: CGRect) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                                                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    static func fit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
