import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ZadurCore

/// Setting, replacing and removing a book's cover image.
final class CoverTests: TempDirTestCase {
    /// A plain colored picture in the given format.
    static func image(_ type: UTType, width: Int = 60, height: Int = 90, at url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let picture = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testSetReplaceAndRemove() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Cover.crea"), title: "Cover", author: "Test")
        XCTAssertNil(book.coverURL)

        let png = temp.appendingPathComponent("titel.png")
        try Self.image(.png, at: png)
        try book.setCover(from: png)
        XCTAssertEqual(book.manifest.cover, "assets/cover.png")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(book.coverURL)), try Data(contentsOf: png), "PNG and JPEG stay as they are")
        XCTAssertEqual(try Book(url: book.url).manifest.cover, "assets/cover.png", "kept in book.yaml")

        // A TIFF (like HEIC from a phone) becomes JPEG; the old PNG goes.
        let tiff = temp.appendingPathComponent("foto.tiff")
        try Self.image(.tiff, at: tiff)
        try book.setCover(from: tiff)
        XCTAssertEqual(book.manifest.cover, "assets/cover.jpg")
        let jpeg = try Data(contentsOf: XCTUnwrap(book.coverURL))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.url.appendingPathComponent("assets/cover.png").path))

        try book.removeCover()
        XCTAssertNil(book.manifest.cover)
        XCTAssertNil(book.coverURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.url.appendingPathComponent("assets/cover.jpg").path))
    }

    func testHugePicturesAreScaledDown() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Gross.crea"), title: "Groß", author: "Test")
        let huge = temp.appendingPathComponent("riesig.png")
        try Self.image(.png, width: 6000, height: 9000, at: huge)
        try book.setCover(from: huge)
        let size = try XCTUnwrap(Book.pixelSize(of: XCTUnwrap(book.coverURL)))
        XCTAssertEqual(book.manifest.cover, "assets/cover.jpg")
        XCTAssertEqual(max(size.width, size.height), 4000)
        XCTAssertEqual(size.width / size.height, 6000.0 / 9000.0, accuracy: 0.01)
    }

    func testNotAPictureLeavesTheCoverAlone() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Kein.crea"), title: "Kein Bild", author: "Test")
        let png = temp.appendingPathComponent("titel.png")
        try Self.image(.png, at: png)
        try book.setCover(from: png)
        try write("kein Bild", to: "notiz.heic")
        XCTAssertThrowsError(try book.setCover(from: temp.appendingPathComponent("notiz.heic")))
        XCTAssertEqual(book.manifest.cover, "assets/cover.png")
        XCTAssertNotNil(book.coverURL)
    }
}
