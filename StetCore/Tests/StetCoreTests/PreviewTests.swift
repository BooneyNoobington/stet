import XCTest
@testable import StetCore

final class MarkdownSnippetTests: XCTestCase {
    func testParagraphsEmphasisBreaksAndComments() {
        let markdown = """
        Der *Wind* kam {==von==}{>>Notiz<<} **Westen** & <nicht> „hier“.
        Zweite Zeile im selben Absatz.

        ***

        # Ein Titel

        snake_case_bleibt so.
        """
        XCTAssertEqual(MarkdownSnippet.html(markdown), """
        <p>Der <em>Wind</em> kam von <strong>Westen</strong> &amp; &lt;nicht&gt; „hier“. Zweite Zeile im selben Absatz.</p>
        <p class="break">⁂</p>
        <h3>Ein Titel</h3>
        <p>snake_case_bleibt so.</p>
        """)
    }

    func testWordLimitStopsAtParagraphs() {
        let html = MarkdownSnippet.html("Eins zwei drei.\n\nVier fünf.\n\nSechs.", wordLimit: 4)
        XCTAssertEqual(html, "<p>Eins zwei drei.</p>\n<p>Vier fünf.</p>")
    }
}

final class BookSummaryTests: TempDirTestCase {
    func testSummaryAndPreview() async throws {
        let url = temp.appendingPathComponent("Vorschau.stet")
        let book = try await Book.create(at: url, title: "Der <Leuchtturm>", author: "Erika Muster")
        var first = try book.readScene(book.manifest.sceneIDs[0])
        first.title = "Ankunft"
        first.body = "Der Wind kam von *Westen*."
        try book.writeScene(first)
        let chapter = try book.addChapter(title: "Die Flut", after: book.manifest.chapters[0].id)
        _ = try book.addScene(toChapter: chapter.id)
        try Data("JPEG".utf8).write(to: url.appendingPathComponent("cover.jpg"))
        try book.updateManifest { $0.cover = "cover.jpg" }

        let summary = try BookSummary.read(url)
        XCTAssertEqual(summary.title, "Der <Leuchtturm>")
        XCTAssertEqual(summary.chapters.map(\.title), ["Kapitel 1", "Die Flut"])
        XCTAssertEqual(summary.sceneCount, 3)
        XCTAssertEqual(summary.totalWords, 5)
        XCTAssertEqual(summary.opening, "Der Wind kam von *Westen*.")
        XCTAssertEqual(summary.coverURL?.lastPathComponent, "cover.jpg")

        let html = BookPreviewHTML.render(summary, coverSource: "cid:cover")
        XCTAssertTrue(html.contains("<h1>Der &lt;Leuchtturm&gt;</h1>"))
        XCTAssertTrue(html.contains("2 Kapitel · 3 Szenen · 5 Wörter"))
        XCTAssertTrue(html.contains("<em>Westen</em>"))
        XCTAssertTrue(html.contains("src=\"cid:cover\""))
    }
}
