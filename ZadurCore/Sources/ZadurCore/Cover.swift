import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The book's cover image: `assets/cover.jpg` (or `.png`), named in the manifest. It is the
/// first page of the PDF book, the ePUB's cover and the book's icon in Finder.
extension Book {
    /// Formats every place the cover shows can read as they are; others (HEIC from an iPhone,
    /// TIFF, WebP …) become JPEG.
    static let coverFormats: Set<String> = ["jpg", "jpeg", "png"]
    /// Bigger images are scaled down to this many pixels on the long side (plenty for print).
    static let coverMaxPixels = 4000

    public var coverURL: URL? {
        manifest.cover.map { url.appendingPathComponent($0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Makes `image` the cover. The previous cover file goes (it stays in the history).
    public func setCover(from image: URL) throws {
        let fm = FileManager.default
        let assets = url.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let ext = image.pathExtension.lowercased()
        let data: Data
        let name: String
        if Self.coverFormats.contains(ext), let size = Self.pixelSize(of: image), max(size.width, size.height) <= CGFloat(Self.coverMaxPixels) {
            data = try Data(contentsOf: image)
            name = ext == "png" ? "cover.png" : "cover.jpg"
        } else {
            data = try Self.jpeg(from: image)
            name = "cover.jpg"
        }
        let target = assets.appendingPathComponent(name)
        if let old = coverURL, old.standardizedFileURL.path != target.standardizedFileURL.path { try? fm.removeItem(at: old) }
        try data.write(to: target, options: .atomic)
        try updateManifest { $0.cover = "assets/\(name)" }
        touchPackage()
    }

    public func removeCover() throws {
        if let old = coverURL { try FileManager.default.removeItem(at: old) }
        try updateManifest { $0.cover = nil }
        touchPackage()
    }

    /// Finder (and Quick Look) notice a changed icon by the package's date.
    private func touchPackage() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func pixelSize(of image: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The image as JPEG, upright (a photo's orientation applied) and at most `coverMaxPixels`.
    static func jpeg(from image: URL) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: coverMaxPixels,
        ]
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw CoverError.unreadable(image.lastPathComponent) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CoverError.unreadable(image.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverError.unreadable(image.lastPathComponent) }
        return data as Data
    }
}

public enum CoverError: LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "„\(name)“ ist kein Bild, das Zadur lesen kann."
        }
    }
}
