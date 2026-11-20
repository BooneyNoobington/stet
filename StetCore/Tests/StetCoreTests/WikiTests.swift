import XCTest
@testable import StetCore

final class WikiMatcherTests: XCTestCase {
    func names(_ text: String, _ list: [String]) -> [String] {
        WikiMatcher.matches(in: text, regex: WikiMatcher.regex(for: list)!).map(\.name)
    }

    func testWholeWordsGenitiveAndLongestFirst() {
        let text = "Mara sah Maras Koffer. Marathon? Kapitänin Kessler und Mara Kessler gingen. Leuchtturmwärter."
        XCTAssertEqual(names(text, ["Mara", "Mara Kessler", "Leuchtturm"]), ["Mara", "Mara", "Mara Kessler"])
        XCTAssertEqual(names("Ümit kam. Ümits Hut.", ["Ümit"]), ["Ümit", "Ümit"], "umlauts are letters")
        XCTAssertEqual(names("mara kam", ["Mara"]), [], "case-sensitive")
        XCTAssertEqual(names("Er ging (Hafen) zum „Hafen“.", ["Hafen"]), ["Hafen", "Hafen"])
    }
}

final class WikiTests: TempDirTestCase {
    func makeBook() async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("Wiki.stet"), title: "Wiki", author: "Test")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Mara erreichte den Hafen. Maras Koffer war schwer. {>>Mara?<<}\n"
        try book.writeScene(scene)
        let second = try book.addScene(toChapter: book.manifest.chapters[0].id, after: scene.id)
        var s2 = try book.readScene(second.id)
        s2.body = "Der Alte wartete am Leuchtturm.\n"
        try book.writeScene(s2)
        try await book.saveVersion()
        return book
    }

    func testEntriesRoundTripAndAppearances() async throws {
        let book = try await makeBook()
        var mara = try book.createWiki(title: "Mara Kessler", kind: .character)
        XCTAssertEqual(mara.id, "Mara-Kessler")
        mara.aliases = ["Mara", "die Kapitänin"]
        mara.facts = [Fact("Geboren", "1921"), Fact("Augen", "grau"), Fact("Leer", "")]
        mara.body = "# Mara\n\nKam 1953 auf die Insel.\n"
        try book.saveWiki(mara)

        let hafen = try book.createWiki(title: "Hafen", kind: .place)
        _ = try book.createWiki(title: "Mara Kessler", kind: .character)  // same title, unique file

        let entries = book.wikiEntries()
        XCTAssertEqual(entries.map(\.title), ["Mara Kessler", "Mara Kessler", "Hafen"], "by kind, then title")
        let loaded = try XCTUnwrap(entries.first { $0.id == "Mara-Kessler" })
        XCTAssertEqual(loaded.aliases, ["Mara", "die Kapitänin"])
        XCTAssertEqual(loaded.facts, [Fact("Geboren", "1921"), Fact("Augen", "grau")], "empty facts are dropped")
        XCTAssertEqual(loaded.summary, "Mara")
        XCTAssertEqual(book.wikiEntry(named: "die Kapitänin")?.id, "Mara-Kessler")

        let appearances = book.appearances(of: loaded)
        XCTAssertEqual(appearances.map(\.sceneID), [book.manifest.sceneIDs[0]])
        XCTAssertEqual(appearances.first?.count, 2, "Mara and Maras; the comment doesn't count")
        XCTAssertEqual(book.appearances(of: hafen).count, 1)

        let saved = try await book.saveVersion()
        XCTAssertTrue(saved?.subject.contains("Wiki") == true)
    }

    func testPlainMarkdownNoteFromAnImport() async throws {
        let book = try await makeBook()
        try FileManager.default.createDirectory(at: book.url.appendingPathComponent("wiki"), withIntermediateDirectories: true)
        try Data("# Nützliches\n\nNamen und Daten.\n".utf8).write(to: book.url.appendingPathComponent("wiki/Nützliches.md"))
        let note = try XCTUnwrap(book.wikiEntries().first)
        XCTAssertEqual(note.title, "Nützliches")
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(note.body, "# Nützliches\n\nNamen und Daten.\n")
    }

    func testSceneFactsAndFields() async throws {
        let book = try await makeBook()
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.factList = [Fact("Datum", "14.3.1953"), Fact("Uhrzeit", ""), Fact("Ort", "[[Hafen]]")]
        try book.writeScene(scene)
        let reread = try book.readScene(scene.id)
        XCTAssertEqual(reread.factList, [Fact("Datum", "14.3.1953"), Fact("Ort", "[[Hafen]]")])
        XCTAssertEqual(reread.factList[1].displayValue, "Hafen")
        XCTAssertEqual(reread.factList[1].linkedTitle, "Hafen")
        XCTAssertEqual(reread.body, scene.body, "the prose is untouched")

        XCTAssertEqual(book.manifest.sceneFactFields, Manifest.defaultFactFields)
        try book.updateManifest { $0.sceneFactFields = ["Datum", "Wetter"] }
        let reopened = try Book(url: book.url)
        XCTAssertEqual(reopened.manifest.sceneFactFields, ["Datum", "Wetter"])
    }
}
