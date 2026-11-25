import XCTest
@testable import ZadurCore

final class BookTests: TempDirTestCase {
    func makeBook() async throws -> Book {
        try await Book.create(at: temp.appendingPathComponent("Test.crea"), title: "Testbuch", author: "Test")
    }

    func testCreateMakesFirstVersion() async throws {
        let book = try await makeBook()
        XCTAssertEqual(book.manifest.chapters.count, 1)
        XCTAssertEqual(book.manifest.sceneIDs.count, 1)
        let log = try await book.git.log()
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(log[0].subject.contains("Testbuch"))
        let nothing = try await book.saveVersion()
        XCTAssertNil(nothing, "no changes, no version")
    }

    func testSaveVersionMessageAndTrailers() async throws {
        let book = try await makeBook()
        let id = book.manifest.sceneIDs[0]
        var scene = try book.readScene(id)
        scene.title = "Die Ankunft"
        scene.body = "Der Wind kam von Westen."
        try book.writeScene(scene)

        let result = try await book.saveVersion(activeMinutes: 12)
        XCTAssertEqual(result?.subject, "Bearbeitet: „Die Ankunft“ · +5 Wörter")
        XCTAssertEqual(result?.wordsDelta, 5)

        let commit = try await book.git.log(limit: 1)[0]
        XCTAssertEqual(commit.trailers["Words"], "5")
        XCTAssertEqual(commit.trailers["Words-Delta"], "+5")
        XCTAssertEqual(commit.trailers["Active-Minutes"], "12")
        XCTAssertEqual(commit.trailers["Scenes"], id)
        XCTAssertTrue(commit.body.contains("Crea-Words: 5\nCrea-Words-Delta: +5"), "the Crea names (spec §9.3)")

        try await book.git.addNote("Erste richtige Fassung", to: commit.hash)
        let noted = try await book.git.log(limit: 1)[0]
        XCTAssertEqual(noted.note, "Erste richtige Fassung")
    }

    func testStructureChangesAndNewScenes() async throws {
        let book = try await makeBook()
        let chapter = try book.addChapter(title: "Zweites Kapitel", after: book.manifest.chapters[0].id)
        var scene = try book.readScene(chapter.sceneIDs[0])
        scene.body = "Neu hier."
        try book.writeScene(scene)
        let result = try await book.saveVersion()
        XCTAssertEqual(result?.subject, "Neu: „Neu hier…“ · Struktur geändert · +2 Wörter")

        try book.deleteScene(chapter.sceneIDs[0])
        let removed = try await book.saveVersion()
        XCTAssertEqual(removed?.subject, "Entfernt: „Neu hier…“ · Struktur geändert · -2 Wörter")
    }

    func testWriteSceneOnlyWhenChanged() async throws {
        let book = try await makeBook()
        let scene = try book.readScene(book.manifest.sceneIDs[0])
        XCTAssertFalse(try book.writeScene(scene))
    }

    func testSnapshotsDoNotTouchHistoryOrIndex() async throws {
        let book = try await makeBook()
        let id = book.manifest.sceneIDs[0]
        let head = await book.git.headCommit()

        let none = try await book.snapshot(device: "mac1")
        XCTAssertNil(none, "nothing changed yet")

        var scene = try book.readScene(id)
        scene.body = "Ungesichert, aber nicht verloren."
        try book.writeScene(scene)
        let first = try await book.snapshot(device: "mac1")
        XCTAssertNotNil(first)
        let again = try await book.snapshot(device: "mac1")
        XCTAssertNil(again, "same tree again")

        scene.body += " Noch mehr."
        try book.writeScene(scene)
        let second = try await book.snapshot(device: "mac1")
        XCTAssertNotNil(second)

        let headAfter = await book.git.headCommit()
        XCTAssertEqual(head, headAfter, "the branch must not move")
        let changed = try await book.git.changedPaths()
        XCTAssertEqual(changed, [Book.scenePath(id)], "the real index is untouched")

        let parent = try await book.git.run(["rev-parse", "\(second!)^"]).string.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(parent, first, "snapshots chain while HEAD stays the same")

        let history = try await book.history(ofScene: id, device: "mac1")
        XCTAssertEqual(history.filter(\.isSnapshot).count, 2)
        let newest = await book.text(of: history[0])
        XCTAssertEqual(newest, "Ungesichert, aber nicht verloren. Noch mehr.")
    }

    func testSceneHistoryAndRestoreText() async throws {
        let book = try await makeBook()
        let id = book.manifest.sceneIDs[0]
        var scene = try book.readScene(id)
        for text in ["Eins.", "Eins. Zwei.", "Eins. Zwei. Drei."] {
            scene.body = text
            try book.writeScene(scene)
            try await book.saveVersion()
        }
        let history = try await book.history(ofScene: id)
        XCTAssertEqual(history.count, 4)
        let texts = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, version) in history.enumerated() { group.addTask { (i, await book.text(of: version)) } }
            var result = [String?](repeating: nil, count: history.count)
            for await (i, text) in group { result[i] = text }
            return result
        }
        XCTAssertEqual(texts, ["Eins. Zwei. Drei.", "Eins. Zwei.", "Eins.", ""])
    }

    func testBookIsMarkedAsPackageEvenWithoutTheType() async throws {
        // An extension macOS doesn't know, so only the bundle bit can make it a package.
        let url = temp.appendingPathComponent("Unbekannt.stetbook")
        _ = try await Book.create(at: url, title: "T", author: "A")
        XCTAssertEqual(try url.resourceValues(forKeys: [.isPackageKey]).isPackage, true)
    }

    func testIntegrityOfFreshBook() async throws {
        let book = try await makeBook()
        let report = await HealthCheck.run(book)
        XCTAssertTrue(report.isHealthy, "\(report)")
    }
}
