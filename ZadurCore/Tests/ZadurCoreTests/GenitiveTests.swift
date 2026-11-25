import Foundation
import XCTest
@testable import ZadurCore

/// German genitives and their pitfalls in the wiki's name recognition.
final class GenitiveTests: TempDirTestCase {
    private func found(_ names: [String], in text: String, excluding: Set<String> = []) -> [String] {
        guard let regex = WikiMatcher.regex(for: names) else { return [] }
        return WikiMatcher.matches(in: text, regex: regex, excluding: excluding).map { "\(($0.range.location, $0.range.length)) \($0.name)" }
            .map { entry in String(entry.split(separator: " ").last ?? "") }
    }

    private func words(_ names: [String], in text: String, excluding: Set<String> = []) -> [String] {
        guard let regex = WikiMatcher.regex(for: names) else { return [] }
        let ns = text as NSString
        return WikiMatcher.matches(in: text, regex: regex, excluding: excluding).map { ns.substring(with: $0.range) }
    }

    func testGenitiveForms() {
        XCTAssertEqual(words(["Gabriela"], in: "Gabrielas Auto, Gabriela's Rad, Gabriela’s Hut"), ["Gabrielas", "Gabriela's", "Gabriela’s"])
        XCTAssertEqual(words(["Andreas"], in: "Andreas' Restaurant und Andreas’ Garten, Andreas's Laden"), ["Andreas", "Andreas", "Andreas's"])
        // The old genitive -ens, only for names ending in s, ß, x, z.
        XCTAssertEqual(words(["Hans", "Max", "Fritz"], in: "Hansens Hut, Maxens Rad und Fritzens Frau"), ["Hansens", "Maxens", "Fritzens"])
        XCTAssertEqual(words(["Gabriela", "Mara"], in: "Gabrielaens Maraens"), [])
        // No false hits inside longer words.
        XCTAssertEqual(words(["Hans", "Andreas"], in: "Hansestadt, Andreasstraße, Hanse"), [])
    }

    func testTheLongerNameWins() {
        XCTAssertEqual(found(["Andrea", "Andreas"], in: "Andreas kam. Andrea lachte. Andreas' Auto."), ["Andreas", "Andrea", "Andreas"])
        XCTAssertEqual(found(["Andrea"], in: "Andreas kam."), ["Andrea"], "without Andreas in the wiki, it looks like Andrea's genitive")
        XCTAssertEqual(found(["Andrea"], in: "Andreas kam. Andrea lachte.", excluding: ["Andreas"]), ["Andrea"])
    }

    func testNotMeantIsStoredAndHonoured() async throws {
        let book = try await Book.create(at: temp.appendingPathComponent("Buch.crea"), title: "Buch", author: "Test")
        var andrea = try book.createWiki(title: "Andrea", kind: .character)
        andrea.notMeant = ["Andreas"]
        try book.saveWiki(andrea)
        XCTAssertEqual(book.wikiEntry(named: "Andrea")?.notMeant, ["Andreas"])
        let file = try String(contentsOf: book.url.appendingPathComponent(andrea.path), encoding: .utf8)
        XCTAssertTrue(file.contains("notMeant"))

        let id = book.manifest.sceneIDs[0]
        var scene = try book.readScene(id)
        scene.body = "Andreas kam herein. Andrea lachte. Andreas Hut lag da.\n"
        try book.writeScene(scene)
        XCTAssertEqual(book.appearances(of: try XCTUnwrap(book.wikiEntry(named: "Andrea"))).first?.count, 1)

        // With an entry for Andreas, his name is his, even without "not meant".
        var plain = try XCTUnwrap(book.wikiEntry(named: "Andrea"))
        plain.notMeant = []
        try book.saveWiki(plain)
        try book.createWiki(title: "Andreas", kind: .character)
        XCTAssertEqual(book.appearances(of: try XCTUnwrap(book.wikiEntry(named: "Andrea"))).first?.count, 1)
        XCTAssertEqual(book.appearances(of: try XCTUnwrap(book.wikiEntry(named: "Andreas"))).first?.count, 2)

        // "Not meant" comes along into a sequel.
        let sequel = try await Book.create(at: temp.appendingPathComponent("Band 2.crea"), title: "Band 2", author: "Test")
        andrea = try XCTUnwrap(book.wikiEntry(named: "Andrea"))
        andrea.notMeant = ["Andreas"]
        try book.saveWiki(andrea)
        try sequel.importWiki(Book.wikiEntries(at: book.url))
        XCTAssertEqual(sequel.wikiEntry(named: "Andrea")?.notMeant, ["Andreas"])
    }
}
