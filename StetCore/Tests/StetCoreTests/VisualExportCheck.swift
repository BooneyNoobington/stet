import XCTest
@testable import StetCore

/// Not a regular test: with STET_VISUAL_OUT set, writes both PDFs of a sample book there for a
/// look at the typesetting. Uses the editor's own sample scene (no manuscript text).
final class VisualExportCheck: TempDirTestCase {
    func testWriteSamplePDFs() async throws {
        guard let out = ProcessInfo.processInfo.environment["STET_VISUAL_OUT"] else { throw XCTSkip("set STET_VISUAL_OUT") }
        let sampleURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("editor/public/samples/szene.md")
        let sample = try String(contentsOf: sampleURL, encoding: .utf8)
        let book = try await Book.create(at: temp.appendingPathComponent("Probe.stet"), title: "Der Leuchtturm am Ende der Welt", author: "Erika Muster")
        let c1 = book.manifest.chapters[0].id
        try book.updateManifest { $0.updateChapter(c1) { $0.title = "Die Ankunft" } }
        var s = try book.readScene(book.manifest.sceneIDs[0]); s.body = sample; try book.writeScene(s)
        let second = try book.addScene(toChapter: c1, after: s.id)
        var s2 = try book.readScene(second.id)
        s2.body = "Auf dem Tisch lag ein Zettel, in der Schrift ihres Vaters:\n\n> Bin beim Boot. Wenn das Gewitter kommt, schließ die Läden.\n>\n> *Und vergiss den Schlüssel nicht.*\n\n" + sample
        try book.writeScene(s2)
        let ch2 = try book.addChapter(title: "Die Flut", after: c1)
        var s3 = try book.readScene(ch2.sceneIDs[0]); s3.body = sample; try book.writeScene(s3)
        try await book.saveVersion()
        for format in [ExportFormat.pdfManuscript, .pdfBook] {
            try await Exporter.export(book, options: ExportOptions(format: format), to: URL(fileURLWithPath: out).appendingPathComponent("\(format.rawValue).pdf"))
        }
    }
}
