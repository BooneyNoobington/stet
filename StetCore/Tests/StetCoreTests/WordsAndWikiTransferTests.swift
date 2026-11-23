import Foundation
import XCTest
@testable import StetCore

/// The book's spelling word list, and taking a wiki along into another book.
final class WordsAndWikiTransferTests: TempDirTestCase {
    private func book(_ name: String) async throws -> Book {
        try await Book.create(at: temp.appendingPathComponent("\(name).stet"), title: name, author: "Test")
    }

    // MARK: Word list

    func testWordListIsStoredSortedAndNamedInTheVersion() async throws {
        let book = try await book("Buch")
        try book.allowWord("Zwurbel")
        try book.allowWord("Ährenfeld")
        try book.allowWord("Zwurbel")
        XCTAssertEqual(book.manifest.words, ["Ährenfeld", "Zwurbel"])
        let reread = try Book(url: book.url)
        XCTAssertEqual(reread.manifest.words, ["Ährenfeld", "Zwurbel"])
        let result = try await book.saveVersion()
        XCTAssertEqual(result?.subject, "Wörterbuch")

        try book.disallowWord("Zwurbel")
        try book.disallowWord("Ährenfeld")
        XCTAssertNil(book.manifest.words)
        let yaml = try String(contentsOf: book.url.appendingPathComponent(Manifest.fileName), encoding: .utf8)
        XCTAssertFalse(yaml.contains("words"))
    }

    func testBothMacsWordsAreKeptWhenMerging() {
        var base = Manifest(title: "B", authors: [], language: "de")
        base.words = ["Alt"]
        var ours = base
        ours.words = ["Alt", "Mara"]
        var theirs = base
        theirs.words = ["Alt", "Zwurbel"]
        XCTAssertEqual(Manifest.merge(base: base, ours: ours, theirs: theirs).words, ["Alt", "Mara", "Zwurbel"])

        theirs.words = nil  // removed on the other side
        XCTAssertEqual(Manifest.merge(base: base, ours: ours, theirs: theirs).words, ["Mara"])
    }

    // MARK: Wiki transfer

    private func firstVolume() async throws -> Book {
        let book = try await book("Band 1")
        var mara = try book.createWiki(title: "Mara Kessler", kind: .character)
        mara.aliases = ["Mara", "die Kapitänin"]
        mara.facts = [Fact("Geboren", "1921"), Fact("Herkunft", "[[Hamburg]]")]
        mara.body = "Kam 1953 auf die Insel."
        try book.saveWiki(mara)
        try book.createWiki(title: "Hamburg", kind: .place)
        try book.createWiki(title: "Leuchtfeuer", kind: .term)
        return book
    }

    func testExportedWikiGoesIntoTheSequel() async throws {
        let first = try await firstVolume()
        let archive = temp.appendingPathComponent("Band 1 – Wiki.zip")
        try first.exportWiki(to: archive)
        let listing = try Tools.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", archive.path]).text
        XCTAssertTrue(listing.contains("Wiki/Mara-Kessler.md"), listing)

        let sequel = try await book("Band 2")
        try sequel.createWiki(title: "hamburg", kind: .place)  // already there (other case)
        let report = try sequel.importWiki(Book.wikiEntries(at: archive))
        XCTAssertEqual(Set(report.added), ["Mara Kessler", "Leuchtfeuer"])
        XCTAssertEqual(report.skipped, ["Hamburg"])

        let mara = try XCTUnwrap(sequel.wikiEntry(named: "die Kapitänin"))
        XCTAssertEqual(mara.facts, [Fact("Geboren", "1921"), Fact("Herkunft", "[[Hamburg]]")])
        XCTAssertEqual(mara.body.trimmingCharacters(in: .whitespacesAndNewlines), "Kam 1953 auf die Insel.")
        XCTAssertEqual(mara.kind, .character)

        // Importing again changes nothing.
        let again = try sequel.importWiki(Book.wikiEntries(at: archive))
        XCTAssertTrue(again.added.isEmpty)
        XCTAssertEqual(again.skipped.count, 3)
    }

