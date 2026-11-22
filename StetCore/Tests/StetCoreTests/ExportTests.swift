import PDFKit
import XCTest
@testable import StetCore

final class TypographyTests: XCTestCase {
    func t(_ text: String, _ quotes: ExportQuotes = .de) -> String { Typography.apply(text, quotes: quotes) }

    func testGermanQuotes() {
        XCTAssertEqual(t(#""Hallo", sagte sie."#), "„Hallo“, sagte sie.")
        XCTAssertEqual(t(#"Er sagte: "Komm." Dann ging er."#), "Er sagte: „Komm.“ Dann ging er.")
        XCTAssertEqual(t(#"("Klammer")"#), "(„Klammer“)")
        XCTAssertEqual(t(#"*"Kursiv"*"#), "*„Kursiv“*")
        XCTAssertEqual(t("Geht's? 'Ja', sagte sie."), "Geht’s? ‚Ja‘, sagte sie.")
        XCTAssertEqual(t("„Schon gesetzt“ bleibt."), "„Schon gesetzt“ bleibt.")
    }

    func testOtherStyles() {
        XCTAssertEqual(t(#""Hallo""#, .guillemets), "»Hallo«")
        XCTAssertEqual(t(#""Hello," it's me."#, .en), "“Hello,” it’s me.")
        XCTAssertEqual(t(#""Bleibt" -- so..."#, .keep), #""Bleibt" -- so..."#)
    }

    func testDashesAndEllipses() {
        XCTAssertEqual(t("Wort -- Wort"), "Wort – Wort")
        XCTAssertEqual(t("{--gelöscht--}"), "{--gelöscht--}", "CriticMarkup stays intact")
        XCTAssertEqual(t("a---b"), "a---b")
        XCTAssertEqual(t("Und dann..."), "Und dann…")
        XCTAssertEqual(t("***"), "***", "scene break lines stay")
    }
}

final class ExportTests: TempDirTestCase {
    /// A small book with my own text: two chapters, a comment, a TODO, a highlight, an internal rule.
    func makeBook() async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("Export.stet"), title: "Der Leuchtturm", author: "Erika Muster")
        let c1 = book.manifest.chapters[0].id
        try book.updateManifest { $0.updateChapter(c1) { $0.title = "Ankunft" } }
        var first = try book.readScene(book.manifest.sceneIDs[0])
        first.title = "Am Anleger"
        first.body = #"""
        Der Wind kam von Westen. "Wo ist der Wärter?", fragte sie. {>>@Gisela: Zu direkt?<<}

        Er spuckte ins Wasser. {==Die Lichter waren verschwunden.==}{>>TODO: Uhrzeit prüfen<<}

        ***

        Erst später verstand sie... es war *nicht* der Wind.
        """#
        try book.writeScene(first)
        let second = try book.addScene(toChapter: c1, after: first.id)
        var scene2 = try book.readScene(second.id)
        scene2.body = "Am Abend klopfte es. 'Herein', rief sie -- und erschrak.\n"
        try book.writeScene(scene2)
        let chapter2 = try book.addChapter(title: "Die Flut", after: c1)
        var scene3 = try book.readScene(chapter2.sceneIDs[0])
        scene3.body = "Das Wasser stieg schneller als erwartet.\n"
        try book.writeScene(scene3)
        try await book.saveVersion()
        return book
    }

    func stamp() -> ExportStamp {
        ExportStamp(commit: "abcdef1234567", date: Date(timeIntervalSince1970: 1_795_000_000), versionName: "Hauptfassung", words: 1234)
    }

    func testCombinedMarkdownPerTarget() async throws {
        let book = try await makeBook()
        let typst = CombinedMarkdown.build(book, options: ExportOptions(format: .pdfBook), stamp: stamp())
        XCTAssertTrue(typst.hasPrefix("---\ntitle: \"Der Leuchtturm\"\n"))
        XCTAssertTrue(typst.contains("stet-version: \"abcdef1\""))
        XCTAssertTrue(typst.contains("stet-words: \"1.234\""), "numbers stay text")
        XCTAssertTrue(typst.contains("\n# Ankunft\n"))
        XCTAssertTrue(typst.contains("\n# Die Flut\n"))
        XCTAssertTrue(typst.contains("```{=typst}\n#scenebreak()\n```"), "a scene break between the two scenes")
        XCTAssertTrue(typst.contains("„Wo ist der Wärter?“, fragte sie."))
        XCTAssertTrue(typst.contains("Die Lichter waren verschwunden."))
        XCTAssertFalse(typst.contains("{>>") || typst.contains("Gisela") || typst.contains("TODO"), "comments are gone")
        XCTAssertTrue(typst.contains("sie… es war *nicht*"))
        XCTAssertTrue(typst.contains("‚Herein‘, rief sie – und"))

        let html = CombinedMarkdown.build(book, options: ExportOptions(format: .epub), stamp: stamp())
        XCTAssertTrue(html.contains(#"<p class="scene-break">⁂</p>"#))
        XCTAssertTrue(html.contains("Fassung abcdef1 vom"))

        var withTitles = ExportOptions(format: .pdfManuscript, quotes: .guillemets)
        withTitles.sceneTitles = true
        let titled = CombinedMarkdown.build(book, options: withTitles, stamp: stamp())
        XCTAssertTrue(titled.contains("## Am Anleger {.unnumbered .scene-title}"))
        XCTAssertTrue(titled.contains("»Wo ist der Wärter?«"))
    }

    func testCommentsBecomeWordComments() async throws {
        let book = try await makeBook()
        var options = ExportOptions(format: .docx)
        options.commentsAsAnnotations = true
        let text = CombinedMarkdown.build(book, options: options, stamp: stamp())
        XCTAssertTrue(text.contains(#"[Zu direkt?]{.comment-start id="0" author="Gisela""#))
        XCTAssertTrue(text.contains(#"[TODO: Uhrzeit prüfen]{.comment-start id="1" author="Erika Muster""#))
        XCTAssertTrue(text.contains(#"Die Lichter waren verschwunden.[]{.comment-end id="1"}"#))
    }

    // MARK: Real files (needs Pandoc and Typst)

    func requireTools() throws {
        let missing = Exporter.missingTools(for: .pdfBook) + Exporter.missingTools(for: .docx)
        if !missing.isEmpty { throw XCTSkip("needs \(missing.joined(separator: ", "))") }
    }

    func pdfText(_ url: URL) throws -> (text: String, pages: Int) {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (document.string ?? "", document.pageCount)
    }

    func zipEntry(_ archive: URL, _ entry: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testExportAllFormats() async throws {
        try requireTools()
        let book = try await makeBook()
        // An unsaved edit: the export must save it as a version first and name that version.
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body += "\n\nEin letzter, noch nicht gesicherter Satz.\n"
        try book.writeScene(scene)
        let out = temp.appendingPathComponent("Ausgabe")

        let manuscript = try await Exporter.export(book, options: ExportOptions(format: .pdfManuscript), to: out.appendingPathComponent("M.pdf"))
        let head = await book.git.headCommit()
        XCTAssertEqual(manuscript.stamp.commit, head, "the stamp names the saved version")
        let changed = try await book.git.changedPaths()
        XCTAssertTrue(changed.isEmpty)
        let m = try pdfText(manuscript.file)
        XCTAssertGreaterThanOrEqual(m.pages, 3, "title page + two chapters")
        XCTAssertTrue(m.text.contains("Der Leuchtturm"))
        XCTAssertTrue(m.text.contains("Fassung \(manuscript.stamp.shortCommit)"))
        XCTAssertTrue(m.text.contains("„Wo ist der Wärter?“"))
        XCTAssertTrue(m.text.contains("noch nicht gesicherter Satz"))
        XCTAssertFalse(m.text.contains("Gisela"))

        let bookPDF = try await Exporter.export(book, options: ExportOptions(format: .pdfBook), to: out.appendingPathComponent("B.pdf"))
        let b = try pdfText(bookPDF.file)
        XCTAssertTrue(b.text.contains("Gesetzt mit Stet"))
        XCTAssertTrue(b.text.contains("⁂"))
        XCTAssertGreaterThanOrEqual(b.pages, 4)

        let epub = try await Exporter.export(book, options: ExportOptions(format: .epub), to: out.appendingPathComponent("E.epub"))
        let chapter = try await zipEntry(epub.file, "EPUB/text/ch001.xhtml")
        XCTAssertTrue(chapter.contains("scene-break"))
        XCTAssertTrue(chapter.contains("„Wo ist der Wärter?“"))
        let css = try await zipEntry(epub.file, "EPUB/styles/stylesheet1.css")
        XCTAssertTrue(css.contains("p.scene-break"))

        var docxOptions = ExportOptions(format: .docx)
        docxOptions.commentsAsAnnotations = true
        let docx = try await Exporter.export(book, options: docxOptions, to: out.appendingPathComponent("W.docx"))
        let document = try await zipEntry(docx.file, "word/document.xml")
        XCTAssertTrue(document.contains("Szenenwechsel"))
        XCTAssertTrue(document.contains("Fassung \(docx.stamp.shortCommit)"))
        let comments = try await zipEntry(docx.file, "word/comments.xml")
        XCTAssertTrue(comments.contains("Zu direkt?"))
        XCTAssertTrue(comments.contains("Gisela"))

        let odt = try await Exporter.export(book, options: ExportOptions(format: .odt), to: out.appendingPathComponent("O.odt"))
        let content = try await zipEntry(odt.file, "content.xml")
        XCTAssertTrue(content.contains("Das Wasser stieg"))

        let md = try await Exporter.export(book, options: ExportOptions(format: .markdown), to: out.appendingPathComponent("Buch.md"))
        let markdown = try String(contentsOf: md.file, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Die Flut"))

        // Each export marks its version.
        let marks = await book.milestones().filter(\.isExport)
        XCTAssertEqual(marks.count, 6)
        XCTAssertTrue(marks.allSatisfy { $0.commit == head })
        XCTAssertTrue(marks.contains { $0.name == "Export: PDF – Manuskript" })
    }

    func testCoverInPDFBookAndEPUB() async throws {
        try requireTools()
        let book = try await makeBook()
        let out = temp.appendingPathComponent("Ausgabe")
        let without = try pdfText(try await Exporter.export(book, options: ExportOptions(format: .pdfBook), to: out.appendingPathComponent("ohne.pdf")).file)

        let picture = temp.appendingPathComponent("titel.png")
        try CoverTests.image(.png, at: picture)
        try book.setCover(from: picture)
        let with = try pdfText(try await Exporter.export(book, options: ExportOptions(format: .pdfBook), to: out.appendingPathComponent("mit.pdf")).file)
        XCTAssertEqual(with.pages, without.pages + 2, "the cover and the blank back of it")

        let epub = try await Exporter.export(book, options: ExportOptions(format: .epub), to: out.appendingPathComponent("E.epub"))
        let opf = try await zipEntry(epub.file, "EPUB/content.opf")
        XCTAssertTrue(opf.contains("cover-image"), "the ePUB names its cover")
    }

    func testUnusualMarkupDoesNotBreakThePDF() async throws {
        try requireTools()
        let book = try await Book.create(at: temp.appendingPathComponent("Markup.stet"), title: "Markup", author: "Test")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        // Seen in a real manuscript's early version: an empty link around an HTML comment,
        // footnotes pointing at footnotes, and an image whose file is missing.
        scene.body = "Ein Satz.[<!-- [^1] -->]()\n\n[^1]: [^2]\n\n[^2]: \n\n![Ein Bild](fehlt.png)\n\nEnde.\n"
        try book.writeScene(scene)
        for format in [ExportFormat.pdfBook, .pdfManuscript, .epub, .docx] {
            let result = try await Exporter.export(book, options: ExportOptions(format: format), to: temp.appendingPathComponent("out.\(format.fileExtension)"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.file.path), format.rawValue)
        }
    }

    func testMissingToolsAreExplained() {
        let saved = Exporter.searchPaths
        defer { Exporter.searchPaths = saved }
        let message = ExportError.missingTools(["pandoc", "typst"]).localizedDescription
        XCTAssertTrue(message.contains("brew install pandoc typst"))
    }
}
