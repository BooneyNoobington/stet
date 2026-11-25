import XCTest
@testable import ZadurCore

final class BackupTests: TempDirTestCase {
    func makeBook(_ title: String = "Der Leuchtturm") async throws -> Book {
        let book = try await Book.create(at: temp.appendingPathComponent("Buecher/\(title).crea"), title: title, author: "Test")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Der Wind kam von Westen.\n"
        try book.writeScene(scene)
        try await book.saveVersion()
        try await book.startExperiment(named: "Andere Sicht", carryChanges: false)
        try await book.switchTo("main")
        try await book.setMilestone(name: "Erste Fassung")
        try book.addFeedback(from: "Gisela", refersTo: nil, text: "Schön.")
        // Unsaved text and per-device state.
        scene.body = "Der Wind kam von Westen. Noch nicht gesichert.\n"
        try book.writeScene(scene)
        try FileManager.default.createDirectory(at: book.url.appendingPathComponent(".local"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: book.url.appendingPathComponent(".local/state.json"))
        return book
    }

    func testBackupAndRestoreKeepEverything() async throws {
        let book = try await makeBook()
        let folder = temp.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_795_000_000)

        let zip = try await Backup.create(book, in: folder, date: date)
        XCTAssertEqual(zip.lastPathComponent, Backup.fileName(for: book, date: date))
        XCTAssertTrue(zip.lastPathComponent.hasPrefix("Der Leuchtturm – Backup "))
        XCTAssertTrue(zip.lastPathComponent.hasSuffix(".crea.zip"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(leftovers, [zip.lastPathComponent], "no temporary files in the backup folder")

        let restored = try await Backup.restore(zip, into: temp.appendingPathComponent("Wiederhergestellt"))
        let copy = try Book(url: restored)
        XCTAssertEqual(restored.lastPathComponent, "Der Leuchtturm.crea")
        let headOriginal = await book.git.headCommit()
        let headCopy = await copy.git.headCommit()
        XCTAssertEqual(headCopy, headOriginal, "the whole history")
        let experiments = await copy.experiments()
        XCTAssertEqual(experiments.map(\.name), ["Andere Sicht"])
        let milestones = await copy.milestones()
        XCTAssertEqual(milestones.map(\.name), ["Erste Fassung"])
        XCTAssertEqual(copy.feedbackEntries().map(\.from), ["Gisela"])
        XCTAssertEqual(try copy.readScene(copy.manifest.sceneIDs[0]).body, "Der Wind kam von Westen. Noch nicht gesichert.\n", "unsaved text too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent(".local").path), "per-device state left out")
        let problem = await copy.git.integrityProblem()
        XCTAssertNil(problem)

        // Restoring again doesn't overwrite.
        let second = try await Backup.restore(zip, into: temp.appendingPathComponent("Wiederhergestellt"))
        XCTAssertEqual(second.lastPathComponent, "Der Leuchtturm (wiederhergestellt).crea")
    }

    func testListAndRotateOnlyTouchThisBook() async throws {
        let book = try await makeBook()
        let other = try await makeBook("Anderes Buch")
        let folder = temp.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for day in 0..<5 {
            try await Backup.create(book, in: folder, date: Date(timeIntervalSince1970: 1_795_000_000 + Double(day) * 86_400))
        }
        try await Backup.create(other, in: folder)

        XCTAssertEqual(Backup.list(in: folder, for: book).count, 5)
        let removed = try Backup.rotate(in: folder, for: book, keep: 3)
        XCTAssertEqual(removed.count, 2)
        let kept = Backup.list(in: folder, for: book)
        XCTAssertEqual(kept.count, 3)
        XCTAssertGreaterThan(kept[0].date, kept[2].date, "newest first, oldest removed")
        XCTAssertEqual(Backup.list(in: folder, for: other).count, 1, "another book's backups stay")
    }

    func testDamagedAndMissing() async throws {
        let book = try await makeBook()
        do {
            try await Backup.create(book, in: temp.appendingPathComponent("gibt-es-nicht"))
            XCTFail("expected an error")
        } catch Backup.BackupError.folderUnavailable {}

        let broken = temp.appendingPathComponent("kaputt.crea.zip")
        try Data("kein zip".utf8).write(to: broken)
        do {
            _ = try await Backup.restore(broken, into: temp.appendingPathComponent("X"))
            XCTFail("expected an error")
        } catch Backup.BackupError.damaged {}
    }
}