    func testWikiComesStraightFromAnotherBookOrAFolder() async throws {
        let first = try await firstVolume()
        let sequel = try await book("Band 2")
        let fromBook = try sequel.importWiki(Book.wikiEntries(at: first.url))
        XCTAssertEqual(fromBook.added.count, 3)

        let folder = temp.appendingPathComponent("Notizen")
        try write("# Der Leuchtturm\n\nWeiß, mit rotem Band.\n", to: "Notizen/leuchtturm.md")
        let third = try await book("Band 3")
        let fromFolder = try third.importWiki(Book.wikiEntries(at: folder))
        XCTAssertEqual(fromFolder.added.count, 1)
        XCTAssertEqual(third.wikiEntries().first?.kind, .note)

        let empty = try await book("Leer")
        XCTAssertThrowsError(try Book.wikiEntries(at: empty.url)) { error in
            XCTAssertEqual(error as? WikiTransferError, .nothingFound("Leer.stet"))
        }
        XCTAssertThrowsError(try empty.exportWiki(to: temp.appendingPathComponent("x.zip")))
    }

    func testFileNamesDontCollideEvenInOtherCase() async throws {
        let first = try await firstVolume()
        let sequel = try await book("Band 2")
        // The same file name apart from case (one file on the Mac), a different person.
        try sequel.saveWiki(WikiEntry(id: "mara-kessler", title: "Mara Albers", kind: .character))
        let report = try sequel.importWiki(Book.wikiEntries(at: first.url))
        XCTAssertTrue(report.added.contains("Mara Kessler"))
        XCTAssertEqual(sequel.wikiEntry(named: "Mara Kessler")?.id, "Mara-Kessler-2")
        XCTAssertEqual(sequel.wikiEntry(named: "Mara Albers")?.id, "mara-kessler")

        // Creating an entry by hand had the same problem.
        let book = try await book("Band 3")
        try book.createWiki(title: "Hamburg", kind: .place)
        let lower = try book.createWiki(title: "hamburg", kind: .term)
        XCTAssertEqual(lower.id, "hamburg-2")
        XCTAssertEqual(book.wikiEntries().count, 2)
    }
}

/// The sample book offered on first start.
final class SampleBookTests: TempDirTestCase {
    func testSampleBookShowsWhatStetCanDo() async throws {
        let book = try await SampleBook.create(at: temp.appendingPathComponent("Beispiel.stet"))
        XCTAssertEqual(book.manifest.title, SampleBook.title)
        XCTAssertEqual(book.manifest.chapters.map(\.title), ["Ankunft", "Gewitter"])
        XCTAssertEqual(book.manifest.sceneIDs.count, 4)
        XCTAssertEqual(book.wikiEntries().map(\.title).sorted(), ["Lene", "Seehaus"])
        let notes = book.manifest.sceneIDs.compactMap { try? book.readScene($0).body }.joined()
        XCTAssertTrue(notes.contains("{>>TODO:"))
        XCTAssertTrue(notes.contains("\n\n> Für Lene, die *Kapitänin*."), "a quote, with italics")
        XCTAssertTrue(notes.contains("Jemand klopfte"), "the main version keeps its ending")
        let experiments = try await book.experiments()
        XCTAssertEqual(experiments.map(\.name), ["Anderes Ende"])
        let milestones = await book.milestones()
        XCTAssertEqual(milestones.first?.name, "Erste Fassung")
        let versions = try await book.git.log()
        XCTAssertEqual(versions.count, 3)
        let changed = try await book.git.changedPaths()
        XCTAssertTrue(changed.isEmpty)
        let facts = try book.readScene(book.manifest.sceneIDs[1]).factList
        XCTAssertTrue(facts.contains(Fact("Datum", "Sommer 1978")))
    }
}
