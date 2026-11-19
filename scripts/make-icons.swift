// Renders Stet.icns (app) and StetBook.icns (.stet books) from StetArtwork.
// Run via scripts/make-icons.sh.
import AppKit

func render(_ draw: (CGRect) -> Void, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func makeIconset(named name: String, at folder: URL, draw: (CGRect) -> Void) throws -> URL {
    let iconset = folder.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try render(draw, pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try render(draw, pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    return iconset
}

let work = URL(fileURLWithPath: CommandLine.arguments[1])
_ = try makeIconset(named: "Stet", at: work, draw: StetArtwork.drawAppIcon)
_ = try makeIconset(named: "StetBook", at: work, draw: StetArtwork.drawDocumentIcon)

// A sample title page, for checking the thumbnail fallback.
let sample = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 848, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sample)
StetArtwork.drawTitlePage(title: "Der Leuchtturm am Ende der Welt", author: "Erika Muster", in: CGRect(x: 0, y: 0, width: 600, height: 848))
NSGraphicsContext.restoreGraphicsState()
try sample.representation(using: .png, properties: [:])!.write(to: work.appendingPathComponent("title-page-sample.png"))
